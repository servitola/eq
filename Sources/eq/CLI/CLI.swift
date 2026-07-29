import Foundation

struct CLIContext {
    typealias ConnectedDevice = (uid: String, name: String, transport: String)

    var store: ConfigStore
    var statusURL: URL
    var connectedDevices: () -> [ConnectedDevice]
    var defaultOutput: () -> (uid: String, name: String)?

    static func live() -> CLIContext {
        CLIContext(
            store: ConfigStore(url: ConfigStore.defaultURL),
            statusURL: Status.defaultURL,
            connectedDevices: { AudioDeviceManager.outputDevices().map { ($0.uid, $0.name, $0.transportName) } },
            defaultOutput: {
                AudioDeviceManager.defaultOutputDeviceID().flatMap(AudioDeviceManager.device).map { ($0.uid, $0.name) }
            })
    }
}

enum CLI {
    static let usage = """
    usage:
      eq                          show the current device's profile
      eq init                     write the default config if none exists
      eq set [--device Q] <band> <gain> …   e.g. eq set 64hz +4 1khz -3
      eq preamp [--device Q] <gain>
      eq flat [--device Q]
      eq copy --to Q              copy the current profile onto device Q
      eq devices                  known profiles and connected outputs
      eq on | eq off              enable / bypass
      eq status [--json]
      eq daemon                   run the audio engine (used by the LaunchAgent)
    bands: \(Config.bandLabels.joined(separator: " "))   gains: \(Config.gainRange.lowerBound)…\(Config.gainRange.upperBound) dB
    """

    static let permissionHint = "System Settings → Privacy & Security → Screen & System Audio Recording → enable EQ, then: launchctl kickstart -k gui/$UID/com.servitola.eq"

    static func run(_ args: [String], context: CLIContext) -> (exitCode: Int32, output: String) {
        do {
            return (0, try dispatch(args, context))
        } catch let error as CLIError {
            switch error {
            case .usage, .unknownBand, .badGain, .gainOutOfRange:
                return (2, "error: \(error)\n\(usage)")
            case .daemonNotRunning:
                return (1, "\(error)")
            default:
                return (1, "error: \(error)")
            }
        } catch {
            return (1, "error: \(error)")
        }
    }

    private static func dispatch(_ args: [String], _ ctx: CLIContext) throws -> String {
        var rest = args
        let command = rest.isEmpty ? "show" : rest.removeFirst()
        switch command {
        case "show": return try show(ctx)
        case "init": return try initialise(ctx)
        case "set": return try set(rest, ctx)
        case "preamp": return try preamp(rest, ctx)
        case "flat": return try flat(rest, ctx)
        case "copy": return try copy(rest, ctx)
        case "devices": return try devices(ctx)
        case "on": return try toggle(true, ctx)
        case "off": return try toggle(false, ctx)
        case "status": return try status(rest, ctx)
        case "help", "-h", "--help": return usage
        default: throw CLIError.usage("unknown command \"\(command)\"")
        }
    }

    // MARK: - Commands

    private static func show(_ ctx: CLIContext) throws -> String {
        let config = try loadConfig(ctx)
        let current = try currentDevice(ctx)
        let resolved = config.profile(forDeviceUID: current.uid)
        let source = resolved.source == .device ? "own profile" : "default profile"
        return Table.profile(resolved.profile, header: "\(current.name) (\(source))")
    }

    private static func initialise(_ ctx: CLIContext) throws -> String {
        let builtIn = ctx.connectedDevices().first { $0.transport == "builtin" }
        let existed = ctx.store.exists()
        _ = try ctx.store.loadOrCreate(builtInUID: builtIn?.uid, builtInName: builtIn?.name)
        return existed ? "config already exists: \(ctx.store.url.path)" : "wrote \(ctx.store.url.path)"
    }

    private static func set(_ args: [String], _ ctx: CLIContext) throws -> String {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        let assignments = try BandParser.assignments(rest)
        var config = try loadConfig(ctx)
        let target: Target
        if let explicit { target = explicit } else { target = try currentDevice(ctx) }
        var profile = editableProfile(config, target)
        for (index, gain) in assignments { profile.bands[index] = gain }
        config.setProfile(profile, forDeviceUID: target.uid)
        try ctx.store.save(config)
        return Table.profile(profile, header: target.name)
    }

    private static func preamp(_ args: [String], _ ctx: CLIContext) throws -> String {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        guard rest.count == 1 else { throw CLIError.usage("eq preamp [--device Q] <gain>") }
        let gain = try BandParser.gain(rest[0])
        var config = try loadConfig(ctx)
        let target: Target
        if let explicit { target = explicit } else { target = try currentDevice(ctx) }
        var profile = editableProfile(config, target)
        profile.preamp = gain
        config.setProfile(profile, forDeviceUID: target.uid)
        try ctx.store.save(config)
        return Table.profile(profile, header: target.name)
    }

    private static func flat(_ args: [String], _ ctx: CLIContext) throws -> String {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        guard rest.isEmpty else { throw CLIError.usage("eq flat [--device Q]") }
        var config = try loadConfig(ctx)
        let target: Target
        if let explicit { target = explicit } else { target = try currentDevice(ctx) }
        let profile = Profile(name: target.name, preamp: 0, bands: Profile.flat.bands)
        config.setProfile(profile, forDeviceUID: target.uid)
        try ctx.store.save(config)
        return Table.profile(profile, header: target.name)
    }

    private static func copy(_ args: [String], _ ctx: CLIContext) throws -> String {
        let (target, rest) = try splitDeviceOption(args, flag: "--to", ctx)
        guard let target, rest.isEmpty else { throw CLIError.usage("eq copy --to Q") }
        var config = try loadConfig(ctx)
        let current = try currentDevice(ctx)
        var profile = config.profile(forDeviceUID: current.uid).profile
        profile.name = target.name
        config.setProfile(profile, forDeviceUID: target.uid)
        try ctx.store.save(config)
        return "copied \(current.name) → \(target.name)\n" + Table.profile(profile, header: target.name)
    }

    private static func devices(_ ctx: CLIContext) throws -> String {
        let config = try loadConfig(ctx)
        let connected = ctx.connectedDevices()
        let currentUID = (try? currentDevice(ctx))?.uid
        var lines: [String] = []
        for device in connected {
            let marker = device.uid == currentUID ? "* " : "  "
            let profile = config.devices[device.uid] != nil ? "own profile" : "default profile"
            lines.append("\(marker)\(device.name)  [\(device.transport)]  \(profile)")
        }
        for (uid, profile) in config.devices.sorted(by: { ($0.value.name ?? $0.key) < ($1.value.name ?? $1.key) })
            where !connected.contains(where: { $0.uid == uid }) {
            lines.append("  \(profile.name ?? uid)  [disconnected]  own profile")
        }
        return lines.joined(separator: "\n")
    }

    private static func toggle(_ enabled: Bool, _ ctx: CLIContext) throws -> String {
        var config = try loadConfig(ctx)
        config.enabled = enabled
        try ctx.store.save(config)
        return enabled ? "eq on" : "eq off (bypass)"
    }

    private static func status(_ args: [String], _ ctx: CLIContext) throws -> String {
        guard let status = Status.read(from: ctx.statusURL), status.isAlive() else { throw CLIError.daemonNotRunning }
        if args == ["--json"] {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(status), as: UTF8.self)
        }
        var lines = ["state: \(status.state.rawValue)"]
        if let device = status.device {
            lines.append("device: \(device.name) [\(device.transport)] \(Int(status.sampleRate)) Hz, \(status.profile?.rawValue ?? "-") profile")
        }
        lines.append("frames: \(status.framesProcessed)  enabled: \(status.enabled)  pid: \(status.pid)")
        if let error = status.error { lines.append("error: \(error)") }
        if status.state == .noPermission { lines.append(permissionHint) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    typealias Target = (uid: String, name: String)

    private static func loadConfig(_ ctx: CLIContext) throws -> Config {
        guard ctx.store.exists() else { throw CLIError.usage("no config at \(ctx.store.url.path) — run `eq init` first") }
        return try ctx.store.load()
    }

    private static func currentDevice(_ ctx: CLIContext) throws -> Target {
        if let status = Status.read(from: ctx.statusURL), status.isFresh(), let device = status.device {
            return (device.uid, device.name)
        }
        guard let device = ctx.defaultOutput() else { throw CLIError.noCurrentDevice }
        return device
    }

    private static func editableProfile(_ config: Config, _ target: Target) -> Profile {
        var profile = config.profile(forDeviceUID: target.uid).profile
        profile.name = target.name
        return profile
    }

    private static func splitDeviceOption(_ args: [String], flag: String, _ ctx: CLIContext) throws -> (Target?, [String]) {
        guard let at = args.firstIndex(of: flag) else { return (nil, args) }
        guard at + 1 < args.count else { throw CLIError.usage("\(flag) needs a device name") }
        var rest = args
        rest.removeSubrange(at...(at + 1))
        return (try resolveDevice(args[at + 1], ctx), rest)
    }

    private static func resolveDevice(_ query: String, _ ctx: CLIContext) throws -> Target {
        let needle = query.lowercased()
        var candidates: [String: String] = [:]
        for device in ctx.connectedDevices() where device.name.lowercased().contains(needle) {
            candidates[device.uid] = device.name
        }
        if let config = try? ctx.store.load() {
            for (uid, profile) in config.devices where (profile.name ?? "").lowercased().contains(needle) {
                candidates[uid] = profile.name ?? uid
            }
        }
        switch candidates.count {
        case 0: throw CLIError.noSuchDevice(query)
        case 1: return candidates.first.map { ($0.key, $0.value) }!
        default: throw CLIError.ambiguousDevice(query, candidates.values.sorted())
        }
    }
}
