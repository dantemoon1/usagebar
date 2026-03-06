import Foundation
import SwiftUI
import UsageBarCore

@MainActor
final class AppModel: ObservableObject {
    @AppStorage("displayMode") var displayModeRawValue = DisplayMode.dual.rawValue
    @AppStorage("singleBarProvider") var singleBarProviderRawValue = ProviderID.claude.rawValue
    @AppStorage("colorMode") var colorModeRawValue = ColorMode.color.rawValue
    @AppStorage("barWidth") var barWidthRaw: Double = 30

    @Published private(set) var snapshot = UsageDashboardSnapshot(
        claude: .unavailable(providerID: .claude, sourceLabel: "Loading..."),
        codex: .unavailable(providerID: .codex, sourceLabel: "Loading..."),
        refreshedAt: Date()
    )
    @Published private(set) var isRefreshing = false
    @Published private(set) var claudeFailures = 0
    @Published private(set) var codexFailures = 0

    private let coordinator = TelemetryCoordinator()
    private var refreshTask: Task<Void, Never>?

    /// Number of consecutive failures before showing re-login prompt.
    private static let failureThreshold = 3

    init() {
        // Load cached data immediately so the UI isn't empty on launch
        if let cached = coordinator.loadCachedSnapshot() {
            snapshot = cached
        }
        // Delay first API call to avoid rate limits on rapid restarts
        startRefreshLoop(initialDelay: 5)
    }

    deinit { refreshTask?.cancel() }

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
        get { barWidthRaw }
        set { barWidthRaw = newValue; objectWillChange.send() }
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let updated = await coordinator.loadSnapshot()

            // Track consecutive failures per provider
            claudeFailures = updated.claude.isAvailable ? 0 : claudeFailures + 1
            codexFailures = updated.codex.isAvailable ? 0 : codexFailures + 1

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

            self.snapshot = UsageDashboardSnapshot(claude: claude, codex: codex, refreshedAt: updated.refreshedAt)
            self.isRefreshing = false
        }
    }

    var claudeNeedsRelogin: Bool { claudeFailures >= Self.failureThreshold }
    var codexNeedsRelogin: Bool { codexFailures >= Self.failureThreshold }

    func providerSnapshot(for providerID: ProviderID) -> ProviderSnapshot {
        switch providerID {
        case .claude: snapshot.claude
        case .codex: snapshot.codex
        }
    }

    private func startRefreshLoop(initialDelay: Int) {
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(initialDelay))
            await MainActor.run { self?.refresh() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                await MainActor.run { self?.refresh() }
            }
        }
    }
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
