import Foundation

/// Append-only run log. The app is invisible by design, so this is the record of what
/// it actually did. Failing to log must never break a sync that would otherwise work.
enum Log {
    static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CalSync", isDirectory: true)

    static let fileURL = directory.appendingPathComponent("calsync.log")

    private static let stamp = Date.ISO8601FormatStyle(timeZone: .current)

    static func write(_ message: String) {
        let line = "\(stamp.format(Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard let data = line.data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL)
            }
        } catch {
            // Deliberately swallowed — see the note above.
        }
    }
}
