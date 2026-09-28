import Foundation

struct Status: Codable, Equatable {
    enum State: String, Codable {
        case starting, running, bypassed, failed
        case noPermission = "no-permission"
    }

    /// Host-clock seconds of the last sound to follow silence, when the tap stamped it and when eq sent it on.
    struct Onset: Codable, Equatable {
        var tapHostSeconds: Double
        var outputHostSeconds: Double
        var count: UInt64
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
    var callbacks: UInt64
    // Status dates are ISO-8601 to the second, so two rewrites within a second look identical without a counter.
    var writes: UInt64
    var enabled: Bool
    var error: String?
    var pid: Int32
    var version: String?
    var updatedAt: Date
    var latencyMs: Double? = nil
    /// Seconds the IO proc kept running while nothing but exact zeros arrived from the tap.
    var tapSilentSeconds: Double? = nil
    /// Written as [] when there is nothing to say, so nil means a daemon too old to check.
    var warnings: [String]? = nil
    var deviceLatencyMs: Double? = nil
    /// From the tap's host timestamp on a frame to the output's on the same frame; players compensate for the device, never for this.
    var addedLatencyMs: Double? = nil
    var addedLatencyFrames: Double? = nil
    var lastOnset: Onset? = nil
    /// Output cycles that found the tap's ring short (silence filled the gap) or overfull (oldest dropped).
    var underruns: UInt64? = nil
    var overruns: UInt64? = nil
    /// Buffers the engine dropped whole: a tap buffer the ring cannot take, an output buffer larger than eq prepared for.
    var dropouts: UInt64? = nil
    /// Only while `experimental.apps` is on.
    var apps: AppsStatus? = nil

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

    func isFresh(now: Date = Date(), maxAge: TimeInterval = 90) -> Bool {
        now.timeIntervalSince(updatedAt) <= maxAge
    }

    func isAlive(now: Date = Date()) -> Bool {
        isFresh(now: now) && kill(pid, 0) == 0
    }
}

extension Status {
    private enum CodingKeys: String, CodingKey {
        case state, device, sampleRate, profile, framesProcessed, callbacks, writes, enabled, error, pid, version, updatedAt, latencyMs, tapSilentSeconds, warnings
        case deviceLatencyMs, addedLatencyMs, addedLatencyFrames, lastOnset, underruns, overruns, dropouts, apps
    }

    // v1 daemons wrote no `callbacks`; a CLI upgraded before its daemon must still read their status.
    // v1/v2 daemons wrote no `version`; that's exactly how Doctor tells them apart from v3.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(State.self, forKey: .state)
        device = try c.decodeIfPresent(Device.self, forKey: .device)
        sampleRate = try c.decode(Double.self, forKey: .sampleRate)
        profile = try c.decodeIfPresent(ProfileSource.self, forKey: .profile)
        framesProcessed = try c.decode(UInt64.self, forKey: .framesProcessed)
        callbacks = try c.decodeIfPresent(UInt64.self, forKey: .callbacks) ?? 0
        writes = try c.decodeIfPresent(UInt64.self, forKey: .writes) ?? 0
        enabled = try c.decode(Bool.self, forKey: .enabled)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        pid = try c.decode(Int32.self, forKey: .pid)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs)
        tapSilentSeconds = try c.decodeIfPresent(Double.self, forKey: .tapSilentSeconds)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings)
        deviceLatencyMs = try c.decodeIfPresent(Double.self, forKey: .deviceLatencyMs)
        addedLatencyMs = try c.decodeIfPresent(Double.self, forKey: .addedLatencyMs)
        addedLatencyFrames = try c.decodeIfPresent(Double.self, forKey: .addedLatencyFrames)
        lastOnset = try c.decodeIfPresent(Onset.self, forKey: .lastOnset)
        underruns = try c.decodeIfPresent(UInt64.self, forKey: .underruns)
        overruns = try c.decodeIfPresent(UInt64.self, forKey: .overruns)
        dropouts = try c.decodeIfPresent(UInt64.self, forKey: .dropouts)
        apps = try c.decodeIfPresent(AppsStatus.self, forKey: .apps)
    }
}
