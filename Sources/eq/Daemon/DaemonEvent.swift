import Foundation

/// One state change, as `eq events` prints it: `{"t":…,"event":"device",…}`. Never a meter tick.
enum DaemonEvent: Equatable {
    case device(name: String, uid: String, transport: String, rate: Double)
    case rate(device: String, rate: Double)
    case profile(device: String, preset: String?, source: ProfileSource)
    case enabled(Bool)
    case solo(SoloRange?)
    case daemon(state: Status.State, version: String, error: String?)
    case app(app: String, name: String, preset: String?)

    var kind: String {
        switch self {
        case .device: return "device"
        case .rate: return "rate"
        case .profile: return "profile"
        case .enabled: return "enabled"
        case .solo: return "solo"
        case .daemon: return "daemon"
        case .app: return "app"
        }
    }

    static func encodeLine(_ event: DaemonEvent, at t: Double = Date().timeIntervalSince1970) throws -> Data {
        var data = try encoder.encode(Line(t: t, event: event))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    // Absent values go out as explicit `null`, so `jq .preset` on every profile line reads the same.
    private struct Line: Encodable {
        var t: Double
        var event: DaemonEvent

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(t, forKey: Key("t"))
            try c.encode(event.kind, forKey: Key("event"))
            switch event {
            case .device(let name, let uid, let transport, let rate):
                try c.encode(name, forKey: Key("device"))
                try c.encode(uid, forKey: Key("uid"))
                try c.encode(transport, forKey: Key("transport"))
                try c.encode(rate, forKey: Key("rate"))
            case .rate(let device, let rate):
                try c.encode(device, forKey: Key("device"))
                try c.encode(rate, forKey: Key("rate"))
            case .profile(let device, let preset, let source):
                try c.encode(device, forKey: Key("device"))
                try c.encode(preset, forKey: Key("preset"))
                try c.encode(source, forKey: Key("source"))
            case .enabled(let on):
                try c.encode(on, forKey: Key("enabled"))
            case .solo(let range):
                try c.encode(range, forKey: Key("solo"))
            case .daemon(let state, let version, let error):
                try c.encode(state, forKey: Key("state"))
                try c.encode(version, forKey: Key("version"))
                try c.encode(error, forKey: Key("error"))
            case .app(let app, let name, let preset):
                try c.encode(app, forKey: Key("app"))
                try c.encode(name, forKey: Key("name"))
                try c.encode(preset, forKey: Key("preset"))
            }
        }
    }
}

/// Turns what the daemon did into events and hook runs, each only when the value really changed.
/// Device, rate and profile come only from a profile applied to a running engine, never from a
/// rebuild in progress, so a device that never played never shows up.
final class EventTracker {
    private let publish: (DaemonEvent) -> Void
    private let hooks: Hooks
    private var state: Status.State = .starting
    private var lastError: String?
    private var device: Status.Device?
    private var rate: Double = 0
    private var profile: Profile?
    private var source: ProfileSource?
    private var enabled: Bool
    private var solo: SoloRange?

    init(enabled: Bool, hooks: Hooks, publish: @escaping (DaemonEvent) -> Void) {
        self.enabled = enabled
        self.hooks = hooks
        self.publish = publish
    }

    /// What a new events client is told first.
    var current: DaemonEvent { .daemon(state: state, version: Build.version, error: lastError) }

    func state(_ new: Status.State, error: String?) {
        lastError = error
        guard new != state else { return }
        state = new
        publish(current)
    }

    func applied(device new: Status.Device, rate newRate: Double, profile newProfile: Profile, source newSource: ProfileSource) {
        let deviceChanged = new.uid != device?.uid
        let rateChanged = newRate != rate
        // The daemon writes the device's name into its profile; a rename is not something you hear.
        var heard = newProfile
        heard.name = nil
        let profileChanged = heard != profile || newSource != source
        let presetChanged = profile == nil || heard.preset != profile?.preset
        device = new
        rate = newRate
        profile = heard
        source = newSource
        if deviceChanged {
            publish(.device(name: new.name, uid: new.uid, transport: new.transport, rate: newRate))
        } else if rateChanged {
            publish(.rate(device: new.name, rate: newRate))
        }
        if profileChanged { publish(.profile(device: new.name, preset: heard.preset, source: newSource)) }
        let environment = ["EQ_DEVICE": new.name, "EQ_PRESET": heard.preset ?? "", "EQ_RATE": String(Int(newRate))]
        if deviceChanged || rateChanged { hooks.fire("device", environment: environment) }
        if presetChanged { hooks.fire("preset", environment: environment) }
    }

    func enabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        publish(.enabled(on))
    }

    /// The app rule heard now, or, with `match` nil, the one that just ended. Hooks never run for it.
    func app(_ match: AppMatch?, previous: AppMatch?) {
        guard let subject = match ?? previous else { return }
        publish(.app(app: subject.app, name: subject.name, preset: match?.preset))
    }

    func solo(_ range: SoloRange?) {
        guard range != solo else { return }
        solo = range
        publish(.solo(range))
    }
}
