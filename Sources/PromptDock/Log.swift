import Foundation
import os

/// 同时写系统日志和 ~/Library/Logs/PromptDock/app.log，便于排障。
enum Log {
    private static let logger = Logger(subsystem: "local.jemry.promptdock", category: "app")
    private static let queue = DispatchQueue(label: "promptdock.log")
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    static func info(_ message: String) { write("INFO", message); logger.info("\(message, privacy: .public)") }
    static func error(_ message: String) { write("ERROR", message); logger.error("\(message, privacy: .public)") }

    private static func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        queue.async {
            let url = Paths.logFile
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
