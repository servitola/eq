import Foundation

struct AppRuleRow: Encodable {
    var app: String
    var name: String?
    var preset: String
    /// The preset is gone, so the rule matches nothing.
    var missing: Bool
}

struct AppsReport: Encodable {
    var on: Bool
    var rules: [AppRuleRow]
    var heard: AppMatch?
    var held: AppMatch?
    enum CodingKeys: String, CodingKey { case on, rules, heard, held }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(on, forKey: .on)
        try container.encode(rules, forKey: .rules)
        try container.encode(heard, forKey: .heard)
        try container.encode(held, forKey: .held)
    }
}

/// Finds installed apps by the name on their bundle, or by bundle ID, without AppKit.
enum InstalledApps {
    static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Applications")]
    }

    static func find(_ query: String, in folders: [URL] = folders, bundleInfo: AppIdentity.BundleInfo = AppIdentity.liveBundleInfo) -> PlayingApp? {
        let files = FileManager.default
        let bundles = folders.flatMap { folder in
            ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".app") }.map { folder.appendingPathComponent($0) }
        }
        if let named = bundles.first(where: { $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(query) == .orderedSame }) {
            return bundleInfo(named.path)
        }
        guard CLI.looksLikeBundleID(query) else { return nil }
        return bundles.compactMap { bundleInfo($0.path) }.first { $0.id.caseInsensitiveCompare(query) == .orderedSame }
    }
}

extension CLI {
    static func looksLikeBundleID(_ text: String) -> Bool {
        text.contains(".") && !text.contains(" ") && !text.hasPrefix(".") && !text.hasSuffix(".")
    }

    static func app(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let usage = "eq app [list] | eq app set <app> <preset> | eq app rm <app> | eq app on|off"
        var config = try loadConfig(ctx)
        switch (args.first, args.count) {
        case (nil, _), ("list", 1):
            return appList(config, ctx)
        case ("set", 3):
            let app = try resolveApp(args[1], ctx)
            let rule = try setAppRule(app, preset: args[2], in: &config)
            try ctx.store.save(config)
            var lines = [Paint.ink(.green, "app ") + Paint.ink(.bold, app.name) + Paint.ink(.dim, " (\(app.id))") + " → " + Paint.ink(.bold, rule.preset)]
            if !config.followsApps { lines.append(Paint.ink(.dim, "apps are off — eq app on to follow them")) }
            return Output(lines.joined(separator: "\n"), appsReport(config, ctx))
        case ("rm", 2):
            let removed = try removeAppRule(args[1], in: &config, ctx)
            try ctx.store.save(config)
            return Output(Paint.ink(.green, "removed ") + Paint.ink(.bold, removed.app), appsReport(config, ctx))
        case ("on", 1), ("off", 1):
            config.setFollowsApps(args[0] == "on")
            try ctx.store.save(config)
            let text = config.followsApps
                ? "apps " + Paint.ink(.green, "on") + Paint.ink(.dim, " (experimental)") + ((config.apps ?? []).isEmpty ? Paint.ink(.dim, " — no rules yet: eq app set <app> <preset>") : "")
                : "apps " + Paint.ink(.yellow, "off")
            return Output(text, appsReport(config, ctx))
        default:
            throw CLIError.usage(usage)
        }
    }

    /// The app plays `preset` from now on, replacing a rule it had.
    @discardableResult
    static func setAppRule(_ app: PlayingApp, preset name: String, in config: inout Config) throws -> AppRule {
        guard let preset = config.preset(named: name) else { throw CLIError.noSuchPreset(name) }
        var rules = config.apps ?? []
        let rule = AppRule(app: app.id, preset: preset.name)
        if let at = rules.firstIndex(where: { $0.matches(app.id) }) { rules[at] = rule } else { rules.append(rule) }
        config.apps = rules
        return rule
    }

    /// The rule of the app `query` names by bundle ID, or by the name of an app running or installed.
    static func removeAppRule(_ query: String, in config: inout Config, _ ctx: CLIContext) throws -> AppRule {
        var rules = config.apps ?? []
        let id = rules.first(where: { $0.matches(query) })?.app ?? (try? resolveApp(query, ctx))?.id
        guard let id, let at = rules.firstIndex(where: { $0.matches(id) }) else { throw CLIError.noSuchAppRule(query) }
        let removed = rules.remove(at: at)
        config.apps = rules.isEmpty ? nil : rules
        return removed
    }

    /// A running app by bundle ID or name first, then an installed one; a bundle ID of an app not
    /// installed yet is taken as typed.
    static func resolveApp(_ query: String, _ ctx: CLIContext) throws -> PlayingApp {
        let running = ctx.audioApps()
        if let hit = running.first(where: { $0.id.caseInsensitiveCompare(query) == .orderedSame })
            ?? running.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            return hit
        }
        if let installed = ctx.findApp(query) { return installed }
        guard looksLikeBundleID(query) else { throw CLIError.noSuchApp(query) }
        return PlayingApp(id: query, name: query)
    }

    private static func liveApps(_ ctx: CLIContext) -> AppsStatus? {
        Status.read(from: ctx.statusURL).flatMap { $0.isAlive() ? $0.apps : nil }
    }

    private static func appsReport(_ config: Config, _ ctx: CLIContext) -> AppsReport {
        let running = ctx.audioApps()
        let rows = (config.apps ?? []).map { rule in
            AppRuleRow(app: rule.app, name: running.first { rule.matches($0.id) }?.name, preset: rule.preset,
                       missing: config.preset(named: rule.preset) == nil)
        }
        let live = config.followsApps ? liveApps(ctx) : nil
        return AppsReport(on: config.followsApps, rules: rows, heard: live?.overlay, held: live?.held)
    }

    private static func appList(_ config: Config, _ ctx: CLIContext) -> Output {
        let report = appsReport(config, ctx)
        var lines = [report.on ? "apps " + Paint.ink(.green, "on") + Paint.ink(.dim, " (experimental)")
                               : "apps " + Paint.ink(.yellow, "off") + Paint.ink(.dim, " — eq app on to follow them")]
        if report.rules.isEmpty { lines.append(Paint.ink(.dim, "no rules — eq app set <app> <preset>")) }
        for row in report.rules {
            let heard = report.heard.map { row.app.caseInsensitiveCompare($0.app) == .orderedSame } ?? false
            let marker = heard ? Paint.ink(.green, "*") + " " : "  "
            let name = row.name.map { Paint.ink(.bold, $0) + " " + Paint.ink(.dim, "(\(row.app))") } ?? Paint.ink(.bold, row.app)
            let preset = row.missing ? Paint.ink(.yellow, "\(row.preset) (no such preset)") : row.preset
            lines.append("\(marker)\(name) → \(preset)")
        }
        if let line = appLine(report.heard, held: report.held) { lines.append(line) }
        return Output(lines.joined(separator: "\n"), report)
    }

    /// `app: Spotify → favourite`, for `eq`, `eq status` and `eq app list`.
    static func appLine(_ heard: AppMatch?, held: AppMatch?) -> String? {
        let label = Paint.ink(.dim, "app:")
        if let heard {
            return "\(label) \(Paint.ink(.bold, heard.name)) → \(Paint.ink(.cyan, heard.preset))"
                + Paint.ink(.dim, " — heard instead of the device's curve until \(heard.name) stops")
        }
        if let held {
            return "\(label) \(Paint.ink(.bold, held.name)) plays" + Paint.ink(.dim, " — your edit is heard until it stops, then \(held.preset) again next time")
        }
        return nil
    }

    static func appLine(_ ctx: CLIContext) -> (text: String?, apps: AppsStatus?) {
        let live = liveApps(ctx)
        return (appLine(live?.overlay, held: live?.held), live)
    }
}
