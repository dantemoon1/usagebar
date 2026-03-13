import Foundation
import SwiftUI
import UserNotifications
import UsageBarCore

@MainActor
final class AppModel: ObservableObject {
    @AppStorage("displayMode") var displayModeRawValue = DisplayMode.dual.rawValue
    @AppStorage("singleBarProvider") var singleBarProviderRawValue = ProviderID.claude.rawValue
    @AppStorage("colorMode") var colorModeRawValue = ColorMode.color.rawValue
    @AppStorage("barWidth") var barWidthRaw: Double = 30
    @AppStorage("notificationsEnabled") var notificationsEnabled = true
    @AppStorage("sparklinesEnabled") var sparklinesEnabled = false
    @AppStorage("showPercentageLabel") var showPercentageLabel = false
    @AppStorage("notificationPreset") var notificationPresetRaw = NotificationPreset.standard.rawValue

    @Published private(set) var snapshot = UsageDashboardSnapshot(
        claude: .unavailable(providerID: .claude, sourceLabel: "Loading..."),
        codex: .unavailable(providerID: .codex, sourceLabel: "Loading..."),
        refreshedAt: Date()
    )
    @Published var claudeCookie: String = ""
    @Published private(set) var cookieValidation: CookieValidation = .none
    @Published private(set) var notificationsDenied = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var claudeFailures = 0
    @Published private(set) var codexFailures = 0

    private let coordinator = TelemetryCoordinator()
    let usageHistory = UsageHistory()
    private var refreshTask: Task<Void, Never>?
    private var cookieValidationTask: Task<Void, Never>?

    /// Number of consecutive failures before showing re-login prompt.
    private static let failureThreshold = 3

    /// Tracks which thresholds have already been notified, keyed by "provider-window".
    private var notifiedThresholds: [String: Set<Int>] = [:]
    /// Whether we've seeded thresholds from the initial snapshot (to avoid burst on launch).
    private var hasSeededThresholds = false

    init() {
        // Load cached data immediately so the UI isn't empty on launch
        if let cached = coordinator.loadCachedSnapshot() {
            snapshot = cached
        }
        claudeCookie = loadStoredCookie()
        if notificationsEnabled { requestNotificationPermission() }
        // Delay first API call to avoid rate limits on rapid restarts
        startRefreshLoop(initialDelay: 5)
    }

    deinit {
        refreshTask?.cancel()
        cookieValidationTask?.cancel()
    }

    var notificationPreset: NotificationPreset {
        get { NotificationPreset(rawValue: notificationPresetRaw) ?? .standard }
        set {
            guard notificationPresetRaw != newValue.rawValue else { return }
            notificationPresetRaw = newValue.rawValue
            notifiedThresholds.removeAll()
            hasSeededThresholds = false
            objectWillChange.send()
        }
    }

    var displayMode: DisplayMode {
        get { DisplayMode(rawValue: displayModeRawValue) ?? .single }
        set { displayModeRawValue = newValue.rawValue; objectWillChange.send() }
    }

    var singleBarProvider: ProviderID {
        get { ProviderID(rawValue: singleBarProviderRawValue) ?? .claude }
        set { singleBarProviderRawValue = newValue.rawValue; objectWillChange.send() }
    }

    var colorMode: ColorMode {
        get { ColorMode(rawValue: colorModeRawValue) ?? .color }
        set { colorModeRawValue = newValue.rawValue; objectWillChange.send() }
    }

    var barWidth: Double {
        get { min(max(barWidthRaw, 20), 60) }
        set { barWidthRaw = min(max(newValue, 20), 60); objectWillChange.send() }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let updated = await coordinator.loadSnapshot()

            // Track auth failures per provider since last success (rate limits/transient errors don't reset the count)
            if updated.claude.isAvailable { claudeFailures = 0 }
            else if updated.claude.isAuthError { claudeFailures += 1 }

            if updated.codex.isAvailable { codexFailures = 0 }
            else if updated.codex.isAuthError { codexFailures += 1 }

            // Keep old good data on transient errors, but replace after threshold
            let claude: ProviderSnapshot
            if updated.claude.isAvailable {
                claude = updated.claude
            } else if snapshot.claude.isAvailable && claudeFailures < Self.failureThreshold {
                claude = snapshot.claude
            } else {
                claude = updated.claude
            }

            let codex: ProviderSnapshot
            if updated.codex.isAvailable {
                codex = updated.codex
            } else if snapshot.codex.isAvailable && codexFailures < Self.failureThreshold {
                codex = snapshot.codex
            } else {
                codex = updated.codex
            }

            let newSnapshot = UsageDashboardSnapshot(claude: claude, codex: codex, refreshedAt: updated.refreshedAt)
            self.snapshot = newSnapshot
            self.usageHistory.record(updated)
            self.checkNotifications(for: newSnapshot)
            self.isRefreshing = false
        }
    }

    func providerSnapshot(for providerID: ProviderID) -> ProviderSnapshot {
        switch providerID {
        case .claude: snapshot.claude
        case .codex: snapshot.codex
        }
    }

    private func loadStoredCookie() -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".usagebar/claude-cookie.txt")
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func saveClaudeCookie(_ cookie: String) {
        DebugLog.log("[Claude] cookie pasted (\(cookie.count) chars)")
        claudeCookie = cookie
        ClaudeAPIProvider.saveCookie(cookie)
        validateCookie()
    }

    func clearClaudeCookie() {
        DebugLog.log("[Claude] cookie cleared by user")
        cookieValidationTask?.cancel()
        cookieValidationTask = nil
        claudeCookie = ""
        cookieValidation = .none
        ClaudeAPIProvider.clearCookie()
    }

    func validateCookie() {
        let cookie = claudeCookie

        guard !cookie.isEmpty else {
            cookieValidation = .none
            return
        }

        // Check for required cookie fields
        let hasSessionKey = cookie.contains("sessionKey=")
        let hasLastActiveOrg = cookie.contains("lastActiveOrg=")
        guard hasSessionKey, hasLastActiveOrg else {
            cookieValidation = .invalid("Cookie missing required fields (sessionKey, lastActiveOrg)")
            return
        }

        // Extract org ID and try hitting the API
        cookieValidationTask?.cancel()
        cookieValidation = .validating
        cookieValidationTask = Task { [cookie] in
            let result = await ClaudeAPIProvider.validateCookie(cookie)
            guard !Task.isCancelled, self.claudeCookie == cookie else { return }
            self.cookieValidation = result ? .valid : .invalid("API request failed. Cookie may be expired.")
            if result { self.refresh() }
        }
    }

    // MARK: - Notifications

    private func checkNotifications(for snapshot: UsageDashboardSnapshot) {
        guard notificationsEnabled else { return }
        let thresholds = notificationPreset.thresholds
        guard !thresholds.isEmpty else { return }

        // On first check, seed already-passed thresholds so we don't fire a burst of stale alerts.
        let isFirstCheck = !hasSeededThresholds
        if isFirstCheck { hasSeededThresholds = true }

        for provider in [snapshot.claude, snapshot.codex] {
            for window in [provider.fiveHourWindow, provider.sevenDayWindow].compactMap({ $0 }) {
                let key = "\(provider.providerID.rawValue)-\(window.kind.rawValue)"
                let percent = Int(window.usedPercent)

                // Reset tracked thresholds if usage dropped (new reset window)
                if let existing = notifiedThresholds[key], let maxNotified = existing.max(), percent < maxNotified - 10 {
                    notifiedThresholds[key] = []
                }

                // Collect all newly-crossed thresholds, but only notify for the highest
                var highestNew: Int?
                for threshold in thresholds where percent >= threshold {
                    if notifiedThresholds[key, default: []].contains(threshold) { continue }
                    notifiedThresholds[key, default: []].insert(threshold)
                    if !isFirstCheck {
                        highestNew = threshold
                    }
                }

                if let threshold = highestNew {
                    sendNotification(
                        provider: provider.providerID.displayName,
                        window: window.kind.displayName,
                        percent: percent,
                        threshold: threshold
                    )
                }
            }
        }
    }

    private func sendNotification(provider: String, window: String, percent: Int, threshold: Int) {
        DebugLog.log("[Notifications] sending: \(provider) \(window) at \(percent)% (threshold \(threshold)%)")
        let content = UNMutableNotificationContent()
        content.title = "\(provider) Usage: \(percent)%"
        content.body = "\(window) window has reached \(threshold)% usage."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(provider)-\(window)-\(threshold)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func requestNotificationPermission() {
        DebugLog.log("[Notifications] requesting permission")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DebugLog.log("[Notifications] permission granted: \(granted)")
            Task { @MainActor in
                self?.notificationsDenied = !granted
            }
        }
    }

    func checkNotificationPermission() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self.notificationsDenied = settings.authorizationStatus == .denied
        }
    }

    /// Returns refresh interval: 60s when any window is above 80%, 180s otherwise.
    private var adaptiveRefreshInterval: Int {
        let maxUsage = [
            snapshot.claude.fiveHourWindow?.usedPercent,
            snapshot.claude.sevenDayWindow?.usedPercent,
            snapshot.codex.fiveHourWindow?.usedPercent,
            snapshot.codex.sevenDayWindow?.usedPercent,
        ].compactMap { $0 }.max() ?? 0
        return maxUsage >= 80 ? 60 : 180
    }

    private func startRefreshLoop(initialDelay: Int) {
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(initialDelay))
                await MainActor.run { self?.refresh() }
                while !Task.isCancelled {
                    let interval = await MainActor.run { self?.adaptiveRefreshInterval ?? 180 }
                    try await Task.sleep(for: .seconds(interval))
                    await MainActor.run { self?.refresh() }
                }
            } catch {}
        }
    }
}

enum CookieValidation: Equatable {
    case none
    case validating
    case valid
    case invalid(String)
}

enum DisplayMode: String, CaseIterable {
    case single, dual
    var title: String {
        switch self {
        case .single: "Single Bar"
        case .dual: "Dual Bar"
        }
    }
}

enum ColorMode: String, CaseIterable {
    case color, monochrome
    var title: String {
        switch self {
        case .color: "Color"
        case .monochrome: "Mono"
        }
    }
}

enum NotificationPreset: String, CaseIterable {
    case standard, conservative, minimal, off

    var title: String {
        switch self {
        case .standard: "Standard"
        case .conservative: "Conservative"
        case .minimal: "Minimal"
        case .off: "Off"
        }
    }

    var thresholds: [Int] {
        switch self {
        case .standard: [50, 75, 90, 95, 99]
        case .conservative: [75, 90, 95]
        case .minimal: [90, 99]
        case .off: []
        }
    }

    var caption: String {
        switch self {
        case .standard: "Alerts at 50%, 75%, 90%, 95%, 99%"
        case .conservative: "Alerts at 75%, 90%, 95%"
        case .minimal: "Alerts at 90%, 99%"
        case .off: "No usage notifications"
        }
    }
}
