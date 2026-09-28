import Foundation

enum Log {
    private static let formatter = ISO8601DateFormatter()

    static func format(_ message: String, at date: Date = Date()) -> String {
        "\(formatter.string(from: date)) \(message)"
    }

    static func write(_ message: String) {
        FileHandle.standardError.write(Data((format(message) + "\n").utf8))
    }

    /// The bundled LaunchAgent cannot name a log under the user's home — launchd expands no `~`
    /// and the plist is sealed in the signed bundle — so it passes EQ_LOG and the daemon opens it.
    /// O_APPEND keeps an in-place truncation by a log cap from leaving a hole at the old offset.
    static func redirect(to path: String) {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            write("cannot open log \(url.path) (errno \(errno)); logging to the inherited stderr")
            return
        }
        dup2(fd, STDOUT_FILENO)
        dup2(fd, STDERR_FILENO)
        close(fd)
    }
}
