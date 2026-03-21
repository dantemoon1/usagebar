import Foundation

public enum ProviderID: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case cursor

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    public var usageURL: URL? {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")
        case .codex: URL(string: "https://chatgpt.com/admin/usage")
        case .cursor: URL(string: "https://www.cursor.com/settings")
        }
    }
}

public enum QuotaWindowKind: String, CaseIterable, Codable, Sendable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case monthly = "monthly"

    public var displayName: String {
        switch self {
        case .fiveHour: "5h"
        case .sevenDay: "7-day"
        case .monthly: "Monthly"
        }
    }
}

public struct QuotaWindowSnapshot: Equatable, Sendable, Codable {
    public let kind: QuotaWindowKind
    public let usedPercent: Double
    public let resetAt: Date?

    public init(kind: QuotaWindowKind, usedPercent: Double, resetAt: Date?) {
        self.kind = kind
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetAt = resetAt
    }
}

public struct ExpandedMetric: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct ProviderSnapshot: Equatable, Sendable, Codable {
    public let providerID: ProviderID
    public let windows: [QuotaWindowSnapshot]
    public let lastUpdatedAt: Date?
    public let sourceLabel: String
    public let notes: [String]
    public let metrics: [ExpandedMetric]
    public let isAuthError: Bool

    public init(
        providerID: ProviderID,
        windows: [QuotaWindowSnapshot],
        lastUpdatedAt: Date?,
        sourceLabel: String,
        notes: [String] = [],
        metrics: [ExpandedMetric] = [],
        isAuthError: Bool = false
    ) {
        self.providerID = providerID
        self.windows = windows
        self.lastUpdatedAt = lastUpdatedAt
        self.sourceLabel = sourceLabel
        self.notes = notes
        self.metrics = metrics
        self.isAuthError = isAuthError
    }

    /// Convenience initializer for providers with two windows (Claude, Codex).
    public init(
        providerID: ProviderID,
        fiveHourWindow: QuotaWindowSnapshot?,
        sevenDayWindow: QuotaWindowSnapshot?,
        lastUpdatedAt: Date?,
        sourceLabel: String,
        notes: [String] = [],
        metrics: [ExpandedMetric] = [],
        isAuthError: Bool = false
    ) {
        self.init(
            providerID: providerID,
            windows: [fiveHourWindow, sevenDayWindow].compactMap { $0 },
            lastUpdatedAt: lastUpdatedAt,
            sourceLabel: sourceLabel,
            notes: notes,
            metrics: metrics,
            isAuthError: isAuthError
        )
    }

    public var fiveHourWindow: QuotaWindowSnapshot? { window(for: .fiveHour) }
    public var sevenDayWindow: QuotaWindowSnapshot? { window(for: .sevenDay) }

    public var hasQuotaData: Bool {
        !windows.isEmpty
    }

    public var isAvailable: Bool {
        hasQuotaData || !metrics.isEmpty
    }

    public var errorKind: ErrorKind {
        guard !isAvailable else { return .none }
        if lastUpdatedAt == nil && sourceLabel.localizedCaseInsensitiveContains("loading") {
            return .none
        }
        if isAuthError {
            let hasLoginHint = notes.contains { note in
                let normalized = note.lowercased()
                return normalized.contains("no credentials")
                    || normalized.contains("set a browser cookie")
                    || normalized.contains("missing org id")
            }
            return hasLoginHint ? .needsLogin : .cookieExpired
        }
        if notes.contains(where: { $0.lowercased().contains("rate limit") }) {
            return .rateLimited
        }
        if !notes.isEmpty {
            return .apiError
        }
        return .needsLogin
    }

    /// The highest usage percentage across all windows, or nil if unavailable.
    public var peakPercent: Double? {
        windows.map(\.usedPercent).max()
    }

    public func window(for kind: QuotaWindowKind) -> QuotaWindowSnapshot? {
        windows.first { $0.kind == kind }
    }

    public static func unavailable(providerID: ProviderID, sourceLabel: String, notes: [String] = [], isAuthError: Bool = false) -> Self {
        ProviderSnapshot(
            providerID: providerID,
            windows: [],
            lastUpdatedAt: nil,
            sourceLabel: sourceLabel,
            notes: notes,
            isAuthError: isAuthError
        )
    }

    // MARK: - Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case providerID, windows, lastUpdatedAt, sourceLabel, notes, metrics, isAuthError
        case fiveHourWindow, sevenDayWindow // legacy
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(lastUpdatedAt, forKey: .lastUpdatedAt)
        try container.encode(sourceLabel, forKey: .sourceLabel)
        try container.encode(notes, forKey: .notes)
        try container.encode(metrics, forKey: .metrics)
        try container.encode(isAuthError, forKey: .isAuthError)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(ProviderID.self, forKey: .providerID)
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
        notes = try container.decode([String].self, forKey: .notes)
        metrics = try container.decode([ExpandedMetric].self, forKey: .metrics)
        isAuthError = try container.decode(Bool.self, forKey: .isAuthError)

        // Try new format first, fall back to legacy
        if let w = try? container.decode([QuotaWindowSnapshot].self, forKey: .windows) {
            windows = w
        } else {
            let five = try container.decodeIfPresent(QuotaWindowSnapshot.self, forKey: .fiveHourWindow)
            let seven = try container.decodeIfPresent(QuotaWindowSnapshot.self, forKey: .sevenDayWindow)
            windows = [five, seven].compactMap { $0 }
        }
    }
}

public enum ErrorKind: Equatable, Sendable {
    case none
    case needsLogin
    case cookieExpired
    case rateLimited
    case apiError

    public var icon: String {
        switch self {
        case .none: "checkmark.circle"
        case .needsLogin: "person.crop.circle.badge.questionmark"
        case .cookieExpired: "key.slash"
        case .rateLimited: "hourglass"
        case .apiError: "exclamationmark.icloud"
        }
    }

    public var title: String {
        switch self {
        case .none: ""
        case .needsLogin: "Setup required"
        case .cookieExpired: "Session expired"
        case .rateLimited: "Rate limited"
        case .apiError: "Service error"
        }
    }
}

public struct UsageDashboardSnapshot: Equatable, Sendable, Codable {
    public let claude: ProviderSnapshot
    public let codex: ProviderSnapshot
    public let cursor: ProviderSnapshot
    public let refreshedAt: Date

    public init(claude: ProviderSnapshot, codex: ProviderSnapshot, cursor: ProviderSnapshot, refreshedAt: Date) {
        self.claude = claude
        self.codex = codex
        self.cursor = cursor
        self.refreshedAt = refreshedAt
    }

    // Backward-compatible decoding for caches without cursor
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        claude = try container.decode(ProviderSnapshot.self, forKey: .claude)
        codex = try container.decode(ProviderSnapshot.self, forKey: .codex)
        cursor = try container.decodeIfPresent(ProviderSnapshot.self, forKey: .cursor)
            ?? .unavailable(providerID: .cursor, sourceLabel: "Not loaded")
        refreshedAt = try container.decode(Date.self, forKey: .refreshedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case claude, codex, cursor, refreshedAt
    }
}
