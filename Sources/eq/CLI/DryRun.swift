import Foundation

/// `--dry-run` runs the command itself against a throwaway copy of the config and its history, so
/// what it shows is exactly what the real run would write, validation included.
enum DryRun {
    struct Side: Encodable {
        var enabled: Bool
        var devices: [ProfileReport]
        var presets: [String: Profile]?
    }

    struct Report: Encodable {
        var before: AnyEncodable?
        var after: AnyEncodable?
        enum CodingKeys: String, CodingKey { case before, after }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(before, forKey: .before)
            try container.encode(after, forKey: .after)
        }
    }

    static func run(_ args: [String], _ ctx: CLIContext, dispatch: ([String], CLIContext) throws -> Output) throws -> Output {
        if args.starts(with: ["device", "use"]) { return try use(Array(args.dropFirst(2)), ctx) }
        let files = FileManager.default
        let sandbox = files.temporaryDirectory.appendingPathComponent("eq-dry-run-\(UUID().uuidString)")
        try files.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: sandbox) }
        var copy = ctx
        copy.store = ConfigStore(url: sandbox.appendingPathComponent(ctx.store.url.lastPathComponent), displayPath: ctx.store.displayPath)
        try mirror(ctx.store, into: sandbox)
        if args.first == "import" { copy.cacheDirectory = try mirror(cache: ctx, into: sandbox) }
        do { _ = try dispatch(args, copy) } catch CLIError.network(let message) {
            let real = ctx.cacheDirectory.deletingLastPathComponent().path
            throw CLIError.network(message.replacingOccurrences(of: copy.cacheDirectory.deletingLastPathComponent().path, with: real))
        }
        let before = try CLI.loadConfig(ctx)
        let after = try CLI.loadConfig(copy)
        if before == after, !ctx.store.exists(), copy.store.exists() {
            return Output(Paint.ink(.yellow, "dry run") + ": would write \(ctx.store.displayPath) with the defaults already in use",
                          Report(before: side(before, [], ctx), after: side(after, [], ctx)))
        }
        return compare(before, after, ctx)
    }

    /// `eq.json` and its siblings (`.1`…`.10`, `.pos`, `.redo`), so undo and redo step the same history.
    private static func mirror(_ store: ConfigStore, into sandbox: URL) throws {
        let files = FileManager.default
        let folder = store.url.deletingLastPathComponent()
        let name = store.url.lastPathComponent
        guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { return }
        for sibling in names where sibling == name || sibling.hasPrefix(name + ".") {
            let source = folder.appendingPathComponent(sibling).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            try files.copyItem(at: source, to: sandbox.appendingPathComponent(sibling))
        }
    }

    /// A fresh index is read from the copy and a stale or `--refresh`ed one is fetched into it,
    /// so the real cache is never written. OPRA lives next to the AutoEq directory, so it comes too.
    private static func mirror(cache ctx: CLIContext, into sandbox: URL) throws -> URL {
        let files = FileManager.default
        let root = sandbox.appendingPathComponent("cache")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        for source in [ctx.cacheDirectory, HeadphoneLookup.opraDirectory(ctx)] where files.fileExists(atPath: source.path) {
            try files.copyItem(at: source, to: root.appendingPathComponent(source.lastPathComponent))
        }
        return root.appendingPathComponent(ctx.cacheDirectory.lastPathComponent)
    }

    private static var heading: String { Paint.ink(.yellow, "dry run") + ": nothing written" }

    private static func compare(_ before: Config, _ after: Config, _ ctx: CLIContext) -> Output {
        guard before != after else {
            return Output(Paint.ink(.yellow, "dry run") + ": nothing would change", Report(before: side(before, [], ctx), after: side(after, [], ctx)))
        }
        let current = try? CLI.currentDevice(ctx)
        var uids = Set(before.devices.keys).union(after.devices.keys).filter { before.devices[$0] != after.devices[$0] }
        if before.default != after.default, let current { uids.insert(current.uid) }
        let ordered = uids.sorted { name(of: $0, before, after, ctx).lowercased() < name(of: $1, before, after, ctx).lowercased() }
        let targets = ordered.map { (uid: $0, name: name(of: $0, before, after, ctx)) }

        var lines = [heading]
        if before.enabled != after.enabled {
            lines.append("eq " + toggle(before.enabled) + " → " + toggle(after.enabled))
        }
        for name in changedPresets(before, after) {
            let verb = before.preset(named: name) == nil ? "added" : (after.preset(named: name) == nil ? "removed" : "changed")
            lines.append("preset " + Paint.ink(.bold, name) + ": " + Paint.ink(verb == "removed" ? .magenta : .green, verb))
        }
        for target in targets {
            lines.append(Paint.ink(.dim, "before"))
            lines.append(table(before, target))
            lines.append(Paint.ink(.bold, "after"))
            lines.append(table(after, target))
        }
        return Output(lines.joined(separator: "\n"), Report(before: side(before, targets, ctx, presets: changedPresets(before, after)),
                                                            after: side(after, targets, ctx, presets: changedPresets(before, after))))
    }

    private static func use(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let target = try CLI.useTarget(args, ctx)
        let config = try CLI.loadConfig(ctx)
        let current = try CLI.currentDevice(ctx)
        guard current.uid != target.uid else {
            let lines = [Paint.ink(.yellow, "dry run") + ": " + Paint.ink(.bold, target.name) + " is already the output", table(config, target)]
            return Output(lines.joined(separator: "\n"), Report(before: AnyEncodable(report(config, current)), after: AnyEncodable(report(config, target))))
        }
        let lines = [
            Paint.ink(.yellow, "dry run") + ": output not switched",
            "output " + Paint.ink(.bold, current.name) + " → " + Paint.ink(.bold, target.name),
            Paint.ink(.dim, "before"), table(config, current),
            Paint.ink(.bold, "after"), table(config, target),
        ]
        return Output(lines.joined(separator: "\n"), Report(before: AnyEncodable(report(config, current)), after: AnyEncodable(report(config, target))))
    }

    private static func toggle(_ enabled: Bool) -> String {
        enabled ? Paint.ink(.green, "on") : Paint.ink(.yellow, "off (bypass)")
    }

    private static func changedPresets(_ before: Config, _ after: Config) -> [String] {
        let names = Set((before.presets ?? [:]).keys).union((after.presets ?? [:]).keys)
        return names.filter { before.presets?[$0] != after.presets?[$0] }.sorted { $0.lowercased() < $1.lowercased() }
    }

    private static func name(of uid: String, _ before: Config, _ after: Config, _ ctx: CLIContext) -> String {
        after.devices[uid]?.name ?? before.devices[uid]?.name ?? ctx.connectedDevices().first { $0.uid == uid }?.name ?? uid
    }

    private static func table(_ config: Config, _ target: CLI.Target) -> String {
        let resolved = config.profile(forDeviceUID: target.uid)
        let label = resolved.source == .device ? "own profile" : "default profile"
        return Table.profile(resolved.profile, header: "\(target.name) (\(label))", preset: CLI.presetMark(resolved.profile, config))
    }

    private static func report(_ config: Config, _ target: CLI.Target) -> ProfileReport {
        let resolved = config.profile(forDeviceUID: target.uid)
        return ProfileReport(device: DeviceRef(uid: target.uid, name: target.name), source: resolved.source == .device ? "device" : "default",
                             profile: resolved.profile, preset: CLI.presetMark(resolved.profile, config)?.name)
    }

    private static func side(_ config: Config, _ targets: [CLI.Target], _ ctx: CLIContext, presets names: [String] = []) -> AnyEncodable? {
        let presets = names.isEmpty ? nil : names.reduce(into: [String: Profile]()) { $0[$1] = config.presets?[$1] }
        return AnyEncodable(Side(enabled: config.enabled, devices: targets.map { report(config, $0) }, presets: presets))
    }
}
