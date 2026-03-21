import Foundation

/// Lightweight rolling history of usage percentages for sparklines.
/// Stores up to 24h of samples in a flat JSON array file.
public struct UsageHistory: Sendable {
    private static let resetDropThreshold = 1.0
    private static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".usagebar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-history.json")
    }()

    /// Maximum age of entries to keep.
    private static let maxAge: TimeInterval = 24 * 60 * 60

    public init() {}

    public func record(_ snapshot: UsageDashboardSnapshot) {
        var entries = load()
        entries.append(HistoryEntry(snapshot: snapshot))
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        entries.removeAll { $0.timestamp < cutoff }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    public func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        return entries.filter { $0.timestamp >= cutoff }
    }

    /// Returns recent percentage values for a specific provider + window.
    public func values(provider: ProviderID, window: QuotaWindowKind) -> [Double] {
        load().compactMap { entry in
            entry.value(provider: provider, window: window)
        }
    }

    /// Returns the largest positive usage delta for any window of a provider
    /// over the given lookback interval. Used by auto mode to detect activity.
    public func recentPositiveDelta(provider: ProviderID, over interval: TimeInterval = 3600) -> Double {
        let entries = load()
        let cutoff = Date().addingTimeInterval(-interval)
        let recent = entries.filter { $0.timestamp >= cutoff }
        guard !recent.isEmpty else { return 0 }

        let windows: [QuotaWindowKind] = [.fiveHour, .sevenDay, .monthly]
        var maxDelta = 0.0

        for window in windows {
            let values = recent.compactMap { e -> (Date, Double)? in
                guard let v = e.value(provider: provider, window: window) else { return nil }
                return (e.timestamp, v)
            }
            guard let segment = currentSegment(from: values),
                  let first = segment.first,
                  let last = segment.last else { continue }
            let delta = last.1 - first.1
            if delta > maxDelta { maxDelta = delta }
        }

        return maxDelta
    }

    /// Computes burn rate from recent history.
    /// Returns `nil` if there isn't enough data or usage is flat/decreasing.
    public func burnRate(provider: ProviderID, window: QuotaWindowKind, currentPercent: Double) -> BurnRate? {
        let relevant = load().compactMap { e -> (Date, Double)? in
            guard let v = e.value(provider: provider, window: window) else { return nil }
            return (e.timestamp, v)
        }
        guard let segment = currentSegment(from: relevant),
              segment.count >= 2,
              let first = segment.first,
              let last = segment.last else { return nil }

        let elapsed = last.0.timeIntervalSince(first.0)
        guard elapsed > 60 else { return nil } // need at least a minute of data

        let delta = last.1 - first.1
        guard delta > 0 else { return nil } // only show when usage is increasing

        let ratePerHour = delta / (elapsed / 3600)
        let remaining = 100.0 - currentPercent
        guard remaining > 0 else { return nil }

        let hoursToFull = remaining / ratePerHour
        return BurnRate(percentPerHour: ratePerHour, hoursToFull: hoursToFull)
    }

    private func currentSegment(from relevant: [(Date, Double)]) -> [(Date, Double)]? {
        guard !relevant.isEmpty else { return nil }

        var startIndex = relevant.startIndex
        for index in relevant.indices.dropFirst() {
            let previous = relevant[relevant.index(before: index)].1
            let current = relevant[index].1
            if current + Self.resetDropThreshold < previous {
                startIndex = index
            }
        }

        let segment = Array(relevant[startIndex...])
        guard segment.count >= 2,
              let first = segment.first,
              let last = segment.last,
              last.0.timeIntervalSince(first.0) > 0 else { return nil }
        return segment
    }
}

public struct BurnRate: Sendable {
    public static let actionableProjectionThresholdHours: Double = 12

    public let percentPerHour: Double
    public let hoursToFull: Double

    public var projectionText: String {
        if hoursToFull > 24 {
            return ">24h to 100%"
        }
        let totalMinutes = Int(hoursToFull * 60)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return "~\(h)h \(m)m to 100%"
        }
        return "~\(m)m to 100%"
    }

    public var isActionable: Bool {
        hoursToFull <= Self.actionableProjectionThresholdHours
    }
}

public struct HistoryEntry: Codable, Sendable {
    public let timestamp: Date
    public let claudeFiveHour: Double?
    public let claudeSevenDay: Double?
    public let codexFiveHour: Double?
    public let codexSevenDay: Double?
    public let cursorMonthly: Double?

    public init(snapshot: UsageDashboardSnapshot) {
        self.timestamp = snapshot.refreshedAt
        self.claudeFiveHour = snapshot.claude.fiveHourWindow?.usedPercent
        self.claudeSevenDay = snapshot.claude.sevenDayWindow?.usedPercent
        self.codexFiveHour = snapshot.codex.fiveHourWindow?.usedPercent
        self.codexSevenDay = snapshot.codex.sevenDayWindow?.usedPercent
        self.cursorMonthly = snapshot.cursor.window(for: .monthly)?.usedPercent
    }

    public func value(provider: ProviderID, window: QuotaWindowKind) -> Double? {
        switch (provider, window) {
        case (.claude, .fiveHour): claudeFiveHour
        case (.claude, .sevenDay): claudeSevenDay
        case (.codex, .fiveHour): codexFiveHour
        case (.codex, .sevenDay): codexSevenDay
        case (.cursor, .monthly): cursorMonthly
        default: nil
        }
    }
}
