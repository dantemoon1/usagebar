import Foundation

/// Fetches Claude Code quota data via the OAuth usage endpoint.
/// Reads credentials from ~/.claude/.credentials.json or Keychain.
/// Refreshes expired tokens automatically and saves back to the original source.
public struct ClaudeAPIProvider: ProviderSnapshotLoader {
    private static let keychainService = "Claude Code-credentials"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let scopes = "user:profile user:inference user:sessions:claude_code"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let refreshBufferMs: Double = 5 * 60 * 1000

    public init() {}

    public func loadSnapshot(now: Date) async -> ProviderSnapshot {
        do {
            var cred = try loadCredential()

            if cred.needsRefresh {
                cred = try await refreshAndSave(cred)
            }

            let (data, status) = try await fetchUsage(accessToken: cred.accessToken)

            if status == 200 {
                return try decodeAndBuild(data: data, now: now)
            }

            if status == 401 || status == 403 {
                // Try refresh first
                if let refreshed = try? await refreshAndSave(cred) {
                    let (d, s) = try await fetchUsage(accessToken: refreshed.accessToken)
                    if s == 200 { return try decodeAndBuild(data: d, now: now) }
                }

                // Re-read from disk (Claude Code may have rotated)
                if let fresh = try? loadCredential(), fresh.accessToken != cred.accessToken {
                    let (d, s) = try await fetchUsage(accessToken: fresh.accessToken)
                    if s == 200 { return try decodeAndBuild(data: d, now: now) }
                }

                throw ProviderError.sessionExpired("Session expired. Run `claude login` to re-authenticate.")
            }

            if status == 429 { throw ProviderError.rateLimited }

            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.apiError("Claude API returned \(status): \(body)")
        } catch let error as ProviderError {
            return .unavailable(providerID: .claude, sourceLabel: "Claude API", notes: [error.userMessage])
        } catch {
            return .unavailable(providerID: .claude, sourceLabel: "Claude API", notes: [error.localizedDescription])
        }
    }

    // MARK: - Credential model

    private enum CredentialSource: Sendable {
        case file, keychain
    }

    private struct Credential: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Double? // milliseconds since epoch
        let rawData: Data // original JSON for field-preserving write-back
        let source: CredentialSource

        var needsRefresh: Bool {
            guard let expiresAt else { return true }
            let nowMs = Date().timeIntervalSince1970 * 1000
            return nowMs + ClaudeAPIProvider.refreshBufferMs >= expiresAt
        }
    }

    // MARK: - Loading credentials

    private func loadCredential() throws -> Credential {
        if let cred = loadFromFile() { return cred }
        if let cred = loadFromKeychain() { return cred }
        throw ProviderError.noCredentials("Run `claude login` in Terminal to authenticate.")
    }

    private func loadFromFile() -> Credential? {
        let credPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: credPath) else { return nil }
        return parseCredential(from: data, source: .file)
    }

    private func loadFromKeychain() -> Credential? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", Self.keychainService, "-w"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return parseCredential(from: data, source: .keychain)
    }

    private func parseCredential(from data: Data, source: CredentialSource) -> Credential? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = dict["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else { return nil }
        return Credential(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: oauth["expiresAt"] as? Double,
            rawData: data,
            source: source
        )
    }

    // MARK: - Token refresh

    private func refreshAndSave(_ cred: Credential) async throws -> Credential {
        guard let refreshToken = cred.refreshToken else {
            throw ProviderError.sessionExpired("Session expired. Run `claude login` to re-authenticate.")
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": Self.scopes,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ProviderError.sessionExpired("Session expired. Run `claude login` to re-authenticate.") }

        let tokenResp = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)

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
            expiresAt: newExpiresAt,
            rawData: newRawData,
            source: cred.source
        )

        saveCredential(newCred)
        return newCred
    }

    private func updatedRawData(from original: Data, accessToken: String, refreshToken: String?, expiresAt: Double?) -> Data {
        guard var dict = try? JSONSerialization.jsonObject(with: original) as? [String: Any] else { return original }
        var oauth = (dict["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt { oauth["expiresAt"] = expiresAt }
        dict["claudeAiOauth"] = oauth
        return (try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)) ?? original
    }

    // MARK: - Saving credentials

    private func saveCredential(_ cred: Credential) {
        switch cred.source {
        case .file:
            let credPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            try? cred.rawData.write(to: credPath, options: .atomic)
        case .keychain:
            guard let json = String(data: cred.rawData, encoding: .utf8) else { return }
            let del = Process()
            del.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            del.arguments = ["delete-generic-password", "-s", Self.keychainService]
            del.standardOutput = Pipe()
            del.standardError = Pipe()
            try? del.run()
            del.waitUntilExit()

            let add = Process()
            add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            add.arguments = ["add-generic-password", "-s", Self.keychainService, "-w", json]
            add.standardOutput = Pipe()
            add.standardError = Pipe()
            try? add.run()
            add.waitUntilExit()
        }
    }

    // MARK: - API

    private func fetchUsage(accessToken: String) async throws -> (Data, Int) {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("UsageBar/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    // MARK: - Snapshot building

    private func decodeAndBuild(data: Data, now: Date) throws -> ProviderSnapshot {
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        return buildSnapshot(from: usage, now: now)
    }

    private func buildSnapshot(from usage: ClaudeUsageResponse, now: Date) -> ProviderSnapshot {
        let fiveHour = usage.fiveHour.map {
            QuotaWindowSnapshot(kind: .fiveHour, usedPercent: $0.utilization, resetAt: $0.parsedResetDate)
        }
        let sevenDay = usage.sevenDay.map {
            QuotaWindowSnapshot(kind: .sevenDay, usedPercent: $0.utilization, resetAt: $0.parsedResetDate)
        }

        var metrics: [ExpandedMetric] = []
        if let extra = usage.extraUsage, extra.isEnabled, extra.usedCredits > 0 {
            metrics.append(ExpandedMetric(
                id: "extra_credits",
                label: "Extra credits",
                value: UsageBarFormatting.currencyUSD(extra.usedCredits / 100.0)
            ))
        }

        return ProviderSnapshot(
            providerID: .claude,
            fiveHourWindow: fiveHour,
            sevenDayWindow: sevenDay,
            lastUpdatedAt: now,
            sourceLabel: "Claude API",
            metrics: metrics
        )
    }
}

// MARK: - JSON Models

private struct TokenRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: UsageWindow?; let sevenDay: UsageWindow?; let extraUsage: ExtraUsage?
    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"; case sevenDay = "seven_day"; case extraUsage = "extra_usage"
    }
}

private struct UsageWindow: Decodable {
    let utilization: Double; let resetsAt: String?
    var parsedResetDate: Date? {
        guard let resetsAt else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: resetsAt) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: resetsAt)
    }
    private enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" }
}

private struct ExtraUsage: Decodable {
    let isEnabled: Bool; let usedCredits: Double; let monthlyLimit: Double?
    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"; case usedCredits = "used_credits"; case monthlyLimit = "monthly_limit"
    }
}

// MARK: - Errors

enum ProviderError: LocalizedError {
    case noCredentials(String)
    case sessionExpired(String)
    case rateLimited
    case apiError(String)

    var userMessage: String {
        switch self {
        case .noCredentials(let msg): msg
        case .sessionExpired(let msg): msg
        case .rateLimited: "Rate limited. Will retry on next refresh."
        case .apiError(let msg): msg
        }
    }

    var errorDescription: String? { userMessage }
}
