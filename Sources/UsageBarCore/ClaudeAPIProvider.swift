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
                    DebugLog.log("[Claude] OAuth rate limited, will try cookie fallback")
                } else {
                    DebugLog.log("[Claude] OAuth failed with \(status), will try cookie fallback")
                }
            } catch let error as ProviderError {
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

    // MARK: - Cookie storage

    private static let cookieFileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".usagebar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("claude-cookie.txt")
    }()

    private func loadCookie() -> String? {
        guard let data = try? Data(contentsOf: Self.cookieFileURL) else { return nil }
        let cookie = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cookie?.isEmpty == false) ? cookie : nil
    }

    public static func saveCookie(_ cookie: String) {
        let dir = cookieFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8) {
            FileManager.default.createFile(
                atPath: cookieFileURL.path, contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        }
    }

    public static func clearCookie() {
        try? FileManager.default.removeItem(at: cookieFileURL)
    }

    // MARK: - Org ID extraction

    private static func extractOrgId(from cookie: String) -> String? {
        for part in cookie.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("lastActiveOrg=") {
                return trimmed.replacingOccurrences(of: "lastActiveOrg=", with: "")
            }
        }
        return nil
    }

    // MARK: - Cookie validation

    /// Validates a cookie by making a test request to the claude.ai usage API.
    public static func validateCookie(_ cookie: String) async -> Bool {
        guard let orgId = extractOrgId(from: cookie) else { return false }
        guard let url = URL(string: "\(webUsageURLBase)\(orgId)/usage") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DebugLog.log("[Claude] cookie validation returned \(status)")
            return status == 200
        } catch {
            DebugLog.log("[Claude] cookie validation error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Cookie fallback

    private static let webUsageURLBase = "https://claude.ai/api/organizations/"

    private func loadViaCookie(now: Date) async -> ProviderSnapshot {
        guard let cookie = loadCookie() else {
            DebugLog.log("[Claude] no cookie stored")
            return .unavailable(providerID: .claude, sourceLabel: "Claude API",
                                notes: ["No credentials available. Set a browser cookie in settings or run `claude` then `/login`."],
                                isAuthError: true)
        }
        guard let orgId = Self.extractOrgId(from: cookie) else {
            DebugLog.log("[Claude] cookie missing lastActiveOrg")
            return .unavailable(providerID: .claude, sourceLabel: "Claude API",
                                notes: ["Cookie missing org ID. Re-copy the full cookie from claude.ai."],
                                isAuthError: true)
        }

        do {
            let (data, resp) = try await fetchUsageWithCookie(cookie: cookie, orgId: orgId)
            let status = resp?.statusCode ?? 0
            DebugLog.log("[Claude] cookie API returned \(status)")

            if status == 200 {
                return try decodeAndBuild(data: data, now: now, source: "Claude API (cookie)")
            }
            if status == 429 {
                DebugLog.log("[Claude] cookie rate limited")
                return .unavailable(providerID: .claude, sourceLabel: "Claude API", notes: ["Rate limited. Will retry on next refresh."])
            }

            let body = String(data: data, encoding: .utf8) ?? ""
            DebugLog.log("[Claude] cookie failed \(status): \(body.prefix(200))")
            return .unavailable(providerID: .claude, sourceLabel: "Claude API",
                                notes: ["Cookie auth failed (\(status)). Re-copy cookie from claude.ai."],
                                isAuthError: true)
        } catch {
            DebugLog.log("[Claude] cookie error: \(error.localizedDescription)")
            return .unavailable(providerID: .claude, sourceLabel: "Claude API",
                                notes: [error.localizedDescription])
        }
    }

    private func fetchUsageWithCookie(cookie: String, orgId: String) async throws -> (Data, HTTPURLResponse?) {
        guard let url = URL(string: "\(Self.webUsageURLBase)\(orgId)/usage") else {
            throw ProviderError.apiError("Invalid URL for org \(orgId)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as? HTTPURLResponse)
    }

    // MARK: - API

    private func fetchUsage(accessToken: String) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("UsageBar/0.2", forHTTPHeaderField: "User-Agent")
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
