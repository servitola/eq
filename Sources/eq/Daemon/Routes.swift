import Foundation

extension Config {
    /// The rules that play: none while `experimental.routes` is off, though the config keeps them.
    var activeRoutes: [RouteRule] { followsRoutes ? routes ?? [] : [] }
}

enum RouteReason: String, Codable {
    case first, fallback, identity, exhausted
    /// Its engine failed too often; it plays on the main path for a while.
    case suspended
}

/// One app with a rule and audio open, and where it plays.
struct RoutedApp: Equatable {
    var app: String
    var name: String
    /// The first available output in its rule; nil when none is, and the app follows the default.
    var target: String?
    var reason: RouteReason
    var processes: [UInt32]
    var playing: Bool

    /// On a route engine; otherwise the app plays on the main path.
    var isRouted: Bool { reason == .first || reason == .fallback }
}

/// One engine per target in use, however many apps play on it.
struct RouteEnginePlan: Equatable {
    var target: String
    var apps: [String]
    var processes: [UInt32]
    var playing: Bool
}

struct RoutePlan: Equatable {
    var apps: [RoutedApp] = []
    var engines: [String: RouteEnginePlan] = [:]
    /// Every process on a route engine: the main tap must not carry them too.
    var mainExclusions: Set<UInt32> = []

    /// Lowercased, as `AppFollower.routed` takes them.
    var routedApps: Set<String> { Set(apps.filter(\.isRouted).map { $0.app.lowercased() }) }
}

enum RouteResolver {
    /// The device the main path plays on: the default output in tap mode, the driver's target in driver mode.
    static func mainTarget(path: AudioPaths.Path?, defaultOutput: String?, driverTarget: String?) -> String? {
        path == .driver ? driverTarget : defaultOutput
    }

    /// `available` holds only real devices that are ready (`RouteDevices`), so an output that is eq's
    /// own device, an aggregate or AirPlay is never a target.
    /// `suspended` holds lowercased app IDs whose route is suspended.
    static func resolve(rules: [RouteRule], processes: [AudioProcess], identify: (AudioProcess) -> PlayingApp?,
                        available: Set<String>, mainTarget: String?, excluding: pid_t, suspended: Set<String> = []) -> RoutePlan {
        var found: [Int: RoutedApp] = [:]
        for process in processes where process.pid != excluding {
            guard let app = identify(process), let index = rules.firstIndex(where: { $0.matches(app.id) }) else { continue }
            var entry = found[index] ?? RoutedApp(app: app.id, name: app.name, target: nil, reason: .exhausted, processes: [], playing: false)
            entry.processes.append(process.object)
            entry.playing = entry.playing || process.playing
            found[index] = entry
        }
        var plan = RoutePlan()
        for index in found.keys.sorted() {
            var entry = found[index]!
            let outputs = rules[index].outputs
            entry.processes.sort()
            entry.target = outputs.first(where: available.contains)
            switch entry.target {
            case _ where suspended.contains(entry.app.lowercased()):
                entry.target = nil
                entry.reason = .suspended
            case nil: entry.reason = .exhausted
            case mainTarget: entry.reason = .identity
            case outputs.first: entry.reason = .first
            default: entry.reason = .fallback
            }
            plan.apps.append(entry)
            guard entry.isRouted, let target = entry.target else { continue }
            var engine = plan.engines[target] ?? RouteEnginePlan(target: target, apps: [], processes: [], playing: false)
            engine.apps.append(entry.app)
            engine.processes = (engine.processes + entry.processes).sorted()
            engine.playing = engine.playing || entry.playing
            plan.engines[target] = engine
            plan.mainExclusions.formUnion(entry.processes)
        }
        return plan
    }
}

enum RouteAction: Equatable {
    /// The target's IO up, before any tap feeds it.
    case startEngine(String)
    /// The processes the target's route tap captures, and so mutes everywhere else.
    case tap(String, [UInt32])
    /// The processes the main tap leaves out.
    case exclude([UInt32])
    /// The route tap and the engine gone.
    case stopEngine(String)
}

enum RoutePlanner {
    /// A process is captured by its new route tap before the main tap lets it go, and the main tap
    /// takes it back before its old route tap lets it go. A process moving between two engines is
    /// in both taps for a moment. A few milliseconds heard twice are the lesser failure; a gap, or
    /// a moment on the wrong device, is the worse.
    static func actions(from old: RoutePlan, to new: RoutePlan) -> [RouteAction] {
        var grow: [RouteAction] = []
        var shrink: [RouteAction] = []
        for target in new.engines.keys.sorted() {
            let wanted = new.engines[target]!.processes
            guard let had = old.engines[target]?.processes else {
                grow += [.startEngine(target), .tap(target, wanted)]
                continue
            }
            let both = Set(had).union(wanted)
            if both.count > had.count { grow.append(.tap(target, both.sorted())) }
            if both.count > wanted.count { shrink.append(.tap(target, wanted)) }
        }
        for target in old.engines.keys.sorted() where new.engines[target] == nil {
            shrink.append(.stopEngine(target))
        }
        let exclude = old.mainExclusions == new.mainExclusions ? [] : [RouteAction.exclude(new.mainExclusions.sorted())]
        return grow + exclude + shrink
    }
}

/// A device in the HAL's list, as routing judges it.
struct RouteDeviceState: Equatable {
    var uid: String
    var alive: Bool
    var rate: Double
    /// Not eq's own device, not an aggregate, not AirPlay: `AudioOutputDevice.isFollowable`.
    var real: Bool

    /// A Bluetooth device is listed at 0 Hz first and gets its rate a moment later.
    var usable: Bool { alive && rate > 0 && real }
}

extension RouteDeviceState {
    init(_ device: AudioOutputDevice, alive: Bool, rate: Double) {
        self.init(uid: device.uid, alive: alive, rate: rate, real: device.isFollowable)
    }
}

/// Which devices a route may play on. One that appears must stay usable for the settle delay before
/// a route moves to it; one that goes is gone at once. One that appears more than `flapLimit` times
/// in `flapWindow` is held off for `hold`, so its apps stay where they are, as driver mode stops
/// taking the default output back when something keeps moving it.
struct RouteDevices {
    static let settle = DaemonPolicy.settleDelay
    static let flapLimit = DefaultFollower.burstLimit
    static let flapWindow = DefaultFollower.burstWindow
    static let hold = DefaultFollower.cooldown

    private var usableSince: [String: Date] = [:]
    private var appearances: [String: [Date]] = [:]
    private var heldUntil: [String: Date] = [:]

    /// The devices this observation put on hold.
    @discardableResult
    mutating func observe(_ devices: [RouteDeviceState], at now: Date) -> Set<String> {
        let usable = Set(devices.filter(\.usable).map(\.uid))
        for uid in usableSince.keys where !usable.contains(uid) { usableSince[uid] = nil }
        var held = Set<String>()
        for uid in usable.sorted() where usableSince[uid] == nil {
            usableSince[uid] = now
            if let until = heldUntil[uid], now < until { continue }
            var seen = (appearances[uid] ?? []).filter { now.timeIntervalSince($0) < Self.flapWindow }
            seen.append(now)
            if seen.count > Self.flapLimit {
                heldUntil[uid] = now.addingTimeInterval(Self.hold)
                held.insert(uid)
                seen = []
            }
            appearances[uid] = seen
        }
        return held
    }

    func available(at now: Date) -> Set<String> {
        Set(usableSince.filter { uid, since in
            now >= since.addingTimeInterval(Self.settle) && !isHeld(uid, at: now)
        }.keys)
    }

    func isHeld(_ uid: String, at now: Date) -> Bool {
        heldUntil[uid].map { now < $0 } ?? false
    }

    /// When `available` changes with no new observation: a device settles, or a hold ends.
    func nextChange(after now: Date) -> Date? {
        usableSince.compactMap { uid, since in
            [since.addingTimeInterval(Self.settle), heldUntil[uid]].compactMap { $0 }.filter { $0 > now }.min()
        }.min()
    }
}

/// What the daemon keeps between events: the devices' history and the plan in force.
struct RouteState {
    private(set) var devices = RouteDevices()
    private(set) var plan = RoutePlan()

    @discardableResult
    mutating func observe(_ states: [RouteDeviceState], at now: Date) -> Set<String> {
        devices.observe(states, at: now)
    }

    /// The new plan, and the steps from the old one in the order they must run.
    mutating func update(rules: [RouteRule], processes: [AudioProcess], identify: (AudioProcess) -> PlayingApp?,
                         mainTarget: String?, excluding: pid_t, suspended: Set<String> = [], now: Date) -> [RouteAction] {
        let next = RouteResolver.resolve(rules: rules, processes: processes, identify: identify,
                                         available: devices.available(at: now), mainTarget: mainTarget, excluding: excluding,
                                         suspended: suspended)
        defer { plan = next }
        return RoutePlanner.actions(from: plan, to: next)
    }

    /// Every engine is gone (sleep, a mode change): the next update starts each one again.
    mutating func forgetPlan() {
        plan = RoutePlan()
    }
}

enum RouteCurve {
    /// The app rules that match apps playing on `target`'s engine, and on it alone.
    static func candidates(for target: String, in plan: RoutePlan, config: Config) -> [AppMatch] {
        guard config.followsApps else { return [] }
        let playing = plan.apps.filter { $0.isRouted && $0.target == target && $0.playing }.map { PlayingApp(id: $0.app, name: $0.name) }
        return AppResolver.candidates(rules: config.apps ?? [], playing: playing, config: config)
    }

    /// The target's own curve, with the preset of the app rule that wins among its engine's apps on top.
    static func heard(on target: String, in plan: RoutePlan, config: Config, nowPlaying: String?) -> (profile: Profile, match: AppMatch?) {
        let match = AppResolver.winner(candidates(for: target, in: plan, config: config), nowPlaying: nowPlaying)
        return (AppOverlay.heard(config.profile(forDeviceUID: target).profile, match, in: config), match)
    }
}
