import Foundation

public enum LaunchAtLogin {
    private static let agentLabel = "com.usagebar.app"
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    public static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public static func setEnabled(_ enabled: Bool, executablePath: String? = nil) {
        if enabled {
            enable(executablePath: executablePath)
        } else {
            disable()
        }
    }

    private static func enable(executablePath: String?) {
        let path = executablePath ?? resolveExecutablePath()
        guard let path else { return }

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]

        // Ensure LaunchAgents directory exists
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try? data?.write(to: plistURL)
    }

    private static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func resolveExecutablePath() -> String? {
        // Get the path of the currently running executable
        let path = ProcessInfo.processInfo.arguments.first
        guard let path, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        // Resolve to absolute path
        if path.hasPrefix("/") {
            return path
        }
        return FileManager.default.currentDirectoryPath + "/" + path
    }
}
