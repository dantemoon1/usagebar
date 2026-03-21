import Foundation

/// Fetches Cursor usage data via the usage-summary endpoint.
/// Reads credentials from the Cursor SQLite database at
/// ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb.
public struct CursorAPIProvider: ProviderSnapshotLoader {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func loadSnapshot(now: Date) async -> ProviderSnapshot {
        do {
            let cred = try await loadCredential()
            let (data, resp) = try await fetchUsageSummary(cookie: cred.cookie)
            let status = resp?.statusCode ?? 0

            if status == 200 {
                return try decodeAndBuild(data: data, now: now)
            }

            if status == 401 || status == 403 {
                throw ProviderError.sessionExpired("Cursor session expired. Re-sign in to Cursor.")
            }

            if status == 429 {
                throw ProviderError.rateLimited
            }

            throw ProviderError.apiError("Cursor API returned \(status). Please try again later.")
        } catch let error as ProviderError {
            return .unavailable(providerID: .cursor, sourceLabel: "Cursor API", notes: [error.userMessage], isAuthError: error.isAuthError)
        } catch {
            return .unavailable(providerID: .cursor, sourceLabel: "Cursor API", notes: [error.localizedDescription])
        }
    }

    // MARK: - Credential

    private struct Credential {
        let userId: String
        let accessToken: String
        var cookie: String { "\(userId)%3A%3A\(accessToken)" }
    }

    private func loadCredential() async throws -> Credential {
        let dbPath = homeDirectory
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ProviderError.noCredentials("No credentials found for Cursor. Install Cursor and sign in.")
        }

        let accessToken = try await runSqlite(dbPath: dbPath, query: "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';")
        guard !accessToken.isEmpty else {
            throw ProviderError.noCredentials("No credentials found for Cursor. Sign in to Cursor.")
        }

        let userId = try extractUserId(from: accessToken)
        return Credential(userId: userId, accessToken: accessToken)
    }

    private func runSqlite(dbPath: String, query: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-noheader", "-batch", dbPath, query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                guard proc.terminationStatus == 0 else {
                    continuation.resume(throwing: ProviderError.apiError("Failed to read Cursor database"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: result)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Extracts the user ID (e.g. "user_01HV63BC...") from the JWT's `sub` claim.
    private func extractUserId(from jwt: String) throws -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            throw ProviderError.noCredentials("Invalid Cursor token format")
        }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        while base64.count % 4 != 0 { base64.append("=") }

        guard let payloadData = Data(base64Encoded: base64) else {
            throw ProviderError.noCredentials("Failed to decode Cursor token")
        }

        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let sub = json["sub"] as? String else {
            throw ProviderError.noCredentials("Missing sub claim in Cursor token")
        }

        // sub is "google-oauth2|user_XXXX" — extract after the pipe
        if let pipeIndex = sub.lastIndex(of: "|") {
            return String(sub[sub.index(after: pipeIndex)...])
        }
        return sub
    }

    // MARK: - API

    private func fetchUsageSummary(cookie: String) async throws -> (Data, HTTPURLResponse?) {
        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.timeoutInterval = 30
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("UsageBar/0.2", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as? HTTPURLResponse)
    }

    // MARK: - Snapshot building

    private func decodeAndBuild(data: Data, now: Date) throws -> ProviderSnapshot {
        let usage = try JSONDecoder().decode(CursorUsageSummary.self, from: data)
        return buildSnapshot(from: usage, now: now)
    }

    private func buildSnapshot(from usage: CursorUsageSummary, now: Date) -> ProviderSnapshot {
        let plan = usage.individualUsage?.plan
        let onDemand = usage.individualUsage?.onDemand

        let resetAt = usage.billingCycleEnd.flatMap { dateString -> Date? in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
        }

        var windows: [QuotaWindowSnapshot] = []

        if let plan, plan.limit > 0 {
            let percent = plan.totalPercentUsed ?? (Double(plan.used) / Double(plan.limit) * 100)
            windows.append(QuotaWindowSnapshot(kind: .monthly, usedPercent: percent, resetAt: resetAt))
        }

        var metrics: [ExpandedMetric] = []

        if let plan, plan.limit > 0 {
            let usedDollars = String(format: "$%.2f", Double(plan.used) / 100.0)
            let limitDollars = String(format: "$%.2f", Double(plan.limit) / 100.0)
            metrics.append(ExpandedMetric(id: "cursor-plan", label: "Included", value: "\(usedDollars) / \(limitDollars)"))
        }

        if let onDemand, onDemand.enabled, let used = onDemand.used {
            let usedDollars = String(format: "$%.2f", Double(used) / 100.0)
            if let limit = onDemand.limit {
                let limitDollars = String(format: "$%.2f", Double(limit) / 100.0)
                metrics.append(ExpandedMetric(id: "cursor-ondemand", label: "On-demand", value: "\(usedDollars) / \(limitDollars)"))
            } else {
                metrics.append(ExpandedMetric(id: "cursor-ondemand", label: "On-demand", value: usedDollars))
            }
        }

        if let membership = usage.membershipType {
            metrics.append(ExpandedMetric(id: "cursor-plan-type", label: "Plan", value: membership.capitalized))
        }

        return ProviderSnapshot(
            providerID: .cursor,
            windows: windows,
            lastUpdatedAt: now,
            sourceLabel: "Cursor API",
            metrics: metrics
        )
    }
}

// MARK: - JSON models

private struct CursorUsageSummary: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let individualUsage: CursorIndividualUsage?
}

private struct CursorIndividualUsage: Decodable {
    let plan: CursorPlanUsage?
    let onDemand: CursorOnDemandUsage?
}

private struct CursorPlanUsage: Decodable {
    let used: Int
    let limit: Int
    let totalPercentUsed: Double?
}

private struct CursorOnDemandUsage: Decodable {
    let enabled: Bool
    let used: Int?
    let limit: Int?
}
