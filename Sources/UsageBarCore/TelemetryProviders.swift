import Foundation

public protocol ProviderSnapshotLoader: Sendable {
    func loadSnapshot(now: Date) async -> ProviderSnapshot
}

public struct TelemetryCoordinator: Sendable {
    private let claudeLoader: any ProviderSnapshotLoader
    private let codexLoader: any ProviderSnapshotLoader
    private let cursorLoader: any ProviderSnapshotLoader

    public init() {
        self.claudeLoader = ClaudeAPIProvider()
        self.codexLoader = CodexAPIProvider()
        self.cursorLoader = CursorAPIProvider()
    }

    public func loadSnapshot(now: Date = Date()) async -> UsageDashboardSnapshot {
        async let claude = claudeLoader.loadSnapshot(now: now)
        async let codex = codexLoader.loadSnapshot(now: now)
        async let cursor = cursorLoader.loadSnapshot(now: now)
        let snapshot = await UsageDashboardSnapshot(claude: claude, codex: codex, cursor: cursor, refreshedAt: now)
        // Only cache providers that succeeded, preserving last-known-good data for failed ones
        SnapshotCache.saveSelective(snapshot)
        return snapshot
    }

    /// Returns cached snapshot from disk, or nil if no cache exists.
    public func loadCachedSnapshot() -> UsageDashboardSnapshot? {
        SnapshotCache.load()
    }
}

// MARK: - Disk cache

enum SnapshotCache {
    private static let cacheURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".usagebar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snapshot-cache.json")
    }()

    static func save(_ snapshot: UsageDashboardSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Only preserves cached provider data on transient errors (rate limits, network issues).
    /// Auth errors overwrite the cache so restarts surface the re-login prompt.
    static func saveSelective(_ snapshot: UsageDashboardSnapshot) {
        let existing = load()
        let claude = snapshot.claude.isAvailable || snapshot.claude.isAuthError
            ? snapshot.claude : (existing?.claude ?? snapshot.claude)
        let codex = snapshot.codex.isAvailable || snapshot.codex.isAuthError
            ? snapshot.codex : (existing?.codex ?? snapshot.codex)
        let cursor = snapshot.cursor.isAvailable || snapshot.cursor.isAuthError
            ? snapshot.cursor : (existing?.cursor ?? snapshot.cursor)
        let merged = UsageDashboardSnapshot(claude: claude, codex: codex, cursor: cursor, refreshedAt: snapshot.refreshedAt)
        save(merged)
    }

    static func load() -> UsageDashboardSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(UsageDashboardSnapshot.self, from: data)
    }
}
