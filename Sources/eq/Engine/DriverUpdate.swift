import Foundation

/// What a newer bundled driver brings, for the terminal prompt and the daemon's notification.
enum DriverUpdate {
    /// One row per driver revision people notice, in their words; a revision without a row only fixes.
    static let changes: [Int: String] = [
        17: "spectrum analyser",
        18: "true silence for silent outputs",
    ]

    static func changes(from installed: Int, to bundled: Int) -> [String] {
        changes.keys.sorted().filter { $0 > installed && $0 <= bundled }.compactMap { changes[$0] }
    }

    static func summary(from installed: Int, to bundled: Int) -> String? {
        let list = changes(from: installed, to: bundled)
        return list.isEmpty ? nil : list.joined(separator: ", ")
    }

    static let declinedName = "driver-update-declined"
    static let notifiedName = "driver-update-notified"
}

/// The newest driver revision the user was already asked about, one number in a file under ~/.cache/eq,
/// so a newer revision asks again.
struct RevisionMarker {
    var url: URL

    func read() -> Int? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func write(_ revision: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(revision)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    func covers(_ revision: Int) -> Bool { (read() ?? Int.min) >= revision }
}
