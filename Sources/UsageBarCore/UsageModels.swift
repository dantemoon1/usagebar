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
