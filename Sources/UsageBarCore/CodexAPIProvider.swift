import Foundation

/// Fetches Codex quota data via the ChatGPT usage endpoint.
/// Reads credentials from ~/.codex/auth.json.
/// Refreshes expired tokens automatically and saves back to the file.
public struct CodexAPIProvider: ProviderSnapshotLoader {
    private let homeDirectory: URL
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let refreshBufferMs: Double = 5 * 60 * 1000

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func loadSnapshot(now: Date) async -> ProviderSnapshot {
        do {
            var cred = try loadCredential()

            if cred.needsRefresh {
                cred = try await refreshAndSave(cred)
            }

            let (data, status) = try await fetchUsage(accessToken: cred.accessToken, accountId: cred.accountId)

            if status == 200 {
                return try decodeAndBuild(data: data, now: now)
            }

            if status == 401 || status == 403 {
                // Try refresh first
                if let refreshed = try? await refreshAndSave(cred) {
                    let (d, s) = try await fetchUsage(accessToken: refreshed.accessToken, accountId: refreshed.accountId)
                    if s == 200 { return try decodeAndBuild(data: d, now: now) }
                }

                // Re-read from disk (Codex CLI may have rotated)
                if let fresh = try? loadCredential(), fresh.accessToken != cred.accessToken {
                    let (d, s) = try await fetchUsage(accessToken: fresh.accessToken, accountId: fresh.accountId)
                    if s == 200 { return try decodeAndBuild(data: d, now: now) }
                }

                throw ProviderError.sessionExpired("Session expired. Run `codex --login` to re-authenticate.")
            }

            if status == 429 { throw ProviderError.rateLimited }

            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.apiError("Codex API returned \(status): \(body)")
        } catch let error as ProviderError {
            return .unavailable(providerID: .codex, sourceLabel: "Codex API", notes: [error.userMessage])
        } catch {
            return .unavailable(providerID: .codex, sourceLabel: "Codex API", notes: [error.localizedDescription])
        }
    }

    // MARK: - Credential model

    private struct Credential: Sendable {
        let accessToken: String
        let refreshToken: String?
        let accountId: String?
        let expiresAt: Double? // milliseconds or seconds since epoch
        let rawData: Data // original JSON for field-preserving write-back

        var needsRefresh: Bool {
            guard let expiresAt else { return false } // no expiry info = assume valid
            // Handle both ms and seconds
            let expiryMs = expiresAt > 1e12 ? expiresAt : expiresAt * 1000
            let nowMs = Date().timeIntervalSince1970 * 1000
            return nowMs + CodexAPIProvider.refreshBufferMs >= expiryMs
        }
    }

    // MARK: - Loading credentials

    private func loadCredential() throws -> Credential {
        let authPath = homeDirectory.appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: authPath.path) else {
            throw ProviderError.noCredentials("Run `codex --login` in Terminal to authenticate.")
        }
        let data = try Data(contentsOf: authPath)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else {
            throw ProviderError.noCredentials("Invalid Codex auth file. Run `codex --login`.")
        }
        return Credential(
            accessToken: accessToken,
            refreshToken: tokens["refresh_token"] as? String,
            accountId: tokens["account_id"] as? String,
            expiresAt: tokens["expires_at"] as? Double,
            rawData: data
        )
    }

    // MARK: - Token refresh

    private func refreshAndSave(_ cred: Credential) async throws -> Credential {
        guard let refreshToken = cred.refreshToken else {
            throw ProviderError.sessionExpired("Session expired. Run `codex --login` to re-authenticate.")
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: Self.clientID),
        ]
        request.httpBody = components.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ProviderError.sessionExpired("Session expired. Run `codex --login` to re-authenticate.") }

        let tokenResp = try JSONDecoder().decode(CodexTokenResponse.self, from: data)

        let newExpiresAt: Double?
        if let expiresIn = tokenResp.expiresIn {
            newExpiresAt = Date().timeIntervalSince1970 * 1000 + Double(expiresIn) * 1000
        } else {
            newExpiresAt = cred.expiresAt
        }

        // Reconstruct JSON preserving unknown fields
        let newRawData = updatedRawData(
            from: cred.rawData,
            accessToken: tokenResp.accessToken,
            refreshToken: tokenResp.refreshToken ?? refreshToken,
            expiresAt: newExpiresAt
        )

        let newCred = Credential(
            accessToken: tokenResp.accessToken,
            refreshToken: tokenResp.refreshToken ?? refreshToken,
            accountId: cred.accountId,
            expiresAt: newExpiresAt,
            rawData: newRawData
        )

        saveCredential(newCred)
        return newCred
    }

    private func updatedRawData(from original: Data, accessToken: String, refreshToken: String?, expiresAt: Double?) -> Data {
        guard var dict = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
              var tokens = dict["tokens"] as? [String: Any] else { return original }
        tokens["access_token"] = accessToken
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        if let expiresAt { tokens["expires_at"] = expiresAt }
        dict["tokens"] = tokens
        return (try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)) ?? original
    }

    // MARK: - Saving credentials

    private func saveCredential(_ cred: Credential) {
        let authPath = homeDirectory.appendingPathComponent(".codex/auth.json")
        try? cred.rawData.write(to: authPath, options: .atomic)
    }

    // MARK: - API

    private func fetchUsage(accessToken: String, accountId: String?) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("UsageBar/0.1", forHTTPHeaderField: "User-Agent")
        if let accountId { request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    // MARK: - Snapshot building

    private func decodeAndBuild(data: Data, now: Date) throws -> ProviderSnapshot {
        let usage = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        return buildSnapshot(from: usage, now: now)
    }

    private func buildSnapshot(from usage: CodexUsageResponse, now: Date) -> ProviderSnapshot {
        let primary = usage.rateLimit?.primaryWindow
        let secondary = usage.rateLimit?.secondaryWindow

        let fiveHour = primary?.usedPercent.map {
            QuotaWindowSnapshot(kind: .fiveHour, usedPercent: $0, resetAt: primary?.parsedResetDate)
        }
        let sevenDay = secondary?.usedPercent.map {
            QuotaWindowSnapshot(kind: .sevenDay, usedPercent: $0, resetAt: secondary?.parsedResetDate)
        }

        return ProviderSnapshot(
            providerID: .codex,
            fiveHourWindow: fiveHour,
            sevenDayWindow: sevenDay,
            lastUpdatedAt: now,
            sourceLabel: "Codex API"
        )
    }
}

// MARK: - JSON Models

private struct CodexTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct CodexUsageResponse: Decodable {
    let rateLimit: CodexRateLimitResponse?
    private enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
}

private struct CodexRateLimitResponse: Decodable {
    let primaryWindow: CodexWindowResponse?
    let secondaryWindow: CodexWindowResponse?
    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexWindowResponse: Decodable {
    let usedPercent: Double?
    let resetAt: Double?
    let resetAfterSeconds: Double?

    var parsedResetDate: Date? {
        if let resetAt { return Date(timeIntervalSince1970: resetAt) }
        if let resetAfterSeconds { return Date().addingTimeInterval(resetAfterSeconds) }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case resetAfterSeconds = "reset_after_seconds"
    }
}
