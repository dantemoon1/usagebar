import Foundation

public enum ProviderID: String, CaseIterable, Codable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

public enum QuotaWindowKind: String, CaseIterable, Codable, Sendable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"

    public var displayName: String {
        switch self {
        case .fiveHour: "5h"
        case .sevenDay: "7-day"
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
    public let fiveHourWindow: QuotaWindowSnapshot?
    public let sevenDayWindow: QuotaWindowSnapshot?
    public let lastUpdatedAt: Date?
    public let sourceLabel: String
    public let notes: [String]
    public let metrics: [ExpandedMetric]
    public let isAuthError: Bool

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
        self.providerID = providerID
        self.fiveHourWindow = fiveHourWindow
        self.sevenDayWindow = sevenDayWindow
        self.lastUpdatedAt = lastUpdatedAt
        self.sourceLabel = sourceLabel
        self.notes = notes
        self.metrics = metrics
        self.isAuthError = isAuthError
    }

    public var isAvailable: Bool {
        fiveHourWindow != nil || sevenDayWindow != nil
    }

    public var errorKind: ErrorKind {
        guard !isAvailable else { return .none }
        if isAuthError {
            // Distinguish "no credentials at all" from "credentials expired"
            let hasLoginHint = notes.contains { $0.contains("No credentials") || $0.contains("Set a browser cookie") || $0.contains("missing org ID") }
            return hasLoginHint ? .needsLogin : .cookieExpired
        }
        if notes.contains(where: { $0.lowercased().contains("rate limit") }) {
            return .rateLimited
        }
        if !notes.isEmpty {
            return .apiError
        }
        return .needsLogin // fallback for unavailable with no notes
    }

    /// The highest usage percentage across all windows, or nil if unavailable.
    public var peakPercent: Double? {
        [fiveHourWindow?.usedPercent, sevenDayWindow?.usedPercent]
            .compactMap { $0 }.max()
    }

    public func window(for kind: QuotaWindowKind) -> QuotaWindowSnapshot? {
        switch kind {
        case .fiveHour: fiveHourWindow
        case .sevenDay: sevenDayWindow
        }
    }

    public static func unavailable(providerID: ProviderID, sourceLabel: String, notes: [String] = [], isAuthError: Bool = false) -> Self {
        ProviderSnapshot(
            providerID: providerID,
            fiveHourWindow: nil,
            sevenDayWindow: nil,
            lastUpdatedAt: nil,
            sourceLabel: sourceLabel,
            notes: notes,
            isAuthError: isAuthError
        )
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
    public let refreshedAt: Date

    public init(claude: ProviderSnapshot, codex: ProviderSnapshot, refreshedAt: Date) {
        self.claude = claude
        self.codex = codex
        self.refreshedAt = refreshedAt
    }
}
