import EQTerm
import Foundation

struct CLIContext {
    typealias ConnectedDevice = (uid: String, name: String, transport: String)

    var store: ConfigStore
    var statusURL: URL
    var connectedDevices: () -> [ConnectedDevice]
    var defaultOutput: () -> (uid: String, name: String)?
    var setDefaultOutput: (String) throws -> Void = { _ in throw CLIError.switchFailed("no audio system in this context") }
    var fetch: (URL) throws -> Data
    var cacheDirectory: URL
    var today: () -> String
    var doctorProbes: (() -> DoctorProbes)? = nil
    var meterSocketURL: URL = Status.defaultURL.deletingLastPathComponent().appendingPathComponent("meter.sock")
    var streamLimit: Int? = nil
    var emit: (String) -> Void = { line in print(line); fflush(stdout) }
    var terminal: () -> (isTTY: Bool, cols: Int, rows: Int) = Terminal.probe
    var width: (Int32) -> Int = Terminal.width
    var agent: LaunchAgentControl?
    /// Off in tests and sandboxed runs: whether a command may start the daemon and warn about it.
    var checksDaemon = false
    var warn: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    /// Apps with audio open, for `eq app set` and completion; only read, never tapped.
    var audioApps: () -> [PlayingApp] = { [] }
    var findApp: (String) -> PlayingApp? = { _ in nil }
    /// The HAL plug-in, when installed; `eq driver` only.
    var driver: () -> DriverPort? = { nil }
    /// Tells the plug-in which write it plays; any increasing number does.
    var driverSerial: () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    /// What `eq mode` moves the default output with; nothing in tests unless a fake is given.
    var audioSystem: AudioSystem = NoAudioSystem()
    var modeDeadline: TimeInterval = 2
    var modeWait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// The driver in /Library and the one this EQ.app carries; none in tests unless a fake is given.
    var driverFiles: () -> DriverFiles = { DriverFiles() }
    var driverElevation: () -> DriverInstall.Elevation = { .dialog }
    /// The one step that runs as root; never the real one in tests.
    var privileged: (DriverInstall.Action, DriverInstall.Elevation) throws -> Void = { _, _ in
        throw DriverInstall.Failure.failed("this eq cannot install drivers here")
    }
    /// How long a freshly installed driver gets to show its device after coreaudiod restarts.
    var driverAppearDeadline: TimeInterval = 15
    var brewCommand: () -> String? = { nil }

    /// `~/.cache/eq` (or EQ_CACHE): eq's own markers live here, beside the downloads, and not in
    /// the config directory, which a fresh Mac does not have until a change needs it.
    var stateDirectory: URL { cacheDirectory.deletingLastPathComponent() }

    var agentOptOutMarker: URL { stateDirectory.appendingPathComponent(LaunchAgent.optOutName) }

    static func live() -> CLIContext {
        CLIContext(
            store: ConfigStore(url: ConfigStore.defaultURL),
            statusURL: Status.defaultURL,
            connectedDevices: { AudioDeviceManager.outputDevices().map { ($0.uid, $0.name, $0.transportName) } },
            defaultOutput: {
                AudioDeviceManager.defaultOutputDeviceID().flatMap(AudioDeviceManager.device).map { ($0.uid, $0.name) }
            },
            setDefaultOutput: { uid in
                guard let device = AudioDeviceManager.outputDevices().first(where: { $0.uid == uid }) else { throw CLIError.notConnected(uid) }
                let status = AudioDeviceManager.setDefaultOutputDevice(device.id)
                guard status == noErr else { throw CLIError.switchFailed("Core Audio status \(status)") }
            },
            fetch: HTTPFetch.live,
            cacheDirectory: AutoEqCache.defaultDirectory,
            today: {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.calendar = Calendar.current
                return formatter.string(from: Date())
            },
            agent: LiveLaunchAgent(),
            checksDaemon: LiveLaunchAgent.autoStarts(),
            audioApps: CoreAudioProcesses.apps,
            findApp: { InstalledApps.find($0) },
            driver: { DriverControl.find() },
            audioSystem: LiveAudioSystem(),
            driverFiles: { DriverFiles.live() },
            driverElevation: DriverInstall.liveElevation,
            privileged: DriverInstall.run,
            brewCommand: BrewParent.live)
    }

}

enum CLI {
    static let permissionHint = "System Settings → Privacy & Security → Screen & System Audio Recording → enable EQ, then: " + LaunchAgent.restartHint

    /// `isError` marks a thrown error, the only output that belongs on stderr; a report that merely
    /// exits non-zero (a failing `doctor`) is still the answer and goes to stdout.
    static func run(_ args: [String], context: CLIContext) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        let wantsJSON = args.contains("--json")
        let dryRun = args.contains("--dry-run")
        let args = args.filter { $0 != "--json" && $0 != "--dry-run" }
        let command = args.first ?? "show"
        do {
            if wantsJSON, let first = args.first, ["watch", "tui"].contains(first) { throw CLIError.usage("eq \(first) has no JSON form; use eq stream") }
            checkDaemon(args, context)
            let output = try dispatch(args, context, dryRun: dryRun)
            // A streamed command already printed its own lines; the empty final Output carries
            // no text in either form, JSON included, so nothing prints twice.
            let text = (output.streamed && output.text.isEmpty) ? "" : (wantsJSON ? json(output.json) : output.text)
            return (output.exitCode, text, false, output.streamed)
        } catch let error as CLIError {
            let code: Int32
            switch error {
            case .usage, .unknownBand, .badGain, .gainOutOfRange: code = 2
            default: code = 1
            }
            if wantsJSON { return (code, json(ErrorReport(error: .init(code: error.code, message: "\(error)"))), true, false) }
            switch error {
            case .usage, .unknownBand, .badGain, .gainOutOfRange:
                let help = helpText(for: command, width: context.width(2), paint: Paint.enabled(fd: 2))
                return (code, "error: \(error)\n\n\(help)", true, false)
            case .daemonNotRunning: return (code, "\(error)", true, false)
            default: return (code, "error: \(error)", true, false)
            }
        } catch {
            let code = error is ConfigError ? "config" : "internal"
            if wantsJSON { return (1, json(ErrorReport(error: .init(code: code, message: "\(error)"))), true, false) }
            return (1, "error: \(error)", true, false)
        }
    }

    /// A JSON answer goes to stdout even when it reports an error, so fd 1 decides its colour.
    private static func json(_ value: Encodable) -> String {
        let text = encode(value)
        return Paint.enabled ? JSONPainter.paint(text) : text
    }

    static func encode(_ value: Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(AnyEncodable(value)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func dispatch(_ args: [String], _ ctx: CLIContext, dryRun: Bool = false) throws -> Output {
        if args.contains("--help") || args.contains("-h") || ["help", "-h", "--help"].contains(args.first ?? "") {
            let topic = ["help", "-h", "--help"].contains(args.first ?? "") ? (args.dropFirst().first { !$0.hasPrefix("-") } ?? "") : args[0]
            let text = helpText(for: topic, width: ctx.width(1), paint: Paint.enabled)
            return Output(text, UsageReport(usage: helpText(for: topic, width: 80, paint: false)))
        }
        let args = CommandHelp.canonical(args)
        if dryRun {
            // Before the grammar check: the cask's --cask is not in the help.
            if args.starts(with: ["driver", "uninstall"]) { return try driverUninstall(Array(args.dropFirst(2)), ctx, dryRun: true) }
            guard CommandHelp.form(matching: args)?.writes == true else {
                throw CLIError.usage("--dry-run applies only to a command that changes something (eq \(args.first ?? "") does not)")
            }
            return try DryRun.run(args, ctx) { try dispatch($0, $1) }
        }
        var rest = args
        let command = rest.isEmpty ? "show" : rest.removeFirst()
        switch command {
        case "show": return try show(ctx)
        case "init": return try initialise(ctx)
        case "set": return try set(rest, ctx)
        case "preamp": return try preamp(rest, ctx)
        case "flat": return try flat(rest, ctx)
        case "device": return try device(rest, ctx)
        case "import": return try importCommand(rest, ctx)
        case "filter": return try filter(rest, ctx)
        case "export": return try export(rest, ctx)
        case "bass", "treble", "tilt": return try preference(command, rest, ctx)
        case "boost": return try boost(rest, ctx)
        case "comp": return try comp(rest, ctx)
        case "color": return try color(rest, ctx)
        case "completions": return try Completions.command(rest)
        case "man": return try ManPage.command(rest)
        case "__complete": return Completions.list(rest, ctx)
        case "on": return try toggle(true, ctx)
        case "off": return try toggle(false, ctx)
        case "status": return try status(ctx)
        case "doctor": return doctor(ctx)
        case "stream": return try stream(rest, ctx)
        case "events": return try events(rest, ctx)
        case "watch": return try watch(rest, ctx)
        case "tui": return try tui(rest, ctx)
        case "zones": return try zones(rest, ctx)
        case "preset": return try preset(rest, ctx)
        case "app": return try app(rest, ctx)
        case "undo": return try undo(rest, ctx)
        case "redo": return try redo(rest, ctx)
        case "history": return try history(rest, ctx)
        case "agent": return try agent(rest, ctx)
        case "driver": return try driver(rest, ctx)
        case "mode": return try mode(rest, ctx)
        default: throw CLIError.usage("unknown command \"\(command)\"")
        }
    }

    /// Commands that never start the daemon: completion runs on every Tab, and help, the man page
    /// and `eq agent` itself must not have side effects; `eq driver` talks to the plug-in alone, and
    /// `eq mode` moves the default output itself, which a daemon starting up in the old mode would fight.
    private static let leavesDaemonAlone: Set<String> = ["agent", "driver", "mode", "__complete", "completions", "man", "help", "-h", "--help"]

    /// Starts the bundled daemon when nothing runs one, and says so once on stderr; points at the
    /// System Audio Recording grant while the daemon waits for it.
    private static func checkDaemon(_ args: [String], _ ctx: CLIContext) {
        let command = args.first ?? "show"
        guard ctx.checksDaemon, let agent = ctx.agent, !leavesDaemonAlone.contains(command),
              !args.contains("--help"), !args.contains("-h") else { return }
        let live = Status.read(from: ctx.statusURL).flatMap { $0.isAlive() ? $0 : nil }
        let paint = Paint.enabled(fd: 2)
        if let note = LaunchAgent.ensureRunning(agent, daemonAlive: live != nil,
                                                  optedOut: FileManager.default.fileExists(atPath: ctx.agentOptOutMarker.path)) { ctx.warn(LaunchAgent.text(note, paint: paint)) }
        if live?.state == .noPermission, !["status", "doctor"].contains(command) {
            ctx.warn(Paint.ink(.yellow, "eq is not equalising: no System Audio Recording permission — \(permissionHint)", on: paint))
        }
    }

    /// One command's block when the topic names a command, the whole grouped help otherwise.
    static func helpText(for topic: String, width: Int, paint: Bool) -> String {
        let entries = CommandHelp.entries(for: topic)
        guard !entries.isEmpty else { return HelpRenderer.render(width: width, paint: paint) }
        return HelpRenderer.render(width: width, paint: paint, entries: entries, footer: false)
    }

    // MARK: - Commands

    private static func show(_ ctx: CLIContext) throws -> Output {
        let config = try loadConfig(ctx)
        let current = try currentDevice(ctx)
        let resolved = config.profile(forDeviceUID: current.uid)
        let sourceLabel = resolved.source == .device ? "own profile" : "default profile"
        let mark = presetMark(resolved.profile, config)
        let table = Table.profile(resolved.profile, header: "\(current.name) (\(sourceLabel))", preset: mark)
        let source = resolved.source == .device ? "device" : "default"
        let app = appLine(ctx)
        return Output(([table] + [app.text].compactMap { $0 }).joined(separator: "\n"),
                      ProfileReport(device: DeviceRef(uid: current.uid, name: current.name), source: source,
                                    profile: resolved.profile, preset: mark?.name, app: app.apps?.overlay))
    }

    private static func initialise(_ ctx: CLIContext) throws -> Output {
        let builtIn = ctx.connectedDevices().first { $0.transport == "builtin" }
        let existed = ctx.store.exists()
        var config = try ctx.store.loadOrCreate(builtInUID: builtIn?.uid, builtInName: builtIn?.name)
        if config.seedPresetsIfNeeded() { try ctx.store.save(config, as: .bookkeeping) }
        let path = Paint.ink(.dim, ctx.store.displayPath)
        let text = existed ? "config already exists: \(path)" : Paint.ink(.green, "wrote") + " \(path)"
        return Output(text, InitReport(path: ctx.store.displayPath, created: !existed))
    }

    private static func set(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        let assignments = try BandParser.assignments(rest)
        var config = try loadConfig(ctx)
        let target: Target
        if let explicit { target = explicit } else { target = try currentDevice(ctx) }
        var profile = editableProfile(config, target)
        for (index, gain) in assignments { profile.bands[index] = gain }
        config.setProfile(profile, forDeviceUID: target.uid)
        try ctx.store.save(config)
        let table = Table.profile(profile, header: target.name, preset: presetMark(profile, config))
        return Output(table, ProfileReport(device: DeviceRef(uid: target.uid, name: target.name), source: "device", profile: profile))
    }

    private static func preamp(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        guard rest.count == 1 else { throw CLIError.usage("eq preamp [--device DEVICE] <gain>") }
        let gain = try BandParser.gain(rest[0])
        var config = try loadConfig(ctx)
        let target: Target
        if let explicit { target = explicit } else { target = try currentDevice(ctx) }
        var profile = editableProfile(config, target)
        profile.preamp = gain
        config.setProfile(profile, forDeviceUID: target.uid)
        try ctx.store.save(config)
        let table = Table.profile(profile, header: target.name, preset: presetMark(profile, config))
        return Output(table, ProfileReport(device: DeviceRef(uid: target.uid, name: target.name), source: "device", profile: profile))
    }

    private static func flat(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        guard rest.isEmpty else { throw CLIError.usage("eq flat [--device DEVICE]") }
        var config = try loadConfig(ctx)
        let target: Target
        if let explicit { target = explicit } else { target = try currentDevice(ctx) }
        let profile = Profile(name: target.name, preamp: 0, bands: Profile.flat.bands)
        config.setProfile(profile, forDeviceUID: target.uid)
        try ctx.store.save(config)
        let table = Table.profile(profile, header: target.name, preset: presetMark(profile, config))
        return Output(table, ProfileReport(device: DeviceRef(uid: target.uid, name: target.name), source: "device", profile: profile))
    }

    private static func device(_ args: [String], _ ctx: CLIContext) throws -> Output {
        switch (args.first ?? "list", args.dropFirst()) {
        case ("list", let rest) where rest.isEmpty: return try devices(ctx)
        case ("use", let rest): return try use(Array(rest), ctx)
        case ("copy", let rest): return try copy(Array(rest), ctx)
        default: throw CLIError.usage("eq device list | eq device use DEVICE | eq device copy --to DEVICE")
        }
    }

    /// Where a dry run of `device use` can reach the same answer without switching anything.
    static func useTarget(_ args: [String], _ ctx: CLIContext) throws -> Target {
        guard args.count == 1 else { throw CLIError.usage("eq device use DEVICE") }
        let query = args[0]
        let connected = ctx.connectedDevices()
        if let device = connected.first(where: { $0.uid == query }) { return (device.uid, device.name) }
        let needle = query.lowercased()
        let exact = connected.filter { $0.name.lowercased() == needle }
        let matches = exact.isEmpty ? connected.filter { $0.name.lowercased().contains(needle) } : exact
        switch matches.count {
        case 1: return (matches[0].uid, matches[0].name)
        case 0:
            if let profile = try? resolveDevice(query, ctx) { throw CLIError.notConnected(profile.name) }
            throw CLIError.noSuchDevice(query)
        default: throw CLIError.ambiguousDevice(query, matches.map { "\($0.name) (\($0.uid))" }.sorted())
        }
    }

    /// Makes the device the system's output. In driver mode the daemon sees the default move to a
    /// real device and points the EQ device at it, taking the default back.
    @discardableResult
    static func useDevice(_ args: [String], _ ctx: CLIContext) throws -> Target {
        let target = try useTarget(args, ctx)
        try ctx.setDefaultOutput(target.uid)
        return target
    }

    private static func use(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let config = try loadConfig(ctx)
        let target = try useDevice(args, ctx)
        let resolved = config.profile(forDeviceUID: target.uid)
        let sourceLabel = resolved.source == .device ? "own profile" : "default profile"
        let text = Paint.ink(.green, "output → ") + Paint.ink(.bold, target.name) + "\n"
            + Table.profile(resolved.profile, header: "\(target.name) (\(sourceLabel))", preset: presetMark(resolved.profile, config))
        return Output(text, ProfileReport(device: DeviceRef(uid: target.uid, name: target.name),
                                          source: resolved.source == .device ? "device" : "default",
                                          profile: resolved.profile, preset: presetMark(resolved.profile, config)?.name))
    }

    private static func copy(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let usage = "eq device copy --to DEVICE"
        guard !(args.contains("--to") && args.contains("--device")) else { throw CLIError.usage(usage + " (--to or --device, not both)") }
        let (target, rest) = try splitDeviceOption(args, flag: args.contains("--device") ? "--device" : "--to", ctx)
        guard let target, rest.isEmpty else { throw CLIError.usage(usage) }
        var config = try loadConfig(ctx)
        let current = try currentDevice(ctx)
        let profile = copyCurve(from: current, to: target, in: &config)
        try ctx.store.save(config)
        let copied = Paint.ink(.green, "copied ") + Paint.ink(.bold, current.name) + " → " + Paint.ink(.bold, target.name)
        let text = copied + "\n" + Table.profile(profile, header: target.name, preset: presetMark(profile, config))
        return Output(text, ProfileReport(device: DeviceRef(uid: target.uid, name: target.name), source: "device", profile: profile))
    }

    /// `source`'s curve, whole, as `target`'s own profile.
    @discardableResult
    static func copyCurve(from source: Target, to target: Target, in config: inout Config) -> Profile {
        var profile = config.profile(forDeviceUID: source.uid).profile
        profile.name = target.name
        config.setProfile(profile, forDeviceUID: target.uid)
        return profile
    }

    private static func importCommand(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let (explicit, afterDevice) = try splitDeviceOption(args, flag: "--device", ctx)
        var sourceOption: String?
        var variantOption: String?
        var search = false
        var keepBands = false
        var refresh = false
        var clear = false
        var positional: [String] = []
        var i = 0
        while i < afterDevice.count {
            switch afterDevice[i] {
            case "--source":
                guard i + 1 < afterDevice.count else { throw CLIError.usage("--source needs a value") }
                sourceOption = afterDevice[i + 1]
                i += 2
            case "--variant":
                guard i + 1 < afterDevice.count else { throw CLIError.usage("--variant needs a value") }
                variantOption = afterDevice[i + 1]
                i += 2
            case "--search":
                search = true
                i += 1
            case "--keep-bands":
                keepBands = true
                i += 1
            case "--refresh":
                refresh = true
                i += 1
            case "--clear":
                clear = true
                i += 1
            case let token where token.hasPrefix("-"):
                throw CLIError.usage("unknown option \"\(token)\" for eq import")
            default:
                positional.append(afterDevice[i])
                i += 1
            }
        }
        if search {
            guard positional.count == 1, explicit == nil, variantOption == nil, !keepBands, !clear else {
                throw CLIError.usage("eq import --search <name> [--source SOURCE] [--refresh]")
            }
            return try HeadphoneLookup.search(positional[0], source: sourceOption, refresh: refresh, ctx)
        }
        if clear {
            guard sourceOption == nil, variantOption == nil, !keepBands, !refresh else { throw CLIError.usage("--clear takes only --device") }
            guard positional.isEmpty else { throw CLIError.usage("eq import --clear [--device DEVICE]") }
        } else {
            guard positional.count == 1 else {
                throw CLIError.usage("eq import <file|url|name> [--device DEVICE] [--source SOURCE] [--variant VARIANT] [--keep-bands] [--refresh]")
            }
        }

        let target: Target
        if let explicit { target = explicit } else { target = try currentDevice(ctx) }

        if clear {
            var config = try loadConfig(ctx)
            var profile = editableProfile(config, target)
            profile.filters.removeAll { $0.origin == .import }
            profile.imported = nil
            profile.preamp = 0
            config.setProfile(profile, forDeviceUID: target.uid)
            try ctx.store.save(config)
            let table = Table.profile(profile, header: target.name, preset: presetMark(profile, config))
            return Output(table, ProfileReport(device: DeviceRef(uid: target.uid, name: target.name), source: "device", profile: profile))
        }

        let query = positional[0]
        let (result, origin, attribution) = try resolveImportSource(query, sourceOption: sourceOption, variant: variantOption, refresh: refresh, ctx)

        var config = try loadConfig(ctx)
        var profile = editableProfile(config, target)
        // Hand-added filters survive a new import, after the correction they were tuned against.
        let handFilters = profile.filters.filter { $0.origin != .import }
        let room = max(Config.maxFilters - handFilters.count, 0)
        if room == 0, !result.filters.isEmpty {
            throw CLIError.importRefused("the \(handFilters.count) filters added by hand fill all \(Config.maxFilters) slots, "
                + "leaving none for the \(result.filters.count) imported — remove some with `eq filter rm <n>`")
        }
        var warnings = result.warnings
        if result.filters.count > room {
            warnings.append("kept the first \(room) of \(result.filters.count) imported filters: "
                + "\(handFilters.count) added by hand leave room for \(room) of \(Config.maxFilters).")
        }
        profile.filters = result.filters.prefix(room).map { var filter = $0; filter.origin = .import; return filter } + handFilters
        if let bands = result.bands {
            profile.bands = bands
            if keepBands { warnings.append("--keep-bands ignored: \(result.format) sets all ten bands.") }
        } else {
            profile.bands = keepBands ? profile.bands : Profile.flat.bands
        }
        profile.preamp = result.preamp
        if let preference = result.preference { profile.preference = preference.isFlat ? nil : preference }
        if let instruments = result.instruments { profile.instruments = instruments.isEmpty ? nil : instruments }
        if let dynamics = result.dynamics { profile.dynamics = dynamics.isOff ? nil : dynamics }
        profile.imported = "\(origin) · \(ctx.today())"
        config.setProfile(profile, forDeviceUID: target.uid)
        try ctx.store.save(config)

        var lines = [Paint.ink(.green, "imported ") + Paint.ink(.cyan, origin) + Paint.ink(.dim, " (\(result.format))")]
        if let attribution { lines.append(Paint.ink(.dim, attribution)) }
        lines.append(contentsOf: warnings.map { "\(Paint.ink(.yellow, "warning:")) \($0)" })
        lines.append(Table.profile(profile, header: target.name, preset: presetMark(profile, config)))
        let report = ImportReport(
            device: DeviceRef(uid: target.uid, name: target.name),
            source: "device",
            profile: profile,
            import: .init(format: result.format, origin: origin, warnings: warnings, attribution: attribution))
        return Output(lines.joined(separator: "\n"), report)
    }

    private static func resolveImportSource(
        _ query: String, sourceOption: String?, variant: String?, refresh: Bool, _ ctx: CLIContext
    ) throws -> (result: ImportResult, origin: String, attribution: String?) {
        let isFile = FileManager.default.fileExists(atPath: query)
        let isURL = query.hasPrefix("http://") || query.hasPrefix("https://")
        if (isFile || isURL) && (sourceOption != nil || variant != nil || refresh) {
            throw CLIError.usage("--source, --variant and --refresh apply to a headphone name")
        }
        func parse(_ data: Data, _ what: String, filename: String?, context: ImportContext = .detached) throws -> ImportResult {
            do { return try EQFormats.parse(data, filename: filename, context: context) }
            catch ImportError.preampOutOfRange(let value) {
                throw CLIError.importRefused("\(what): \(ImportError.preampOutOfRange(value))")
            }
            catch { throw CLIError.importUnrecognized("\(what): \(error)") }
        }
        if isFile {
            let file = URL(fileURLWithPath: query)
            if let reason = ImportCheck.regularFile(at: file.path, maxBytes: APOFormat.maxIncludeBytes) {
                throw CLIError.importRefused(reason)
            }
            let data: Data
            do { data = try Data(contentsOf: file) }
            catch { throw CLIError.importUnrecognized("\(query): \(error)") }
            let basename = file.deletingPathExtension().lastPathComponent
            return (try parse(data, query, filename: file.lastPathComponent, context: ImportContext(file: file)), "file \(basename)", nil)
        }
        if isURL {
            guard let url = URL(string: query) else { throw CLIError.importUnrecognized("\(query): not a valid URL") }
            let data: Data
            do { data = try ctx.fetch(url) }
            catch { throw CLIError.network("\(error)") }
            return (try parse(data, query, filename: url.lastPathComponent), "url \(url.host ?? query)", nil)
        }

        let found = try HeadphoneLookup.resolve(
            query, source: sourceOption, variant: variant,
            autoEq: { try HeadphoneLookup.loadAutoEq(refresh: refresh, ctx) },
            opra: { try HeadphoneLookup.loadOPRA(refresh: refresh, ctx) })
        switch found {
        case .opra(let entry):
            guard entry.preamp.isFinite, Config.preampRange.contains(entry.preamp) else {
                throw CLIError.importRefused(String(format: "OPRA preset \u{201C}%@\u{201D} has preamp %g dB, outside %g…%g dB",
                                                   entry.id, entry.preamp, Config.preampRange.lowerBound, Config.preampRange.upperBound))
            }
            return (OPRA.result(entry), "OPRA \(entry.author) · \(entry.name)", OPRA.attribution(entry))
        case .autoEq(let entry):
            let what = "\(entry.name) from \(entry.source)"
            let data: Data
            do { data = try ctx.fetch(AutoEqIndex.fileURL(for: entry)) }
            catch let error as URLError where error.code == .fileDoesNotExist { throw CLIError.importNotFound(what) }
            catch { throw CLIError.network("\(error)") }
            return (try parse(data, what, filename: AutoEqIndex.fileURL(for: entry).lastPathComponent), "AutoEq \(entry.source) · \(entry.name)", nil)
        }
    }

    private static func devices(_ ctx: CLIContext) throws -> Output {
        let config = try loadConfig(ctx)
        let currentUID = (try? currentDevice(ctx))?.uid
        let rows = deviceRows(config, connected: ctx.connectedDevices())
        let lines = rows.map { row -> String in
            let marker = row.uid == currentUID ? Paint.ink(.green, "*") + " " : "  "
            let transport = Paint.ink(.dim, "[\(row.transport ?? "disconnected")]")
            let profile = row.profile == "own" ? Paint.ink(.green, "own profile") : Paint.ink(.yellow, "default profile")
            return "\(marker)\(Paint.ink(.bold, row.name))  \(transport)  \(profile)"
        }
        return Output(lines.joined(separator: "\n"), DevicesReport(current: currentUID, devices: rows))
    }

    /// The connected outputs in the system's order, then the devices with a profile that are not
    /// connected, by name.
    static func deviceRows(_ config: Config, connected: [CLIContext.ConnectedDevice]) -> [DeviceRow] {
        let live = connected.map { device in
            DeviceRow(uid: device.uid, name: device.name, transport: device.transport, connected: true,
                      profile: config.devices[device.uid] != nil ? "own" : "default")
        }
        let known = config.devices.sorted { ($0.value.name ?? $0.key) < ($1.value.name ?? $1.key) }
            .filter { uid, _ in !connected.contains { $0.uid == uid } }
            .map { DeviceRow(uid: $0.key, name: $0.value.name ?? $0.key, transport: nil, connected: false, profile: "own") }
        return live + known
    }

    private static func toggle(_ enabled: Bool, _ ctx: CLIContext) throws -> Output {
        var config = try loadConfig(ctx)
        config.enabled = enabled
        try ctx.store.save(config)
        let text = "eq " + (enabled ? Paint.ink(.green, "on") : Paint.ink(.yellow, "off (bypass)"))
        return Output(text, ToggleReport(enabled: enabled))
    }

    private static func status(_ ctx: CLIContext) throws -> Output {
        guard let status = Status.read(from: ctx.statusURL), status.isAlive() else { throw CLIError.daemonNotRunning }
        func label(_ text: String) -> String { Paint.ink(.dim, text + ":") }
        var lines = ["\(label("state")) \(Paint.ink(Paint.state(status.state), status.state.rawValue))"]
        if let driver = status.driver, status.mode == .driver {
            lines += driverStatusLines(status, driver, label)
        } else if let device = status.device {
            let hz = Paint.ink(.yellow, "\(Table.whole(status.sampleRate)) Hz")
            let transport = Paint.ink(.dim, "[\(device.transport)]")
            let profile: String
            switch status.profile {
            case .device?: profile = Paint.ink(.green, "device profile")
            case .default?: profile = Paint.ink(.yellow, "default profile")
            case nil: profile = "- profile"
            }
            let latency = latencyText(status).map { ", latency " + $0 } ?? ""
            lines.append("\(label("device")) \(Paint.ink(.bold, device.name)) \(transport) \(hz)\(latency), \(profile)")
        }
        let callbacks = Paint.ink(.yellow, "\(status.callbacks)")
        let frames = Paint.ink(.yellow, "\(status.framesProcessed)")
        let pid = Paint.ink(.yellow, "\(status.pid)")
        let version = Paint.ink(.yellow, status.version ?? "-")
        let enabled = Paint.ink(status.enabled ? .green : .yellow, "\(status.enabled)")
        let counts = status.mode == .driver ? "" : "\(label("callbacks")) \(callbacks)  \(label("frames")) \(frames)  "
        lines.append("\(counts)\(label("enabled")) \(enabled)  \(label("pid")) \(pid)  \(label("version")) \(version)")
        if let text = ringText(status) { lines.append("\(label("ring")) \(text)") }
        if let apps = status.apps, let line = appLine(apps.overlay, held: apps.held) { lines.append(line) }
        if let reduction = status.compReductionDB { lines.append("\(label("comp")) \(Paint.ink(.yellow, String(format: "%.1f dB", reduction == 0 ? 0 : reduction)))") }
        if let error = status.error { lines.append("\(Paint.ink(.red, "error:")) \(error)") }
        lines.append(contentsOf: (status.warnings ?? []).map { "\(Paint.ink(.yellow, "warning:")) \($0)" })
        if status.state == .noPermission { lines.append(Paint.ink(.yellow, permissionHint)) }
        return Output(lines.joined(separator: "\n"), status)
    }

    /// `mode: driver (BE-RCA · EQ → BE-RCA)`, then the target and what the plug-in reports about playing on it.
    static func driverStatusLines(_ status: Status, _ driver: Status.DriverStatus, _ label: (String) -> String) -> [String] {
        let target = driver.target?.name ?? "no target"
        var lines = ["\(label("mode")) \(Paint.ink(.bold, "driver")) (\(driver.deviceName) → \(target))"]
        if let device = driver.target {
            let hz = Paint.ink(.yellow, "\(Table.whole(status.sampleRate)) Hz")
            let latency = driver.latencyMs.map { ", latency " + Paint.ink(.yellow, "\(Table.whole($0)) ms") + " (reported to players)" } ?? ""
            let profile = status.profile == .device ? Paint.ink(.green, "device profile") : Paint.ink(.yellow, "default profile")
            lines.append("\(label("device")) \(Paint.ink(.bold, device.name)) \(Paint.ink(.dim, "[\(device.transport)]")) \(hz)\(latency), \(profile)")
        }
        let io = driver.ioRunning ? Paint.ink(.green, "IO running") : Paint.ink(.yellow, "IO idle")
        let eq = driver.eqActive ? Paint.ink(.green, "EQ active") : Paint.ink(.yellow, "no curve")
        let slips = driver.underruns + driver.overruns > 0 ? Paint.ink(.yellow, "\(driver.underruns) underruns, \(driver.overruns) overruns")
            : "\(driver.underruns) underruns, \(driver.overruns) overruns"
        let clock = String(format: "clock %+.1f ppm", driver.clockPpm)
        lines.append("\(label("driver")) \(io), \(eq), \(slips), \(clock)")
        if !driver.isDefault { lines.append("\(Paint.ink(.yellow, "warning:")) \(driver.deviceName) is not the default output") }
        return lines
    }

    /// Only when something went wrong: a healthy ring never under- or overruns, and a healthy engine drops nothing.
    static func ringText(_ status: Status) -> String? {
        ringCounts(status).map { Paint.ink(.yellow, $0) }
    }

    static func ringCounts(_ status: Status) -> String? {
        let underruns = status.underruns ?? 0, overruns = status.overruns ?? 0, dropouts = status.dropouts ?? 0
        guard underruns > 0 || overruns > 0 || dropouts > 0 else { return nil }
        func count(_ n: UInt64, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        let slips = count(underruns, "underrun") + ", " + count(overruns, "overrun")
        return dropouts > 0 ? slips + ", " + count(dropouts, "dropout") : slips
    }

    /// Whole milliseconds once the daemon splits the path: the device is what a player compensates, the rest it cannot.
    static func latencyText(_ status: Status, paint: Bool = Paint.enabled) -> String? {
        guard let total = status.latencyMs else { return nil }
        guard let device = status.deviceLatencyMs else { return Paint.ink(.yellow, String(format: "%.1f ms", total), on: paint) }
        let added = status.addedLatencyMs.map { ", eq adds " + Paint.ink(.yellow, Table.whole($0), on: paint) } ?? ""
        return Paint.ink(.yellow, "\(Table.whole(total)) ms", on: paint) + " (device \(Table.whole(device))\(added))"
    }

    private static func stream(_ args: [String], _ ctx: CLIContext) throws -> Output {
        guard args.isEmpty else { throw CLIError.usage("eq stream") }
        let client = MeterClient(socketURL: ctx.meterSocketURL)
        do { try client.connect() } catch { throw CLIError.noMeter }
        signal(SIGINT) { _ in _exit(0) }
        let eof = client.lines(maxLines: ctx.streamLimit) { line in ctx.emit(line); return true }
        client.close()
        if eof { throw CLIError.daemonClosedMeter }
        var output = Output("", ["ok": true])
        output.streamed = true
        return output
    }

    private static func events(_ args: [String], _ ctx: CLIContext) throws -> Output {
        guard args.isEmpty else { throw CLIError.usage("eq events") }
        let client = MeterClient(socketURL: ctx.meterSocketURL)
        do {
            try client.connect()
            try client.send(#"{"subscribe":"events"}"#)
        } catch {
            client.close()
            throw CLIError.noEvents
        }
        signal(SIGINT) { _ in _exit(0) }
        // A daemon that predates events ignores the request and streams meter frames. A new one
        // answers with a `daemon` event, but a request that lands after its first tick still gets a
        // frame or two before that; only a second of nothing but frames means an old daemon.
        var answered = false
        let giveUp = DispatchTime.now() + 1
        let eof = client.lines(maxLines: ctx.streamLimit) { line in
            if !answered {
                let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                guard object?["event"] != nil else { return DispatchTime.now() < giveUp }
                answered = true
            }
            ctx.emit(line)
            return true
        }
        client.close()
        if !answered { throw CLIError.noEvents }
        if eof { throw CLIError.daemonClosedEvents }
        var output = Output("", ["ok": true])
        output.streamed = true
        return output
    }

    private static func watch(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let usage = "eq watch [--zones] " + LookSettings.flagsUsage
        let (look, rest) = try LookSettings.parseFlags(args)
        guard rest.allSatisfy({ $0 == "--zones" }) else { throw CLIError.usage(usage) }
        return try meter(zones: !rest.isEmpty, look: look, command: "watch", ctx)
    }

    /// `eq tui [VIEW]` opens on VIEW, the meter by default, as `eq watch` does.
    private static func tui(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let view = args.first.flatMap(TUIView.init(rawValue:))
        let (look, rest) = try LookSettings.parseFlags(view == nil ? args : Array(args.dropFirst()))
        guard rest.allSatisfy({ $0 == "--zones" }) else {
            if let name = rest.first(where: { !$0.hasPrefix("-") }) {
                let views = TUIView.allCases.map(\.rawValue).joined(separator: ", ")
                throw CLIError.usage("eq tui has no view \"\(name)\" yet; there are \(views)")
            }
            throw CLIError.usage("eq tui [VIEW] [--zones] " + LookSettings.flagsUsage)
        }
        return try meter(zones: !rest.isEmpty, look: look, command: "tui", view: view ?? .meter, ctx)
    }

    private static func meter(zones: Bool, look flags: TUIOptions, command: String, view: TUIView = .meter, _ ctx: CLIContext) throws -> Output {
        let terminal = ctx.terminal()
        try Watch.requireTerminal(isTTY: terminal.isTTY, command: command)
        let client = MeterClient(socketURL: ctx.meterSocketURL)
        do { try client.connect() } catch { throw CLIError.noMeter }
        let events = MeterClient(socketURL: ctx.meterSocketURL)
        let session = WatchSession(ctx)
        let environment = ProcessInfo.processInfo.environment
        let settings = LookSettings.resolve(flags: flags, saved: (try? loadConfig(ctx))?.tui, env: environment)
        var childEnvironment = environment
        // The child writes to a pipe: it paints only when told, and not at all when the TUI does not.
        if settings.depth == .none { childEnvironment["NO_COLOR"] = "1" } else { childEnvironment["CLICOLOR_FORCE"] = "1" }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let children = ChildRunner(executable: executable, environment: childEnvironment)
        var jobEnvironment = environment
        jobEnvironment["NO_COLOR"] = "1"
        let jobs = Dictionary(uniqueKeysWithValues: MeterJob.allCases.map { ($0, ChildRunner(executable: executable, environment: jobEnvironment)) })
        let historyURL = ctx.stateDirectory.appendingPathComponent("tui-history")
        let history = ((try? String(contentsOf: historyURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).reversed()
        let effects = MeterEffects(edit: session.apply, header: session.header, send: client.send, mouse: Terminal.setMouse,
                                   connect: {
                                       client.close()
                                       try? client.connect()
                                       return client.descriptor
                                   },
                                   disconnect: client.close,
                                   connectEvents: {
                                       events.close()
                                       guard (try? events.connect()) != nil, (try? events.send(#"{"subscribe":"events"}"#)) != nil else {
                                           events.close()
                                           return nil
                                       }
                                       return events.descriptor
                                   },
                                   complete: { Completions.names($0, ctx) },
                                   children: children,
                                   saveHistory: { lines in
                                       try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(),
                                                                                withIntermediateDirectories: true)
                                       try? (lines.reversed().joined(separator: "\n") + "\n").write(to: historyURL, atomically: true, encoding: .utf8)
                                   },
                                   library: { CLI.library(ctx) },
                                   apps: ctx.audioApps,
                                   system: { CLI.systemInfo(ctx) },
                                   history: { CLI.historyList(ctx) },
                                   jobs: jobs,
                                   target: { session.device = $0 })
        Terminal.enter()
        let size = Terminal.size() ?? Size(cols: terminal.cols, rows: terminal.rows)
        let model = MeterModel(size: size, zones: zones, header: session.header(), reconnects: command == "tui", look: settings, view: view,
                               history: Array(history.prefix(CommandPalette.historyLimit)))
        let runtime = Runtime(model, size: size, translate: MeterEffects.translate, perform: effects.perform)
        if let fd = client.descriptor { runtime.watch(fd: fd, id: MeterEffects.meterSource, latestOnly: true) }
        runtime.send(.start)
        let exitCode = runtime.run()
        Terminal.leave()
        children.finish()
        jobs.values.forEach { $0.finish() }
        client.close()
        events.close()
        // Dying of SIGTERM or SIGHUP tells the parent why; Ctrl-C from kill ends like q.
        if let signal = runtime.endedBy, signal != SIGINT { Terminal.reraise(signal) }
        var output = Output(exitCode == 1 ? "\(CLIError.daemonClosedMeter)" : "", ["ok": exitCode == 0])
        output.exitCode = exitCode
        output.streamed = true
        return output
    }

    static func watchEdit(_ action: WatchAction, _ ctx: CLIContext) throws {
        try WatchSession(ctx).apply(action)
    }

    /// The edits of one `eq watch`, on the same device `eq set` would edit. Only the session's first
    /// save backs up the file, so the whole session is one `eq undo` step; `u` walks back inside it
    /// through what each save replaced: device profiles, presets, app rules.
    final class WatchSession {
        struct Note: Error, CustomStringConvertible { let description: String }

        /// The parts of the config one save changed, as they were before it.
        struct Before {
            var devices: [String: Profile?] = [:]
            var presets: [String: Profile?] = [:]
            /// There were no presets yet: undo leaves none, as `eq preset` found it.
            var unseeded = false
            var apps: [AppRule]?? = nil
            var experimental: Experimental?? = nil
            var fallback: Profile? = nil

            init?(_ original: Config, _ config: Config) {
                for uid in Set(original.devices.keys).union(config.devices.keys) where original.devices[uid] != config.devices[uid] {
                    devices[uid] = .some(original.devices[uid])
                }
                if original.presets == nil, config.presets != nil {
                    unseeded = true
                } else {
                    for name in Set((original.presets ?? [:]).keys).union((config.presets ?? [:]).keys)
                        where original.presets?[name] != config.presets?[name] {
                        presets[name] = .some(original.presets?[name])
                    }
                }
                if original.apps != config.apps { apps = .some(original.apps) }
                if original.experimental != config.experimental { experimental = .some(original.experimental) }
                if original.default != config.default { fallback = original.default }
                guard !devices.isEmpty || !presets.isEmpty || unseeded || apps != nil || experimental != nil || fallback != nil else { return nil }
            }

            func restore(_ config: inout Config) {
                for (uid, profile) in devices { config.devices[uid] = profile }
                if unseeded {
                    config.presets = nil
                } else if !presets.isEmpty {
                    var all = config.presets ?? [:]
                    for (name, profile) in presets { all[name] = profile }
                    config.presets = all
                }
                if let apps { config.apps = apps }
                if let experimental { config.experimental = experimental }
                if let fallback { config.default = fallback }
            }
        }

        private let ctx: CLIContext
        private var history: [Before] = []
        private var lastSaved: Config?
        /// The device the Tune view edits when it is not the one playing; nil edits the current one.
        var device: DeviceChoice?

        init(_ ctx: CLIContext) { self.ctx = ctx }

        private func target() throws -> Target {
            if let device { return (device.uid, device.name) }
            return try currentDevice(ctx)
        }

        func header() -> Watch.Header {
            guard let config = try? loadConfig(ctx), let target = try? currentDevice(ctx) else { return Watch.Header() }
            let profile = config.profile(forDeviceUID: target.uid).profile
            return Watch.Header(preset: CLI.presetMark(profile, config), preference: profile.preference, knobs: profile.instruments,
                                dynamics: profile.dynamics, mouse: config.tui?.mouse == true, profile: profile)
        }

        func apply(_ action: WatchAction) throws {
            if case .useDevice(let uid) = action {
                try CLI.useDevice([uid], ctx)
                return
            }
            let original = try loadConfig(ctx)
            var config = original
            if case .undo = action {
                guard let last = history.popLast() else { throw Note(description: "nothing left to undo in this session") }
                last.restore(&config)
                try save(config, over: original)
                return
            }
            if let edit = Self.tuiEdit(action) {
                var options = config.tui ?? TUIOptions()
                edit(&options)
                config.tui = options.isEmpty ? nil : options
                if config != original { try save(config, over: original) }
                return
            }
            if case .restoreVersion(let index) = action {
                try CLI.restoreVersion(index, ctx)
                // The live file is another version now: this session's steps no longer lead back from it.
                history = []
                lastSaved = nil
                return
            }
            switch action {
            case .savePreset(let name):
                try CLI.savePreset(name, on: try target(), in: &config)
            case .usePreset(let name):
                _ = config.seedPresetsIfNeeded()
                try CLI.usePreset(name, on: try target(), in: &config)
            case .renamePreset(let old, let new):
                _ = config.seedPresetsIfNeeded()
                _ = try CLI.renamePreset(old, to: new, in: &config)
            case .removePreset(let name):
                _ = config.seedPresetsIfNeeded()
                _ = try CLI.removePreset(name, in: &config)
            case .copyCurve(let to):
                CLI.copyCurve(from: try currentDevice(ctx), to: (to.uid, to.name), in: &config)
            case .setAppRule(let query, let preset):
                try CLI.setAppRule(try CLI.resolveApp(query, ctx), preset: preset, in: &config)
            case .removeAppRule(let query):
                try CLI.removeAppRule(query, in: &config, ctx)
            case .followApps(let on):
                config.setFollowsApps(on)
            default:
                let target = try target()
                guard let profile = try edited(editableProfile(config, target), by: action, &config) else { return }
                config.setProfile(profile, forDeviceUID: target.uid)
            }
            guard config != original else { return }
            try save(config, over: original)
            if let before = Before(original, config) { history.append(before) }
        }

        /// The settings of the screen itself, which no undo walks back.
        private static func tuiEdit(_ action: WatchAction) -> ((inout TUIOptions) -> Void)? {
            switch action {
            case .mouse: return { $0.mouse = $0.mouse == true ? nil : true }
            case .setLook(let look): return { $0.look = look }
            case .setPalette(let palette): return { $0.palette = palette }
            default: return nil
            }
        }

        /// Rounded to hundredths so an imported 3.7 stepped up saves as 4.2, not 4.2000000000000002.
        private func edited(_ before: Profile, by action: WatchAction, _ config: inout Config) throws -> Profile? {
            var profile = before
            func stepped(_ value: Double, _ delta: Double, _ range: ClosedRange<Double>) -> Double {
                (min(max(value + delta, range.lowerBound), range.upperBound) * 100).rounded() / 100
            }
            switch action {
            case .bandStep(let band, let delta):
                guard profile.bands.indices.contains(band) else { return nil }
                profile.bands[band] = stepped(profile.bands[band], delta, Config.gainRange)
            case .preamp(let delta):
                profile.preamp = stepped(profile.preamp, delta, Config.preampRange)
            case .bass(let delta):
                profile.setPreference { $0.bass = stepped($0.bass, delta, Config.gainRange) }
            case .treble(let delta):
                profile.setPreference { $0.treble = stepped($0.treble, delta, Config.gainRange) }
            case .boost(let instrument, let delta):
                profile.setKnob(instrument) { stepped($0, delta, Config.gainRange) }
            case .cycleComp:
                profile.setDynamics { $0.comp = Self.next($0.comp, in: Dynamics.Compressor.allCases) }
            case .cycleColour:
                profile.setDynamics { layer in
                    layer.color = Self.next(layer.color?.kind, in: Dynamics.ColourKind.allCases)
                        .map { .init(kind: $0, amount: layer.color?.amount ?? Self.colourStart) }
                }
            case .colourAmount:
                guard let colour = profile.dynamics?.color else { throw Note(description: "color is off — v turns it on") }
                // Up a tenth at a time, and from 1 round to 0.1: one key covers the whole range.
                let amount = colour.amount >= 1 ? 0.1 : ((colour.amount * 10).rounded(.down) + 1) / 10
                profile.setDynamics { $0.color?.amount = amount }
            case .cyclePreset, .previousPreset:
                _ = config.seedPresetsIfNeeded()
                let names = (config.presets ?? [:]).keys.sorted { $0.lowercased() < $1.lowercased() }
                guard !names.isEmpty else { throw Note(description: "no presets — press s to save one") }
                let at = profile.preset.flatMap { name in names.firstIndex { $0.lowercased() == name.lowercased() } }
                let step = action == .previousPreset ? names.count - 1 : 1
                let next = names[at.map { ($0 + step) % names.count } ?? (action == .previousPreset ? names.count - 1 : 0)]
                profile = config.presets![next]!
                profile.name = before.name
                profile.preset = next
            case .adjust(let control, let delta):
                try control.adjust(&profile, by: delta)
            case .assign(let control, let value):
                try control.assign(&profile, value)
            case .addFilter(let filter):
                _ = CLI.addFilter(filter, to: &profile)
            case .setFilter(let index, let filter):
                _ = try CLI.setFilter(index, in: &profile) {
                    $0.type = filter.type
                    $0.frequency = filter.frequency
                    $0.gain = filter.gain
                    $0.q = filter.q
                }
            case .removeFilter(let index):
                _ = try CLI.removeFilter(index, from: &profile)
            case .usePreset, .renamePreset, .removePreset, .useDevice, .copyCurve, .setAppRule, .removeAppRule, .followApps, .restoreVersion,
                 .undo, .savePreset, .startSave, .zones, .help, .quit,
                 .focusNext, .focusPrevious, .unfocus, .listen, .knob, .mouse, .palette,
                 .closeModal, .scrollUp, .scrollDown, .pageUp, .pageDown, .top, .bottom, .nextLook, .nextPalette, .setLook, .setPalette,
                 .goMenu, .go, .back, .focusInMeter, .pause, .filter, .stop, .suspend,
                 .tuneSelect, .tuneGroup, .nudge, .tuneReset, .tuneEntry,
                 .primary, .startRename, .startDelete, .toggleDiff, .copyHere, .editInTune, .startAdd, .editFields, .field, .otherDevice,
                 .fieldEntry, .toggleApps, .switchMode, .refresh, .historyStep, .search, .run:
                return nil
            }
            return profile == before ? nil : profile
        }

        static let colourStart = 0.3

        /// Off, then each case in turn, then off again.
        private static func next<T: Equatable>(_ current: T?, in cases: [T]) -> T? {
            guard let current, let at = cases.firstIndex(of: current) else { return cases.first }
            return at + 1 < cases.count ? cases[at + 1] : nil
        }

        /// A session edit may skip the backup only while the file is still what this session last
        /// wrote; anything another command or a hand edit put there in between must be backed up.
        private func save(_ config: Config, over original: Config) throws {
            try ctx.store.save(config, as: lastSaved != nil && original == lastSaved ? .sessionEdit : .edit)
            lastSaved = config
        }
    }

    /// Saves the target's curve as `name`, replacing a preset of that name in any case, and marks
    /// the target as using it.
    static func savePreset(_ rawName: String, on target: Target, in config: inout Config) throws {
        let name = Config.normalizedPresetName(rawName)
        guard Config.isValidPresetName(name) else { throw CLIError.badPresetName(rawName) }
        _ = config.seedPresetsIfNeeded()
        var profile = editableProfile(config, target)
        if let old = config.preset(named: name) { config.presets?[old.name] = nil }
        config.presets?[name] = Profile(name: nil, preamp: profile.preamp, bands: profile.bands,
                                        filters: profile.filters, imported: profile.imported, preference: profile.preference,
                                        instruments: profile.instruments, dynamics: profile.dynamics)
        profile.preset = name
        config.setProfile(profile, forDeviceUID: target.uid)
    }

    private static func preset(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        var config = try loadConfig(ctx)
        _ = config.seedPresetsIfNeeded()
        let usage = "eq preset [list | save|use|show|rm <name> | rename <old> <new>] [--device DEVICE]"
        func target() throws -> Target { if let explicit { return explicit } else { return try currentDevice(ctx) } }
        func existing(_ name: String) throws -> (name: String, profile: Profile) {
            guard let found = config.preset(named: name) else { throw CLIError.noSuchPreset(name) }
            return found
        }
        func validName(_ name: String) throws -> String {
            let trimmed = Config.normalizedPresetName(name)
            guard Config.isValidPresetName(trimmed) else { throw CLIError.badPresetName(name) }
            return trimmed
        }
        let takesDevice = ["save", "use"].contains(rest.first ?? "")
        guard explicit == nil || takesDevice else { throw CLIError.usage(usage) }

        switch (rest.first, rest.count) {
        case (nil, _), ("list", 1):
            return presetList(config, ctx)
        case ("save", 2):
            let name = try validName(rest[1])
            let target = try target()
            try savePreset(name, on: target, in: &config)
            let profile = editableProfile(config, target)
            try ctx.store.save(config)
            let text = Paint.ink(.green, "saved ") + Paint.ink(.bold, name) + "\n"
                + Table.profile(profile, header: target.name, preset: (name, false))
            return Output(text, ProfileReport(device: DeviceRef(uid: target.uid, name: target.name), source: "device", profile: profile, preset: name))
        case ("use", 2):
            let target = try target()
            let (name, profile) = try usePreset(rest[1], on: target, in: &config)
            try ctx.store.save(config)
            let table = Table.profile(profile, header: target.name, preset: (name, false))
            return Output(table, ProfileReport(device: DeviceRef(uid: target.uid, name: target.name), source: "device", profile: profile, preset: name))
        case ("show", 2):
            let found = try existing(rest[1])
            return Output(Table.profile(found.profile, header: found.name), PresetShowReport(preset: found.name, profile: found.profile))
        case ("rm", 2):
            let name = try removePreset(rest[1], in: &config)
            try ctx.store.save(config)
            return Output(Paint.ink(.green, "removed ") + Paint.ink(.bold, name), PresetRemovedReport(removed: name))
        case ("rename", 3):
            let (from, to) = try renamePreset(rest[1], to: rest[2], in: &config)
            try ctx.store.save(config)
            let text = Paint.ink(.green, "renamed ") + Paint.ink(.bold, from) + " → " + Paint.ink(.bold, to)
            return Output(text, PresetRenamedReport(from: from, to: to))
        default:
            throw CLIError.usage(usage)
        }
    }

    /// The preset, whole, as the target's curve, marked as using it.
    @discardableResult
    static func usePreset(_ query: String, on target: Target, in config: inout Config) throws -> (name: String, profile: Profile) {
        guard let found = config.preset(named: query) else { throw CLIError.noSuchPreset(query) }
        var profile = found.profile
        profile.name = target.name
        profile.preset = found.name
        config.setProfile(profile, forDeviceUID: target.uid)
        return (found.name, profile)
    }

    /// Its name as stored; a device that used it keeps the curve and loses the mark.
    static func removePreset(_ query: String, in config: inout Config) throws -> String {
        guard let found = config.preset(named: query) else { throw CLIError.noSuchPreset(query) }
        config.presets?[found.name] = nil
        renamePresetReferences(&config, from: found.name, to: nil)
        return found.name
    }

    /// Devices and app rules that named it follow the new name.
    static func renamePreset(_ query: String, to raw: String, in config: inout Config) throws -> (from: String, to: String) {
        guard let found = config.preset(named: query) else { throw CLIError.noSuchPreset(query) }
        let name = Config.normalizedPresetName(raw)
        guard Config.isValidPresetName(name) else { throw CLIError.badPresetName(raw) }
        if let clash = config.preset(named: name), clash.name != found.name { throw CLIError.presetExists(clash.name) }
        config.presets?[found.name] = nil
        config.presets?[name] = found.profile
        renamePresetReferences(&config, from: found.name, to: name)
        return (found.name, name)
    }

    private static func presetList(_ config: Config, _ ctx: CLIContext) -> Output {
        let profile = (try? currentDevice(ctx)).map { config.profile(forDeviceUID: $0.uid).profile }
        let mark = profile.flatMap { presetMark($0, config) }
        let entries = (config.presets ?? [:]).sorted { $0.key.lowercased() < $1.key.lowercased() }
        let width = entries.map(\.key.count).max() ?? 0
        let lines = entries.map { name, preset -> String in
            let isCurrent = name == mark?.name
            let marker = isCurrent ? Paint.ink(.green, "*") + " " : "  "
            let label = Table.presetLabel((name, isCurrent && mark?.modified == true))
            let pad = String(repeating: " ", count: width - name.count + (isCurrent && mark?.modified == true ? 0 : 1))
            let filters = preset.filters.isEmpty ? "" : Paint.ink(.cyan, "  +\(preset.filters.count) filters")
            let preamp = "preamp " + Paint.ink(Paint.gain(preset.preamp), Table.gain(preset.preamp))
            return "\(marker)\(label)\(pad)  \(Table.compactGains(preset.bands))  \(preamp)\(filters)"
        }
        let report = PresetsReport(current: mark?.name, presets: entries.map { PresetEntry(name: $0.key, profile: $0.value) })
        return Output(lines.joined(separator: "\n"), report)
    }

    private static func renamePresetReferences(_ config: inout Config, from old: String, to new: String?) {
        let needle = old.lowercased()
        if config.default.preset?.lowercased() == needle { config.default.preset = new }
        for (uid, profile) in config.devices where profile.preset?.lowercased() == needle {
            config.devices[uid]?.preset = new
        }
        // A removed preset leaves its app rules in place: they match nothing until a preset of that name exists again.
        if let new, let rules = config.apps {
            config.apps = rules.map { $0.preset.lowercased() == needle ? AppRule(app: $0.app, preset: new) : $0 }
        }
    }

    private static func undo(_ args: [String], _ ctx: CLIContext) throws -> Output {
        guard args.isEmpty || args == ["--list"] else { throw CLIError.usage("eq undo [--list]") }
        if args == ["--list"] { return try history([], ctx) }
        guard ctx.store.exists() else { throw CLIError.noBackup }
        let note = try ctx.store.reconcileHistory()
        let target = ctx.store.historyPosition() + 1
        do {
            guard let stepped = try ctx.store.stepBack() else { throw noStep(.noBackup, note) }
            return try steppedOutput(stepped, note: note, ctx)
        } catch is ConfigError {
            throw CLIError.unreadableBackup(target)
        }
    }

    private static func redo(_ args: [String], _ ctx: CLIContext) throws -> Output {
        guard args.isEmpty else { throw CLIError.usage("eq redo") }
        guard ctx.store.exists() else { throw CLIError.noRedo }
        let note = try ctx.store.reconcileHistory()
        let target = max(ctx.store.historyPosition() - 1, 0)
        do {
            guard let stepped = try ctx.store.stepForward() else { throw noStep(.noRedo, note) }
            return try steppedOutput(stepped, note: note, ctx)
        } catch is ConfigError {
            throw CLIError.unreadableBackup(target)
        }
    }

    /// The reset note explains why there is suddenly nothing to redo, so it rides along with the error.
    private static func noStep(_ error: CLIError, _ note: String?) -> Error {
        guard let note else { return error }
        FileHandle.standardError.write(Data("warning: \(note)\n".utf8))
        return error
    }

    private static func steppedOutput(_ stepped: (index: Int, date: Date), note: String?, _ ctx: CLIContext) throws -> Output {
        var heading = Paint.ink(.green, "restored the config from ") + Paint.ink(.dim, backupTime(stepped.date))
        if let note { heading = "\(Paint.ink(.yellow, "warning:")) \(note)\n" + heading }
        guard let device = try? currentDevice(ctx) else {
            return Output(heading, HistoryStepReport(position: stepped.index, date: stepped.date, device: nil, source: nil,
                                                     profile: nil, warning: note))
        }
        let config = try ctx.store.load()
        let resolved = config.profile(forDeviceUID: device.uid)
        let sourceLabel = resolved.source == .device ? "own profile" : "default profile"
        let table = Table.profile(resolved.profile, header: "\(device.name) (\(sourceLabel))", preset: presetMark(resolved.profile, config))
        let report = HistoryStepReport(position: stepped.index, date: stepped.date,
                                       device: DeviceRef(uid: device.uid, name: device.name),
                                       source: resolved.source == .device ? "device" : "default", profile: resolved.profile,
                                       warning: note)
        return Output(heading + "\n" + table, report)
    }

    /// One saved version as `eq history` lists it: the current device's profile in it, nil when
    /// it cannot be read.
    struct HistoryVersion: Equatable {
        var index: Int
        var url: URL
        var date: Date
        var config: Config?
        var profile: Profile?
    }

    /// The versions `eq undo` and `eq redo` walk through, newest first, and where they sit; the
    /// bookkeeping is reconciled first, which `note` then explains.
    static func historyVersions(_ ctx: CLIContext) throws -> (position: Int, note: String?, versions: [HistoryVersion]) {
        guard ctx.store.exists() else { return (0, nil, []) }
        // Without it a hand edit mid-undo and a stash left by an interrupted step are missing from the list.
        let note = try ctx.store.reconcileHistory()
        let device = try? currentDevice(ctx)
        func version(_ index: Int, _ url: URL, _ date: Date) -> HistoryVersion {
            let config = try? ctx.store.load(at: url)
            return HistoryVersion(index: index, url: url, date: date, config: config,
                                  profile: config.flatMap { config in device.map { config.profile(forDeviceUID: $0.uid).profile } })
        }
        var versions = ctx.store.latestVersion().map { [version(0, $0.url, $0.date)] } ?? []
        versions += ctx.store.backups().map { version($0.index, $0.url, $0.date) }
        return (ctx.store.historyPosition(), note, versions)
    }

    /// Steps `eq undo` or `eq redo` takes, one at a time, until the live config is version `index`.
    @discardableResult
    static func restoreVersion(_ index: Int, _ ctx: CLIContext) throws -> (index: Int, date: Date)? {
        try ctx.store.reconcileHistory()
        guard index == 0 || ctx.store.backups().contains(where: { $0.index == index }) else {
            throw index > ctx.store.historyPosition() ? CLIError.noBackup : CLIError.noRedo
        }
        var stepped: (index: Int, date: Date)?
        while ctx.store.historyPosition() != index {
            let back = ctx.store.historyPosition() < index
            guard let step = try back ? ctx.store.stepBack() : ctx.store.stepForward() else {
                throw back ? CLIError.noBackup : CLIError.noRedo
            }
            stepped = step
        }
        return stepped
    }

    /// Position 0 is the latest edit, `.1`…`.10` the backup chain; `←` marks where `eq undo`/`eq redo`
    /// currently sit. `eq undo --list` is an alias kept for muscle memory.
    private static func history(_ args: [String], _ ctx: CLIContext) throws -> Output {
        guard args.isEmpty else { throw CLIError.usage("eq history") }
        guard ctx.store.exists() else {
            return Output(Paint.ink(.dim, "no history yet — the defaults are in use and nothing has been saved"),
                          HistoryReport(position: 0, entries: [], warning: nil))
        }
        let (position, note, versions) = try historyVersions(ctx)
        var lines: [String] = note.map { ["\(Paint.ink(.yellow, "warning:")) \($0)"] } ?? []
        var rows: [HistoryRow] = []
        for version in versions {
            var line = String(format: "%3d  ", version.index) + Paint.ink(.dim, backupTime(version.date))
            if let config = version.config, let profile = version.profile {
                line += "  " + Table.compactGains(profile.bands)
                line += "  preamp " + Paint.ink(Paint.gain(profile.preamp), Table.gain(profile.preamp))
                if !profile.filters.isEmpty { line += Paint.ink(.cyan, "  +\(profile.filters.count) filters") }
                if let layer = profile.preference, !layer.isFlat { line += "  pref " + Table.preference(layer) }
                if !profile.knobs.isEmpty { line += "  boost " + Table.knobs(profile) }
                if let layer = profile.dynamics, !layer.isOff { line += "  " + Table.dynamics(layer) }
                if !config.enabled { line += "  " + Paint.ink(.yellow, "off") }
                if let mark = presetMark(profile, config) { line += "  " + Table.presetLabel(mark) }
            } else if version.config == nil {
                line += "  " + Paint.ink(.red, "unreadable")
            }
            if version.index == position { line += Paint.ink(.green, " ←") }
            lines.append(line)
            rows.append(HistoryRow(index: version.index, path: version.url.path, date: version.date, enabled: version.config?.enabled,
                                   profile: version.profile, current: version.index == position))
        }
        return Output(lines.joined(separator: "\n"), HistoryReport(position: position, entries: rows, warning: note))
    }

    private static func backupTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// One row per instrument range: its Hz span and the band columns it touches.
    private static func zones(_ args: [String], _ ctx: CLIContext) throws -> Output {
        guard args.isEmpty else { throw CLIError.usage("eq zones") }
        return Output(InstrumentTable.render(Instruments.all).joined(separator: "\n"), Instruments.all)
    }

    private static func doctor(_ ctx: CLIContext) -> Output {
        let probes = ctx.doctorProbes?() ?? DoctorProbes.live(store: ctx.store, statusURL: ctx.statusURL)
        let report = Doctor.run(probes)
        var output = Output(Doctor.text(report), report)
        output.exitCode = report.ok ? 0 : 1
        return output
    }

    // MARK: - Helpers

    typealias Target = (uid: String, name: String)

    static func loadConfig(_ ctx: CLIContext) throws -> Config {
        try ctx.store.loadOrDefault { ctx.connectedDevices().first { $0.transport == "builtin" }.map { ($0.uid, $0.name) } }
    }

    static func currentDevice(_ ctx: CLIContext) throws -> Target {
        if let status = Status.read(from: ctx.statusURL), status.isAlive(), let device = status.device {
            return (device.uid, device.name)
        }
        guard let device = ctx.defaultOutput() else { throw CLIError.noCurrentDevice }
        // The EQ device has no curve of its own: its target's is the one heard.
        if device.uid == DriverControl.deviceUID, let health = (try? ctx.driver()?.health()).map(DriverHealth.init), !health.target.isEmpty {
            return (health.target, health.targetName.isEmpty ? health.target : health.targetName)
        }
        return device
    }

    static func presetMark(_ profile: Profile, _ config: Config) -> Table.PresetMark? {
        presetMark(profile, presets: config.presets)
    }

    static func presetMark(_ profile: Profile, presets: [String: Profile]?) -> Table.PresetMark? {
        let needle = profile.preset?.lowercased()
        guard let needle, let preset = presets?.first(where: { $0.key.lowercased() == needle }) else { return nil }
        return (preset.key, !profile.sameCurve(as: preset.value))
    }

    static func editableProfile(_ config: Config, _ target: Target) -> Profile {
        var profile = config.profile(forDeviceUID: target.uid).profile
        profile.name = target.name
        return profile
    }

    static func splitDeviceOption(_ args: [String], flag: String, _ ctx: CLIContext) throws -> (Target?, [String]) {
        guard let at = args.firstIndex(of: flag) else { return (nil, args) }
        guard at + 1 < args.count else { throw CLIError.usage("\(flag) needs a device name") }
        var rest = args
        rest.removeSubrange(at...(at + 1))
        return (try resolveDevice(args[at + 1], ctx), rest)
    }

    static func resolveDevice(_ query: String, _ ctx: CLIContext) throws -> Target {
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
