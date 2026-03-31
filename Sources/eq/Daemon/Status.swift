import Foundation

struct Status: Codable, Equatable {
    enum State: String, Codable {
        case starting, running, bypassed, failed
        case noPermission = "no-permission"
    }

    struct Device: Codable, Equatable {
        var uid: String
        var name: String
        var transport: String
    }

    var state: State
    var device: Device?
    var sampleRate: Double
    var profile: ProfileSource?
    var framesProcessed: UInt64
    var enabled: Bool
    var error: String?
    var pid: Int32
    var updatedAt: Date

    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["EQ_STATUS"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/eq/status.json")
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func read(from url: URL) -> Status? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Status.self, from: data)
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    func isFresh(now: Date = Date(), maxAge: TimeInterval = 15) -> Bool {
        now.timeIntervalSince(updatedAt) <= maxAge
    }

    func isAlive(now: Date = Date()) -> Bool {
        isFresh(now: now) && kill(pid, 0) == 0
    }
}
