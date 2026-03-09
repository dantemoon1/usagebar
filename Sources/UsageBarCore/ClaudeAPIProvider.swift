import Foundation

/// Fetches Claude Code quota data via the OAuth usage endpoint.
/// Reads credentials from ~/.claude/.credentials.json or Keychain.
/// Falls back to cookie-based approach if OAuth token is unavailable or fails.
public struct ClaudeAPIProvider: ProviderSnapshotLoader {
    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init() {}

    public func loadSnapshot(now: Date) async -> ProviderSnapshot {
        DebugLog.trimIfNeeded()

        // Tier 1: Try OAuth token
        if let cred = loadCredential() {
            DebugLog.log("[Claude] loaded OAuth token")
            do {
                let (data, resp) = try await fetchUsage(accessToken: cred.accessToken)
                let status = resp?.statusCode ?? 0
                DebugLog.log("[Claude] OAuth API returned \(status)")
                if status == 200 {
                    return try decodeAndBuild(data: data, now: now, source: "Claude API (OAuth)")
                }
                if status == 429 {
                    throw ProviderError.rateLimited
                }
                DebugLog.log("[Claude] OAuth failed with \(status), will try cookie fallback")
            } catch let error as ProviderError {
                if case .rateLimited = error {
                    DebugLog.log("[Claude] error: \(error.userMessage)")
                    return .unavailable(providerID: .claude, sourceLabel: "Claude API", notes: [error.userMessage])
                }
                DebugLog.log("[Claude] OAuth error: \(error.userMessage), will try cookie fallback")
            } catch {
                DebugLog.log("[Claude] OAuth error: \(error.localizedDescription), will try cookie fallback")
            }
        } else {
            DebugLog.log("[Claude] no OAuth credentials found, will try cookie fallback")
        }

        // Tier 2: Cookie fallback (implemented in Task 2)
        return await loadViaCookie(now: now)
    }

    // MARK: - Credential model

    private struct Credential: Sendable {
        let accessToken: String
    }

    // MARK: - Loading credentials

    private func loadCredential() -> Credential? {
        if let cred = loadFromFile() { return cred }
        if let cred = loadFromKeychain() { return cred }
        return nil
    }

    private func loadFromFile() -> Credential? {
        let credPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: credPath) else { return nil }
        return parseCredential(from: data)
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
        return parseCredential(from: data)
    }

    private func parseCredential(from data: Data) -> Credential? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = dict["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else { return nil }
        return Credential(accessToken: accessToken)
    }

    // MARK: - Cookie fallback

    private func loadViaCookie(now: Date) async -> ProviderSnapshot {
        return .unavailable(providerID: .claude, sourceLabel: "Claude API",
                            notes: ["No credentials available. Run `claude login` or set a browser cookie."],
                            isAuthError: true)
    }

    // MARK: - API

    private func fetchUsage(accessToken: String) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("UsageBar/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as? HTTPURLResponse)
    }

    // MARK: - Snapshot building

    private func decodeAndBuild(data: Data, now: Date, source: String = "Claude API") throws -> ProviderSnapshot {
        let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        return buildSnapshot(from: usage, now: now, sourceLabel: source)
    }

    private func buildSnapshot(from usage: ClaudeUsageResponse, now: Date, sourceLabel: String) -> ProviderSnapshot {
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
            sourceLabel: sourceLabel,
            metrics: metrics
        )
    }
}

// MARK: - JSON Models

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

    var isAuthError: Bool {
        switch self {
        case .noCredentials, .sessionExpired: true
        case .rateLimited, .apiError: false
        }
    }

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
