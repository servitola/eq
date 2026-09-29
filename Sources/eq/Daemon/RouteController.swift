import Foundation
import CoreAudio

enum RoutePolicy {
    /// Why no route plays in driver mode. Its design (the spec's hybrid) waits for the user's call
    /// on the recording indicator, and M4.
    static let driverNote = "routes are off in driver mode for now: every app plays through the EQ device"

    /// The rules routing plays by on `path`, and why none while the config holds some.
    static func rules(_ config: Config, path: AudioPaths.Path?, mainPathOff: Bool) -> (rules: [RouteRule], note: String?) {
        let rules = config.activeRoutes
        guard !rules.isEmpty else { return ([], nil) }
        if mainPathOff { return (rules, nil) }
        switch path {
        case .tap?: return (rules, nil)
        case .driver?: return ([], driverNote)
        case nil: return ([], nil)
        }
    }

    /// `EQ_MAIN_PATH=off`: no main path at all, no mode tidying, only route engines. For measuring a
    /// route beside a running daemon without touching the default output.
    static func mainPathOff(_ environment: [String: String]) -> Bool {
        environment["EQ_MAIN_PATH"] == "off"
    }
}

/// What the route watchdog reads from an engine; its counters restart from zero with the engine.
struct RouteHealth: Equatable {
    var failure: String?
    var callbacks: UInt64
    var tapCallbacks: UInt64
    var signalCallbacks: UInt64
    /// Underruns, overruns and dropouts together.
    var slips: UInt64
}

/// The engines' side of routing, so the daemon's policy runs against a fake in tests.
protocol RouteSink: AnyObject {
    /// The target's engine exists; the reason when it cannot.
    func startEngine(_ target: String) -> String?
    /// Builds the target's tap on its first call, and changes its processes live after that.
    func tap(_ target: String, _ processes: [UInt32]) -> String?
    /// The processes the main tap leaves out; false when the live tap refused them.
    func exclude(_ processes: [UInt32]) -> Bool
    func stopEngine(_ target: String)
    func health(_ target: String) -> RouteHealth?
}

/// Runs the planner's actions on the engines, in order, and watches the engines it started: a
/// stalled or failing one is built again, and one built three times in a minute is suspended, its
/// apps back on the main path for `suspension`. Main queue only.
final class RouteController {
    static let rebuildLimit = 3
    static let rebuildWindow: TimeInterval = 60
    static let suspension: TimeInterval = 300
    /// Status ticks of zeros from a tap whose apps are playing before the engine is built again, once:
    /// forum thread 825780's tap that delivers only zeros is cured only by a new tap and aggregate.
    static let silentTicks = 2

    struct Suspension: Equatable {
        var until: Date
        var reason: String
    }

    private struct Watch {
        var callbacks: UInt64 = 0
        var stalledTicks = 0
        var tapCallbacks: UInt64 = 0
        var stalledTapTicks = 0
        var slips: UInt64 = 0
        var risingTicks = 0
        var signal: UInt64 = 0
        var silentTicks = 0
    }

    private let sink: RouteSink
    private var plan = RoutePlan()
    /// Targets whose tap is built and plays.
    private(set) var live: Set<String> = []
    /// Targets whose last start failed, and why; retried on the next tick.
    private(set) var failures: [String: String] = [:]
    private var rebuilds: [String: [Date]] = [:]
    private var watches: [String: Watch] = [:]
    /// Rebuilt once for zeros; not again until sound comes through, or a browser that keeps its
    /// stream open through silence would get its route suspended.
    private var rebuiltForSilence: Set<String> = []
    private var excluded: [UInt32] = []
    /// Keyed by lowercased app ID.
    private(set) var suspensions: [String: Suspension] = [:]
    /// The main tap refused a live exclusion; the daemon rebuilds it, and the rebuild applies it.
    var onExclusionRefused: (() -> Void)?

    init(sink: RouteSink) {
        self.sink = sink
    }

    func suspended(at now: Date) -> Set<String> {
        Set(suspensions.filter { now < $0.value.until }.keys)
    }

    /// Returns true when a route was suspended: the caller resolves the plan again without it.
    @discardableResult
    func apply(_ actions: [RouteAction], plan: RoutePlan, now: Date) -> Bool {
        self.plan = plan
        var suspended = false
        for action in actions {
            switch action {
            case .startEngine(let target):
                failures[target] = nil
                if let why = sink.startEngine(target) { suspended = fail(target, why, now: now) || suspended }
                watches[target] = Watch()
            case .tap(let target, let processes):
                guard failures[target] == nil else { continue }
                if let why = sink.tap(target, processes) {
                    suspended = fail(target, why, now: now) || suspended
                } else {
                    live.insert(target)
                }
            case .exclude:
                syncExclusions()
            case .stopEngine(let target):
                stop(target)
            }
        }
        syncExclusions()
        return suspended
    }

    /// The watchdog, on the daemon's status tick. Returns true when the set of suspended apps changed.
    @discardableResult
    func tick(now: Date) -> Bool {
        var changed = false
        for (app, suspension) in suspensions where now >= suspension.until {
            suspensions[app] = nil
            Log.write("route: \(app) is no longer suspended")
            changed = true
        }
        for target in plan.engines.keys.sorted() {
            if let why = failures[target] {
                changed = rebuild(target, because: "retrying after: \(why)", now: now) || changed
                continue
            }
            guard live.contains(target), let health = sink.health(target) else { continue }
            if let why = check(target, health) { changed = rebuild(target, because: why, now: now) || changed }
        }
        syncExclusions()
        return changed
    }

    /// The target's engine torn down and built again for the plan's processes, unless it has been
    /// three times in the last minute: then its apps are suspended and it stays down.
    @discardableResult
    func rebuild(_ target: String, because why: String, now: Date) -> Bool {
        guard let engine = plan.engines[target] else { return false }
        let recent = (rebuilds[target] ?? []).filter { now.timeIntervalSince($0) < Self.rebuildWindow }
        guard recent.count < Self.rebuildLimit else {
            suspend(target, "rebuilt \(recent.count) times in a minute, last because \(why)", now: now)
            return true
        }
        rebuilds[target] = recent + [now]
        Log.write("route \(target): \(why) — rebuilding")
        live.remove(target)
        syncExclusions()
        sink.stopEngine(target)
        failures[target] = nil
        watches[target] = Watch()
        if let problem = sink.startEngine(target) ?? sink.tap(target, engine.processes) {
            return fail(target, problem, now: now, counted: true)
        }
        live.insert(target)
        syncExclusions()
        return false
    }

    /// Every engine down, every app back on the main path: sleep, exit, routing turned off.
    func stopAll() {
        live = []
        syncExclusions()
        for target in plan.engines.keys.sorted() { sink.stopEngine(target) }
        plan = RoutePlan()
        failures = [:]
        watches = [:]
        rebuiltForSilence = []
    }

    private func stop(_ target: String) {
        live.remove(target)
        failures[target] = nil
        watches[target] = nil
        rebuiltForSilence.remove(target)
        sink.stopEngine(target)
    }

    private func check(_ target: String, _ health: RouteHealth) -> String? {
        if let failure = health.failure { return failure }
        var watch = watches[target] ?? Watch()
        defer { watches[target] = watch }
        let output = DaemonPolicy.stalled(previous: watch.callbacks, current: health.callbacks, unchangedTicks: watch.stalledTicks)
        let tap = DaemonPolicy.stalled(previous: watch.tapCallbacks, current: health.tapCallbacks, unchangedTicks: watch.stalledTapTicks)
        let ring = DaemonPolicy.ringFailing(previous: watch.slips, current: health.slips, risingTicks: watch.risingTicks)
        watch.stalledTicks = output.unchangedTicks
        watch.stalledTapTicks = tap.unchangedTicks
        watch.risingTicks = ring.risingTicks
        watch.callbacks = health.callbacks
        watch.tapCallbacks = health.tapCallbacks
        watch.slips = health.slips
        if output.stalled { return "output IO stalled" }
        if tap.stalled { return "tap IO stalled" }
        if ring.failing { return "ring slipping" }
        if health.signalCallbacks != watch.signal || !(plan.engines[target]?.playing ?? false) {
            watch.signal = health.signalCallbacks
            watch.silentTicks = 0
            if health.signalCallbacks > 0 { rebuiltForSilence.remove(target) }
            return nil
        }
        watch.silentTicks += 1
        guard watch.silentTicks >= Self.silentTicks, !rebuiltForSilence.contains(target) else { return nil }
        rebuiltForSilence.insert(target)
        return "only zeros from the tap while its apps play"
    }

    /// Every process of a target whose tap is up leaves the main tap; the rest stay in it, so an app
    /// whose route failed plays with the main curve rather than without any.
    private func syncExclusions() {
        let wanted = plan.engines.values.filter { live.contains($0.target) }.flatMap(\.processes).sorted()
        guard wanted != excluded else { return }
        excluded = wanted
        if !sink.exclude(wanted) { onExclusionRefused?() }
    }

    /// `counted`: the attempt that failed is already in `rebuilds`.
    private func fail(_ target: String, _ why: String, now: Date, counted: Bool = false) -> Bool {
        Log.write("route \(target): \(why)")
        live.remove(target)
        failures[target] = why
        syncExclusions()
        sink.stopEngine(target)
        let recent = (rebuilds[target] ?? []).filter { now.timeIntervalSince($0) < Self.rebuildWindow } + (counted ? [] : [now])
        rebuilds[target] = recent
        guard recent.count >= Self.rebuildLimit else { return false }
        suspend(target, "failed \(recent.count) times in a minute: \(why)", now: now)
        return true
    }

    private func suspend(_ target: String, _ reason: String, now: Date) {
        Log.write("route \(target): suspended for \(Int(Self.suspension)) s — \(reason)")
        for app in plan.apps where app.target == target && app.isRouted {
            suspensions[app.app.lowercased()] = Suspension(until: now.addingTimeInterval(Self.suspension), reason: reason)
        }
        live.remove(target)
        failures[target] = nil
        rebuilds[target] = nil
        syncExclusions()
        sink.stopEngine(target)
    }
}

/// The route engines Core Audio runs, and the main tap's exclusions.
final class LiveRouteSink: RouteSink {
    private let main: ProcessTapEngine
    private(set) var engines: [String: RouteEngine] = [:]
    private var playing: [String: (profile: Profile, enabled: Bool)] = [:]
    var requestedIOBufferFrames = 128
    /// The curve a target's engine plays, and whether EQ is on.
    var curve: (String) -> (profile: Profile, enabled: Bool) = { _ in (.flat, true) }
    var onInvalidated: ((String) -> Void)?

    init(main: ProcessTapEngine) {
        self.main = main
    }

    func startEngine(_ target: String) -> String? {
        guard AudioDeviceManager.deviceID(uid: target) != nil else { return "route target \(target) is not there" }
        let engine = RouteEngine(targetUID: target)
        engine.requestedIOBufferFrames = requestedIOBufferFrames
        engine.onInvalidated = { [weak self] in self?.onInvalidated?(target) }
        engines[target] = engine
        play(target, force: true)
        return nil
    }

    func tap(_ target: String, _ processes: [UInt32]) -> String? {
        guard let engine = engines[target] else { return "no engine for \(target)" }
        if engine.state == .running {
            return engine.setProcesses(processes) ? nil : "Core Audio refused the tap's new processes"
        }
        engine.start(processes: processes)
        if case .failed(let why) = engine.state { return why }
        return nil
    }

    func exclude(_ processes: [UInt32]) -> Bool {
        main.setExclusions(processes)
    }

    func stopEngine(_ target: String) {
        engines.removeValue(forKey: target)?.stop()
        playing[target] = nil
    }

    func health(_ target: String) -> RouteHealth? {
        guard let engine = engines[target] else { return nil }
        var failure: String?
        if case .failed(let why) = engine.state { failure = why }
        return RouteHealth(failure: failure, callbacks: engine.callbacks, tapCallbacks: engine.tapCallbacks,
                           signalCallbacks: engine.signalCallbacks,
                           slips: engine.underruns &+ engine.overruns &+ engine.dropouts)
    }

    /// The target's curve, when it changed: an edit, an app rule starting, `eq on`/`off`.
    func play(_ target: String, force: Bool = false) {
        guard let engine = engines[target] else { return }
        let (profile, enabled) = curve(target)
        guard force || playing[target]?.profile != profile || playing[target]?.enabled != enabled else { return }
        playing[target] = (profile, enabled)
        engine.processor.apply(profile: profile, enabled: enabled)
    }

    func playAll() {
        for target in engines.keys { play(target) }
    }
}
