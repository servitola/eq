import Foundation

/// One Core Audio client process as the HAL lists it.
struct AudioProcess: Equatable {
    var pid: pid_t
    var bundleID: String?
    /// The executable; read only for a process that plays. Routing names the others by bundle ID alone.
    var path: String?
    var playing: Bool
    /// The HAL's object for the process, which is what a tap names.
    var object: UInt32 = 0
}

struct PlayingApp: Equatable {
    var id: String
    var name: String
}

/// An app rule that won: the app plays, so its preset is what you hear.
struct AppMatch: Codable, Equatable {
    var app: String
    var name: String
    var preset: String

    var label: String { "\(name) → \(preset)" }
}

protocol AudioProcessSource: AnyObject {
    func snapshot() -> [AudioProcess]
    /// Calls `changed` on every change to the process list or to what a process plays; false when it cannot listen.
    func start(_ changed: @escaping () -> Void) -> Bool
    func stop()
}

/// Browsers and Electron apps play from a helper process with a bundle of its own, nested inside
/// the app's: `Vivaldi.app/Contents/Frameworks/…/Vivaldi Helper.app`. The outermost `.app` in the
/// executable's path is the app a person knows. A process whose path cannot be read falls back to
/// its own bundle ID with a `.helper…` suffix dropped.
enum AppIdentity {
    typealias BundleInfo = (_ appPath: String) -> PlayingApp?

    static func outermostApp(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<path.index(before: range.upperBound)])
    }

    static func strippingHelper(_ bundleID: String) -> String {
        guard let range = bundleID.range(of: #"\.helper(\.[A-Za-z0-9_-]+)*$"#, options: [.regularExpression, .caseInsensitive]) else { return bundleID }
        return String(bundleID[..<range.lowerBound])
    }

    static func identify(_ process: AudioProcess, bundleInfo: BundleInfo) -> PlayingApp? {
        if let path = process.path, let app = outermostApp(path), let host = bundleInfo(app) { return host }
        guard let own = process.bundleID, !own.isEmpty else { return nil }
        let id = strippingHelper(own)
        return PlayingApp(id: id, name: printable(process.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? id))
    }

    /// Another app's bundle writes these names, and they reach the log and the terminal.
    static func liveBundleInfo(_ appPath: String) -> PlayingApp? {
        guard let bundle = Bundle(path: appPath), let id = bundle.bundleIdentifier else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        return PlayingApp(id: printable(id), name: printable(name))
    }

    /// Without C0, DEL and C1, so no escape sequence gets through.
    static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !($0.value < 0x20 || (0x7F...0x9F).contains($0.value)) }))
    }
}

enum AppResolver {
    /// One match per playing app, in rule order; a rule whose preset is gone matches nothing.
    static func candidates(rules: [AppRule], playing: [PlayingApp], config: Config) -> [AppMatch] {
        var matches: [AppMatch] = []
        for rule in rules {
            guard let preset = config.preset(named: rule.preset) else { continue }
            for app in playing where rule.matches(app.id) && !matches.contains(where: { $0.app == app.id }) {
                matches.append(AppMatch(app: app.id, name: app.name, preset: preset.name))
            }
        }
        return matches
    }

    /// `nowPlaying` breaks a tie only; otherwise, or when it names none of them, the first rule wins.
    static func winner(_ candidates: [AppMatch], nowPlaying: String?) -> AppMatch? {
        guard candidates.count > 1, let nowPlaying else { return candidates.first }
        let id = AppIdentity.strippingHelper(nowPlaying)
        return candidates.first { $0.app.caseInsensitiveCompare(id) == .orderedSame } ?? candidates.first
    }
}

/// Follows which app plays and decides which app rule is heard. Listens only while the feature is
/// on; every change waits a second of quiet, so a gap between two tracks restores nothing.
/// Not thread-safe: configure it, and let `schedule` and `nowPlaying` call back, on one serial queue.
final class AppFollower {
    typealias NowPlaying = (@escaping (String?) -> Void) -> Void

    static let debounce: TimeInterval = 1
    static let retryDelay: TimeInterval = 30

    private let source: AudioProcessSource
    private let identify: (AudioProcess) -> PlayingApp?
    private let nowPlaying: NowPlaying
    private let now: () -> Date
    private let excluding: pid_t
    private let onChange: (_ new: AppMatch?, _ previous: AppMatch?) -> Void
    private lazy var quiet = Debouncer(delay: Self.debounce, schedule: schedule) { [weak self] in self?.evaluate() }
    private lazy var retry = Debouncer(delay: Self.retryDelay, schedule: schedule) { [weak self] in self?.retryListening() }
    private let schedule: Debouncer.Schedule
    private var rules: [AppRule] = []
    private var config: Config?
    // Bumped by every evaluation and by `stop`, so a now-playing answer that arrives late is dropped.
    private var generation = 0

    private(set) var enabled = false
    private(set) var listening = false
    private(set) var overlay: AppMatch?
    /// Set aside by an edit: the app still plays, but the edited curve is what you hear until it stops.
    private(set) var held: AppMatch?
    private(set) var lastMatch: AppMatch?
    private(set) var lastMatchAt: Date?

    init(source: AudioProcessSource, identify: @escaping (AudioProcess) -> PlayingApp?, nowPlaying: @escaping NowPlaying,
         schedule: @escaping Debouncer.Schedule, now: @escaping () -> Date = Date.init, excluding: pid_t = getpid(),
         onChange: @escaping (_ new: AppMatch?, _ previous: AppMatch?) -> Void) {
        self.source = source
        self.identify = identify
        self.nowPlaying = nowPlaying
        self.schedule = schedule
        self.now = now
        self.excluding = excluding
        self.onChange = onChange
    }

    var status: AppsStatus? {
        enabled ? AppsStatus(listening: listening, overlay: overlay, held: held, lastMatch: lastMatch, lastMatchAt: lastMatchAt) : nil
    }

    func configure(_ config: Config) {
        self.config = config
        rules = config.apps ?? []
        guard config.followsApps else {
            stop()
            return
        }
        if !enabled {
            enabled = true
            listen()
            if !listening { Log.write("apps: cannot listen for playing apps — retrying every \(Int(Self.retryDelay)) s") }
        } else if !listening {
            listen()
        }
        // `eq preset rename` renames the rules along with the preset, so the overlay's rule names
        // the new one; a removed preset leaves the rule matching nothing. Either way it is settled
        // now, since until then the overlay would play the device's curve under a stale name.
        if let overlay, config.preset(named: overlay.preset) == nil {
            generation += 1
            settle(AppResolver.candidates(rules: rules, playing: [PlayingApp(id: overlay.app, name: overlay.name)], config: config).first)
        }
        quiet.trigger()
    }

    /// The overlay ends now, and stays off while the same app keeps playing.
    func hold() -> AppMatch? {
        guard let overlay else { return nil }
        held = overlay
        self.overlay = nil
        return overlay
    }

    private func listen() {
        listening = source.start { [weak self] in self?.quiet.trigger() }
        if !listening { retry.trigger() }
    }

    private func retryListening() {
        guard enabled, !listening else { return }
        listen()
        guard listening else { return }
        Log.write("apps: listening for playing apps")
        quiet.trigger()
    }

    private func stop() {
        guard enabled else { return }
        enabled = false
        if listening { source.stop() }
        listening = false
        quiet.cancel()
        retry.cancel()
        generation += 1
        held = nil
        let previous = overlay
        overlay = nil
        if previous != nil { onChange(nil, previous) }
    }

    private func evaluate() {
        guard enabled, let config else { return }
        generation += 1
        let armed = generation
        var playing: [PlayingApp] = []
        for process in source.snapshot() where process.playing && process.pid != excluding {
            if let app = identify(process), !playing.contains(app) { playing.append(app) }
        }
        let candidates = AppResolver.candidates(rules: rules, playing: playing, config: config)
        guard candidates.count > 1 else {
            settle(candidates.first)
            return
        }
        nowPlaying { [weak self] app in
            guard let self, self.generation == armed else { return }
            self.settle(AppResolver.winner(candidates, nowPlaying: app))
        }
    }

    private func settle(_ match: AppMatch?) {
        if let held {
            if match?.app == held.app {
                self.held = match
                return
            }
            self.held = nil
        }
        guard match != overlay else { return }
        let previous = overlay
        overlay = match
        if let match {
            lastMatch = match
            lastMatchAt = now()
        }
        onChange(match, previous)
    }
}

enum AppOverlay {
    /// What plays while `match` is heard: its preset, as `eq preset use` would set it, never saved.
    static func heard(_ base: Profile, _ match: AppMatch?, in config: Config) -> Profile {
        guard let match, let preset = config.preset(named: match.preset) else { return base }
        var profile = preset.profile
        profile.name = base.name
        profile.preset = preset.name
        return profile
    }

    /// A change someone made to the curve `uid` plays. Labels are none: the daemon renames the
    /// device, and `eq preset rename` or `rm` relabel the curve without changing what it sounds like.
    static func edited(_ old: Config, _ new: Config, uid: String) -> Bool {
        func curve(_ config: Config) -> Profile {
            var profile = config.profile(forDeviceUID: uid).profile
            profile.name = nil
            profile.preset = nil
            profile.imported = nil
            return profile
        }
        return curve(old) != curve(new)
    }
}

struct AppsStatus: Codable, Equatable {
    var listening: Bool
    var overlay: AppMatch?
    var held: AppMatch?
    var lastMatch: AppMatch?
    var lastMatchAt: Date?
}
