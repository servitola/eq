import Foundation

struct CLIContext {
    typealias ConnectedDevice = (uid: String, name: String, transport: String)

    var store: ConfigStore
    var statusURL: URL
    var connectedDevices: () -> [ConnectedDevice]
    var defaultOutput: () -> (uid: String, name: String)?
    var fetch: (URL) throws -> Data
    var cacheDirectory: URL
    var today: () -> String
    var doctorProbes: (() -> DoctorProbes)? = nil
    var meterSocketURL: URL = Status.defaultURL.deletingLastPathComponent().appendingPathComponent("meter.sock")
    var streamLimit: Int? = nil
    var emit: (String) -> Void = { line in print(line); fflush(stdout) }
    var terminal: () -> (isTTY: Bool, cols: Int, rows: Int) = LiveTerminal.probe
    var width: (Int32) -> Int = LiveTerminal.width

    static func live() -> CLIContext {
        CLIContext(
            store: ConfigStore(url: ConfigStore.defaultURL),
            statusURL: Status.defaultURL,
            connectedDevices: { AudioDeviceManager.outputDevices().map { ($0.uid, $0.name, $0.transportName) } },
            defaultOutput: {
                AudioDeviceManager.defaultOutputDeviceID().flatMap(AudioDeviceManager.device).map { ($0.uid, $0.name) }
            },
            fetch: HTTPFetch.live,
            cacheDirectory: AutoEqCache.defaultDirectory,
            today: {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.calendar = Calendar.current
                return formatter.string(from: Date())
            })
    }

}

enum CLI {
    static let permissionHint = "System Settings → Privacy & Security → Screen & System Audio Recording → enable EQ, then: launchctl kickstart -k gui/$UID/com.servitola.eq"

    /// `isError` marks a thrown error, the only output that belongs on stderr; a report that merely
    /// exits non-zero (a failing `doctor`) is still the answer and goes to stdout.
    static func run(_ args: [String], context: CLIContext) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        let wantsJSON = args.contains("--json")
        let args = args.filter { $0 != "--json" }
        let command = args.first ?? "show"
        do {
            if wantsJSON && args.first == "watch" { throw CLIError.usage("eq watch has no JSON form; use eq stream") }
            let output = try dispatch(args, context)
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

    private static func dispatch(_ args: [String], _ ctx: CLIContext) throws -> Output {
        var rest = args
        let command = rest.isEmpty ? "show" : rest.removeFirst()
        if rest.contains("--help") || rest.contains("-h") || ["help", "-h", "--help"].contains(command) {
            let topic = ["help", "-h", "--help"].contains(command) ? (rest.first { !$0.hasPrefix("-") } ?? "") : command
            let text = helpText(for: topic, width: ctx.width(1), paint: Paint.enabled)
            return Output(text, UsageReport(usage: helpText(for: topic, width: 80, paint: false)))
        }
        switch command {
        case "show": return try show(ctx)
        case "init": return try initialise(ctx)
        case "set": return try set(rest, ctx)
        case "preamp": return try preamp(rest, ctx)
        case "flat": return try flat(rest, ctx)
        case "copy": return try copy(rest, ctx)
        case "import": return try importCommand(rest, ctx)
        case "filter": return try filter(rest, ctx)
        case "bass", "treble", "tilt": return try preference(command, rest, ctx)
        case "devices": return try devices(ctx)
        case "on": return try toggle(true, ctx)
        case "off": return try toggle(false, ctx)
        case "status": return try status(ctx)
        case "doctor": return doctor(ctx)
        case "stream": return try stream(rest, ctx)
        case "watch": return try watch(rest, ctx)
        case "zones": return try zones(rest, ctx)
        case "preset": return try preset(rest, ctx)
        case "undo": return try undo(rest, ctx)
        case "redo": return try redo(rest, ctx)
        case "history": return try history(rest, ctx)
        default: throw CLIError.usage("unknown command \"\(command)\"")
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
        return Output(table, ProfileReport(device: DeviceRef(uid: current.uid, name: current.name), source: source,
                                           profile: resolved.profile, preset: mark?.name))
    }

    private static func initialise(_ ctx: CLIContext) throws -> Output {
        let builtIn = ctx.connectedDevices().first { $0.transport == "builtin" }
        let existed = ctx.store.exists()
        var config = try ctx.store.loadOrCreate(builtInUID: builtIn?.uid, builtInName: builtIn?.name)
        if config.seedPresetsIfNeeded() { try ctx.store.save(config, as: .bookkeeping) }
        let path = Paint.ink(.dim, ctx.store.url.path)
        let text = existed ? "config already exists: \(path)" : Paint.ink(.green, "wrote") + " \(path)"
        return Output(text, InitReport(path: ctx.store.url.path, created: !existed))
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

    private static func copy(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let (target, rest) = try splitDeviceOption(args, flag: "--to", ctx)
        guard let target, rest.isEmpty else { throw CLIError.usage("eq copy --to DEVICE") }
        var config = try loadConfig(ctx)
        let current = try currentDevice(ctx)
        var profile = config.profile(forDeviceUID: current.uid).profile
        profile.name = target.name
        config.setProfile(profile, forDeviceUID: target.uid)
        try ctx.store.save(config)
        let copied = Paint.ink(.green, "copied ") + Paint.ink(.bold, current.name) + " → " + Paint.ink(.bold, target.name)
        let text = copied + "\n" + Table.profile(profile, header: target.name, preset: presetMark(profile, config))
        return Output(text, ProfileReport(device: DeviceRef(uid: target.uid, name: target.name), source: "device", profile: profile))
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
        let connected = ctx.connectedDevices()
        let currentUID = (try? currentDevice(ctx))?.uid
        var lines: [String] = []
        var rows: [DeviceRow] = []
        for device in connected {
            let isCurrent = device.uid == currentUID
            let marker = isCurrent ? Paint.ink(.green, "*") + " " : "  "
            let name = Paint.ink(.bold, device.name)
            let hasOwn = config.devices[device.uid] != nil
            let profileLabel = hasOwn ? Paint.ink(.green, "own profile") : Paint.ink(.yellow, "default profile")
            let transport = Paint.ink(.dim, "[\(device.transport)]")
            lines.append("\(marker)\(name)  \(transport)  \(profileLabel)")
            rows.append(DeviceRow(uid: device.uid, name: device.name, transport: device.transport, connected: true, profile: hasOwn ? "own" : "default"))
        }
        for (uid, profile) in config.devices.sorted(by: { ($0.value.name ?? $0.key) < ($1.value.name ?? $1.key) })
            where !connected.contains(where: { $0.uid == uid }) {
            lines.append("  \(Paint.ink(.bold, profile.name ?? uid))  \(Paint.ink(.dim, "[disconnected]"))  \(Paint.ink(.green, "own profile"))")
            rows.append(DeviceRow(uid: uid, name: profile.name ?? uid, transport: nil, connected: false, profile: "own"))
        }
        return Output(lines.joined(separator: "\n"), DevicesReport(current: currentUID, devices: rows))
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
        if let device = status.device {
            let hz = Paint.ink(.yellow, "\(Table.whole(status.sampleRate)) Hz")
            let transport = Paint.ink(.dim, "[\(device.transport)]")
            let profile: String
            switch status.profile {
            case .device?: profile = Paint.ink(.green, "device profile")
            case .default?: profile = Paint.ink(.yellow, "default profile")
            case nil: profile = "- profile"
            }
            let latency = status.latencyMs.map { ", latency " + Paint.ink(.yellow, String(format: "%.1f ms", $0)) } ?? ""
            lines.append("\(label("device")) \(Paint.ink(.bold, device.name)) \(transport) \(hz)\(latency), \(profile)")
        }
        let callbacks = Paint.ink(.yellow, "\(status.callbacks)")
        let frames = Paint.ink(.yellow, "\(status.framesProcessed)")
        let pid = Paint.ink(.yellow, "\(status.pid)")
        let version = Paint.ink(.yellow, status.version ?? "-")
        let enabled = Paint.ink(status.enabled ? .green : .yellow, "\(status.enabled)")
        lines.append("\(label("callbacks")) \(callbacks)  \(label("frames")) \(frames)  \(label("enabled")) \(enabled)  \(label("pid")) \(pid)  \(label("version")) \(version)")
        if let error = status.error { lines.append("\(Paint.ink(.red, "error:")) \(error)") }
        lines.append(contentsOf: (status.warnings ?? []).map { "\(Paint.ink(.yellow, "warning:")) \($0)" })
        if status.state == .noPermission { lines.append(Paint.ink(.yellow, permissionHint)) }
        return Output(lines.joined(separator: "\n"), status)
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

    private static func watch(_ args: [String], _ ctx: CLIContext) throws -> Output {
        guard args.allSatisfy({ $0 == "--zones" }) else { throw CLIError.usage("eq watch [--zones]") }
        let terminal = ctx.terminal()
        try Watch.requireTerminal(isTTY: terminal.isTTY)
        let client = MeterClient(socketURL: ctx.meterSocketURL)
        do { try client.connect() } catch { throw CLIError.noMeter }
        LiveTerminal.enterRaw()
        let marker = hintOffMarker(ctx)
        let session = WatchSession(ctx)
        var keys = KeyBuffer()
        let exitCode = Watch.run(source: client, size: { let t = ctx.terminal(); return (t.cols, t.rows) },
                                 zones: !args.isEmpty,
                                 hintDismissed: FileManager.default.fileExists(atPath: marker.path),
                                 emit: LiveTerminal.emit, readKey: { keys.feed(LiveTerminal.drainInput()) },
                                 edit: session.apply, preset: session.presetMark, preference: session.preference,
                                 dismissHint: {
                                     try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
                                     FileManager.default.createFile(atPath: marker.path, contents: nil)
                                 },
                                 send: client.send)
        LiveTerminal.leaveRaw()
        client.close()
        var output = Output(exitCode == 1 ? "\(CLIError.daemonClosedMeter)" : "", ["ok": exitCode == 0])
        output.exitCode = exitCode
        output.streamed = true
        return output
    }

    static func hintOffMarker(_ ctx: CLIContext) -> URL {
        ctx.store.url.deletingLastPathComponent().appendingPathComponent("watch-hint-off")
    }

    static func watchEdit(_ action: WatchAction, _ ctx: CLIContext) throws {
        try WatchSession(ctx).apply(action)
    }

    /// The edits of one `eq watch`, on the same device `eq set` would edit. Only the session's first
    /// save backs up the file, so the whole session is one `eq undo` step; `u` walks back inside it
    /// through the device profiles the session replaced.
    final class WatchSession {
        struct Note: Error, CustomStringConvertible { let description: String }

        private let ctx: CLIContext
        private var history: [(uid: String, profile: Profile?)] = []
        private var lastSaved: Config?

        init(_ ctx: CLIContext) { self.ctx = ctx }

        func preference() -> Preference? {
            guard let config = try? ctx.store.load(), let target = try? currentDevice(ctx) else { return nil }
            return config.profile(forDeviceUID: target.uid).profile.preference
        }

        func presetMark() -> Table.PresetMark? {
            guard let config = try? ctx.store.load(), let target = try? currentDevice(ctx) else { return nil }
            return CLI.presetMark(config.profile(forDeviceUID: target.uid).profile, config)
        }

        func apply(_ action: WatchAction) throws {
            let original = try loadConfig(ctx)
            var config = original
            if case .undo = action {
                guard let last = history.popLast() else { throw Note(description: "nothing left to undo in this session") }
                config.devices[last.uid] = last.profile
                try save(config, over: original)
                return
            }
            let target = try currentDevice(ctx)
            let before = config.devices[target.uid]
            if case .savePreset(let name) = action {
                try CLI.savePreset(name, on: target, in: &config)
            } else {
                guard let profile = try edited(editableProfile(config, target), by: action, &config) else { return }
                config.setProfile(profile, forDeviceUID: target.uid)
            }
            guard config != original else { return }
            try save(config, over: original)
            if config.devices[target.uid] != before { history.append((target.uid, before)) }
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
            case .undo, .savePreset, .startSave, .zones, .help, .dismissHelp, .quit,
                 .focusNext, .focusPrevious, .unfocus, .listen:
                return nil
            }
            return profile == before ? nil : profile
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
                                        filters: profile.filters, imported: profile.imported, preference: profile.preference)
        profile.preset = name
        config.setProfile(profile, forDeviceUID: target.uid)
    }

    private static func preset(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let (explicit, rest) = try splitDeviceOption(args, flag: "--device", ctx)
        var config = try loadConfig(ctx)
        _ = config.seedPresetsIfNeeded()
        let usage = "eq preset [save|use|show|rm <name> | rename <old> <new>] [--device DEVICE]"
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
        case (nil, _):
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
            let found = try existing(rest[1])
            let target = try target()
            var profile = found.profile
            profile.name = target.name
            profile.preset = found.name
            config.setProfile(profile, forDeviceUID: target.uid)
            try ctx.store.save(config)
            let table = Table.profile(profile, header: target.name, preset: (found.name, false))
            return Output(table, ProfileReport(device: DeviceRef(uid: target.uid, name: target.name), source: "device", profile: profile, preset: found.name))
        case ("show", 2):
            let found = try existing(rest[1])
            return Output(Table.profile(found.profile, header: found.name), PresetShowReport(preset: found.name, profile: found.profile))
        case ("rm", 2):
            let found = try existing(rest[1])
            config.presets?[found.name] = nil
            renamePresetReferences(&config, from: found.name, to: nil)
            try ctx.store.save(config)
            return Output(Paint.ink(.green, "removed ") + Paint.ink(.bold, found.name), PresetRemovedReport(removed: found.name))
        case ("rename", 3):
            let found = try existing(rest[1])
            let name = try validName(rest[2])
            if let clash = config.preset(named: name), clash.name != found.name { throw CLIError.presetExists(clash.name) }
            config.presets?[found.name] = nil
            config.presets?[name] = found.profile
            renamePresetReferences(&config, from: found.name, to: name)
            try ctx.store.save(config)
            let text = Paint.ink(.green, "renamed ") + Paint.ink(.bold, found.name) + " → " + Paint.ink(.bold, name)
            return Output(text, PresetRenamedReport(from: found.name, to: name))
        default:
            throw CLIError.usage(usage)
        }
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
    }

    private static func undo(_ args: [String], _ ctx: CLIContext) throws -> Output {
        guard args.isEmpty || args == ["--list"] else { throw CLIError.usage("eq undo [--list]") }
        guard ctx.store.exists() else { throw CLIError.usage("no config at \(ctx.store.url.path) — run `eq init` first") }
        if args == ["--list"] { return try history([], ctx) }
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
        guard ctx.store.exists() else { throw CLIError.usage("no config at \(ctx.store.url.path) — run `eq init` first") }
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

    /// Position 0 is the latest edit, `.1`…`.10` the backup chain; `←` marks where `eq undo`/`eq redo`
    /// currently sit. `eq undo --list` is an alias kept for muscle memory.
    private static func history(_ args: [String], _ ctx: CLIContext) throws -> Output {
        guard args.isEmpty else { throw CLIError.usage("eq history") }
        guard ctx.store.exists() else { throw CLIError.usage("no config at \(ctx.store.url.path) — run `eq init` first") }
        // Without it a hand edit mid-undo and a stash left by an interrupted step are missing from the list.
        let note = try ctx.store.reconcileHistory()
        let position = ctx.store.historyPosition()
        let device = try? currentDevice(ctx)
        var lines: [String] = note.map { ["\(Paint.ink(.yellow, "warning:")) \($0)"] } ?? []
        var rows: [HistoryRow] = []

        func row(_ index: Int, _ path: String, _ date: Date, _ config: Config?) {
            let profile = config.flatMap { config in device.map { config.profile(forDeviceUID: $0.uid).profile } }
            var line = String(format: "%3d  ", index) + Paint.ink(.dim, backupTime(date))
            if let config, let profile {
                line += "  " + Table.compactGains(profile.bands)
                line += "  preamp " + Paint.ink(Paint.gain(profile.preamp), Table.gain(profile.preamp))
                if !profile.filters.isEmpty { line += Paint.ink(.cyan, "  +\(profile.filters.count) filters") }
                if let layer = profile.preference, !layer.isFlat { line += "  pref " + Table.preference(layer) }
                if !config.enabled { line += "  " + Paint.ink(.yellow, "off") }
                if let mark = presetMark(profile, config) { line += "  " + Table.presetLabel(mark) }
            } else if config == nil {
                line += "  " + Paint.ink(.red, "unreadable")
            }
            if index == position { line += Paint.ink(.green, " ←") }
            lines.append(line)
            rows.append(HistoryRow(index: index, path: path, date: date, enabled: config?.enabled, profile: profile,
                                   current: index == position))
        }

        if let latest = ctx.store.latestVersion() {
            row(0, latest.url.path, latest.date, try? ctx.store.load(at: latest.url))
        }
        for backup in ctx.store.backups() {
            row(backup.index, backup.url.path, backup.date, try? ctx.store.load(backup: backup.index))
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
        guard ctx.store.exists() else { throw CLIError.usage("no config at \(ctx.store.url.path) — run `eq init` first") }
        return try ctx.store.load()
    }

    static func currentDevice(_ ctx: CLIContext) throws -> Target {
        if let status = Status.read(from: ctx.statusURL), status.isAlive(), let device = status.device {
            return (device.uid, device.name)
        }
        guard let device = ctx.defaultOutput() else { throw CLIError.noCurrentDevice }
        return device
    }

    static func presetMark(_ profile: Profile, _ config: Config) -> Table.PresetMark? {
        guard let name = profile.preset, let preset = config.preset(named: name) else { return nil }
        return (preset.name, !profile.sameCurve(as: preset.profile))
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
