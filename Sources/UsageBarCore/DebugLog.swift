import Foundation

public enum DebugLog {
    private static let queue = DispatchQueue(label: "usagebar.debug-log")

    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".usagebar")
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("debug.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func log(_ message: String) {
        queue.sync {
            let timestamp = formatter.string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logURL) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    FileManager.default.createFile(
                        atPath: logURL.path,
                        contents: data,
                        attributes: [.posixPermissions: 0o600]
                    )
                }
            }
        }
    }

    /// Truncate log if it gets too large (> 2MB)
    public static func trimIfNeeded() {
        queue.sync {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
                  let size = attrs[.size] as? Int, size > 2_000_000 else { return }
            guard let data = try? Data(contentsOf: logURL),
                  let content = String(data: data, encoding: .utf8) else { return }
            let lines = content.components(separatedBy: "\n")
            let kept = lines.suffix(500).joined(separator: "\n")
            try? kept.data(using: .utf8)?.write(to: logURL, options: .atomic)
        }
    }
}
