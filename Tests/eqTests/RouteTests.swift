import XCTest
import CoreAudio
@testable import eq

private let speakers = "BuiltInSpeakerDevice"
private let beRCA = "EB-06-EF-24-61-CF:output"
private let dac = "USB-DAC"
private let airPlay = "AirPlay-TV"

private let bundles: [String: PlayingApp] = [
    "/Applications/Spotify.app": PlayingApp(id: "com.spotify.client", name: "Spotify"),
    "/Applications/Google Chrome.app": PlayingApp(id: "com.google.Chrome", name: "Google Chrome"),
    "/Applications/Safari.app": PlayingApp(id: "com.apple.Safari", name: "Safari"),
]

private func identify(_ process: AudioProcess) -> PlayingApp? {
    AppIdentity.identify(process, bundleInfo: { bundles[$0] })
}

private func process(_ object: UInt32, _ bundleID: String, path: String? = nil, playing: Bool = true, pid: pid_t? = nil) -> AudioProcess {
    AudioProcess(pid: pid ?? pid_t(object), bundleID: bundleID, path: path, playing: playing, object: object)
}

private let spotifyPath = "/Applications/Spotify.app/Contents/MacOS/Spotify"
private let webKitGPUPath = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"

private let spotifyRule = RouteRule(app: "com.spotify.client", outputs: [beRCA, speakers])
private let chromeRule = RouteRule(app: "com.google.Chrome", outputs: [beRCA])

private func resolve(_ rules: [RouteRule], _ processes: [AudioProcess], available: Set<String>, main: String? = speakers) -> RoutePlan {
    RouteResolver.resolve(rules: rules, processes: processes, identify: identify, available: available, mainTarget: main, excluding: 99)
}

private func usable(_ uid: String, rate: Double = 48000, real: Bool = true) -> RouteDeviceState {
    RouteDeviceState(uid: uid, alive: true, rate: rate, real: real)
}

final class RouteResolverTests: XCTestCase {
    private let spotify = [process(10, "com.spotify.client", path: spotifyPath)]

    func testTheFirstChoicePlaysThereWhateverTheDefault() {
        let plan = resolve([spotifyRule], spotify, available: [speakers, beRCA])
        XCTAssertEqual(plan.apps, [RoutedApp(app: "com.spotify.client", name: "Spotify", target: beRCA, reason: .first, processes: [10], playing: true)])
        XCTAssertEqual(plan.engines, [beRCA: RouteEnginePlan(target: beRCA, apps: ["com.spotify.client"], processes: [10], playing: true)])
        XCTAssertEqual(plan.mainExclusions, [10])
        XCTAssertEqual(plan.routedApps, ["com.spotify.client"])
    }

    func testAnAbsentFirstChoiceFallsBackToTheNextAvailable() {
        let plan = resolve([RouteRule(app: "com.spotify.client", outputs: [beRCA, dac, speakers])], spotify, available: [speakers, dac])
        XCTAssertEqual(plan.apps.first?.target, dac)
        XCTAssertEqual(plan.apps.first?.reason, .fallback)
        XCTAssertEqual(Array(plan.engines.keys), [dac])
    }

    func testWithNoOutputAvailableTheAppFollowsTheDefault() {
        let plan = resolve([RouteRule(app: "com.spotify.client", outputs: [beRCA])], spotify, available: [speakers])
        XCTAssertEqual(plan.apps.first?.reason, .exhausted)
        XCTAssertNil(plan.apps.first?.target)
        XCTAssertTrue(plan.engines.isEmpty)
        XCTAssertTrue(plan.mainExclusions.isEmpty)
        XCTAssertTrue(plan.routedApps.isEmpty)
    }

    func testTheDefaultOutputIsNoRouteInTapMode() {
        let main = RouteResolver.mainTarget(path: .tap, defaultOutput: beRCA, driverTarget: speakers)
        XCTAssertEqual(main, beRCA)
        let plan = resolve([spotifyRule], spotify, available: [speakers, beRCA], main: main)
        XCTAssertEqual(plan.apps.first?.reason, .identity)
        XCTAssertEqual(plan.apps.first?.target, beRCA)
        XCTAssertTrue(plan.engines.isEmpty)
        XCTAssertTrue(plan.mainExclusions.isEmpty)
    }

    func testAFallbackThatIsTheDefaultIsNoRouteEither() {
        let plan = resolve([spotifyRule], spotify, available: [speakers])
        XCTAssertEqual(plan.apps.first?.reason, .identity)
        XCTAssertTrue(plan.engines.isEmpty)
    }

    func testInDriverModeTheDriversTargetIsTheMainPath() {
        let onBE = RouteResolver.mainTarget(path: .driver, defaultOutput: DriverControl.deviceUID, driverTarget: beRCA)
        XCTAssertEqual(onBE, beRCA)
        XCTAssertEqual(resolve([spotifyRule], spotify, available: [speakers, beRCA], main: onBE).apps.first?.reason, .identity)
        let onSpeakers = RouteResolver.mainTarget(path: .driver, defaultOutput: DriverControl.deviceUID, driverTarget: speakers)
        XCTAssertEqual(Array(resolve([spotifyRule], spotify, available: [speakers, beRCA], main: onSpeakers).engines.keys), [beRCA])
    }

    func testTwoAppsOnOneTargetShareOneEngine() {
        let processes = spotify + [process(20, "com.google.Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", playing: false)]
        let plan = resolve([spotifyRule, chromeRule], processes, available: [speakers, beRCA])
        XCTAssertEqual(plan.engines, [beRCA: RouteEnginePlan(target: beRCA, apps: ["com.spotify.client", "com.google.Chrome"], processes: [10, 20], playing: true)])
        XCTAssertEqual(plan.mainExclusions, [10, 20])
    }

    func testHelpersJoinTheirAppWhetherOrNotTheirPathIsKnown() {
        let processes = [
            process(31, "com.google.Chrome.helper.Renderer",
                    path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"),
            process(30, "com.google.Chrome", playing: false),
            process(32, "com.google.Chrome.helper", playing: false),
        ]
        let plan = resolve([chromeRule], processes, available: [speakers, beRCA])
        XCTAssertEqual(plan.apps.count, 1)
        XCTAssertEqual(plan.apps.first?.processes, [30, 31, 32])
        XCTAssertEqual(plan.apps.first?.name, "Google Chrome")
        XCTAssertEqual(plan.apps.first?.playing, true)
        XCTAssertEqual(plan.mainExclusions, [30, 31, 32])
    }

    func testWebKitsGPUProcessIsNotSafari() {
        let processes = [process(40, "com.apple.Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", playing: false),
                         process(41, "com.apple.WebKit.GPU", path: webKitGPUPath)]
        let safari = resolve([RouteRule(app: "com.apple.Safari", outputs: [beRCA])], processes, available: [speakers, beRCA])
        XCTAssertEqual(safari.mainExclusions, [40], "Safari's sound comes from WebKit's GPU process, which a Safari rule does not reach")
        let webKit = resolve([RouteRule(app: "com.apple.WebKit.GPU", outputs: [beRCA])], processes, available: [speakers, beRCA])
        XCTAssertEqual(webKit.mainExclusions, [41])
    }

    func testEqItselfAndAppsWithoutARuleStayOnTheMainPath() {
        let processes = [process(1, "com.servitola.eq", pid: 99), process(2, "com.apple.Music")]
        let plan = resolve([RouteRule(app: "com.servitola.eq", outputs: [beRCA])], processes, available: [speakers, beRCA])
        XCTAssertEqual(plan, RoutePlan())
    }

    func testRulesMatchWithoutRegardToCase() {
        let plan = resolve([RouteRule(app: "COM.SPOTIFY.CLIENT", outputs: [beRCA])], spotify, available: [beRCA])
        XCTAssertEqual(plan.mainExclusions, [10])
    }

    func testWithTheFlagOffNoRuleIsActive() {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.routes = [spotifyRule]
        XCTAssertEqual(config.activeRoutes, [])
        config.setFollowsRoutes(true)
        XCTAssertEqual(config.activeRoutes, [spotifyRule])
    }
}

final class RoutePlannerTests: XCTestCase {
    private func plan(_ engines: [String: [UInt32]]) -> RoutePlan {
        var plan = RoutePlan()
        for (target, processes) in engines {
            plan.engines[target] = RouteEnginePlan(target: target, apps: [], processes: processes, playing: true)
            plan.mainExclusions.formUnion(processes)
        }
        return plan
    }

    func testARouteStartsWithTheTargetThenTheTapThenTheExclusion() {
        XCTAssertEqual(RoutePlanner.actions(from: RoutePlan(), to: plan([beRCA: [10]])),
                       [.startEngine(beRCA), .tap(beRCA, [10]), .exclude([10])])
    }

    func testARouteEndsWithTheMainTapTakingTheAppBackBeforeTheEngineGoes() {
        XCTAssertEqual(RoutePlanner.actions(from: plan([beRCA: [10]]), to: RoutePlan()), [.exclude([]), .stopEngine(beRCA)])
    }

    func testAMoveBetweenTargetsCapturesOnTheNewOneBeforeLettingGoOfTheOld() {
        XCTAssertEqual(RoutePlanner.actions(from: plan([beRCA: [10]]), to: plan([dac: [10]])),
                       [.startEngine(dac), .tap(dac, [10]), .stopEngine(beRCA)])
    }

    func testATapThatGainsAndLosesProcessesWidensFirstAndNarrowsLast() {
        XCTAssertEqual(RoutePlanner.actions(from: plan([beRCA: [1, 2]]), to: plan([beRCA: [2, 3]])),
                       [.tap(beRCA, [1, 2, 3]), .exclude([2, 3]), .tap(beRCA, [2, 3])])
        XCTAssertEqual(RoutePlanner.actions(from: plan([beRCA: [1]]), to: plan([beRCA: [1, 2]])), [.tap(beRCA, [1, 2]), .exclude([1, 2])])
        XCTAssertEqual(RoutePlanner.actions(from: plan([beRCA: [1, 2]]), to: plan([beRCA: [1]])), [.exclude([1]), .tap(beRCA, [1])])
    }

    func testNoChangeIsNoAction() {
        let same = plan([beRCA: [1, 2], dac: [3]])
        XCTAssertEqual(RoutePlanner.actions(from: same, to: same), [])
    }
}

final class RouteDevicesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testOnlyARealLiveDeviceWithARateIsUsable() {
        XCTAssertTrue(usable(beRCA).usable)
        XCTAssertFalse(usable(beRCA, rate: 0).usable)
        XCTAssertFalse(RouteDeviceState(uid: beRCA, alive: false, rate: 48000, real: true).usable)
        let tv = AudioOutputDevice(id: 5, uid: airPlay, name: "TV", transportType: kAudioDeviceTransportTypeAirPlay)
        XCTAssertFalse(RouteDeviceState(tv, alive: true, rate: 48000).usable)
        let eqDevice = AudioOutputDevice(id: 6, uid: DriverControl.deviceUID, name: "BE-RCA · EQ", transportType: kAudioDeviceTransportTypeVirtual)
        XCTAssertFalse(RouteDeviceState(eqDevice, alive: true, rate: 48000).usable)
        let aggregate = AudioOutputDevice(id: 7, uid: AudioDeviceManager.aggregateUIDPrefix + beRCA, name: "eq", transportType: kAudioDeviceTransportTypeAggregate)
        XCTAssertFalse(RouteDeviceState(aggregate, alive: true, rate: 48000).usable)
        let speaker = AudioOutputDevice(id: 8, uid: beRCA, name: "BE-RCA", transportType: kAudioDeviceTransportTypeBluetooth)
        XCTAssertTrue(RouteDeviceState(speaker, alive: true, rate: 44100).usable)
    }

    func testADeviceThatArrivesInTwoStepsIsAvailableOnceItHasSettled() {
        var devices = RouteDevices()
        devices.observe([usable(speakers), usable(beRCA, rate: 0)], at: t0)
        XCTAssertEqual(devices.available(at: t0.addingTimeInterval(5)), [speakers])
        let rated = t0.addingTimeInterval(6)
        devices.observe([usable(speakers), usable(beRCA)], at: rated)
        XCTAssertEqual(devices.available(at: rated), [speakers])
        XCTAssertEqual(devices.nextChange(after: rated), rated.addingTimeInterval(RouteDevices.settle))
        XCTAssertEqual(devices.available(at: rated.addingTimeInterval(RouteDevices.settle)), [speakers, beRCA])
        XCTAssertNil(devices.nextChange(after: rated.addingTimeInterval(RouteDevices.settle)))
    }

    func testADeviceThatGoesIsUnavailableAtOnce() {
        var devices = RouteDevices()
        devices.observe([usable(speakers), usable(beRCA)], at: t0)
        let later = t0.addingTimeInterval(20)
        XCTAssertEqual(devices.available(at: later), [speakers, beRCA])
        devices.observe([usable(speakers), RouteDeviceState(uid: beRCA, alive: false, rate: 48000, real: true)], at: later)
        XCTAssertEqual(devices.available(at: later), [speakers])
    }

    /// Appears at t, t+2, t+4, t+6: the fourth arrival in 10 s holds it off for 30 s.
    func testAFlappingDeviceIsHeldOffAndComesBackAfterTheHold() {
        var devices = RouteDevices()
        var t = t0
        var held = Set<String>()
        for _ in 0..<4 {
            held = devices.observe([usable(speakers), usable(beRCA)], at: t)
            devices.observe([usable(speakers)], at: t.addingTimeInterval(1))
            t = t.addingTimeInterval(2)
        }
        XCTAssertEqual(held, [beRCA])
        let last = t.addingTimeInterval(-2)
        devices.observe([usable(speakers), usable(beRCA)], at: last.addingTimeInterval(1.5))
        XCTAssertTrue(devices.isHeld(beRCA, at: last.addingTimeInterval(20)))
        XCTAssertEqual(devices.available(at: last.addingTimeInterval(20)), [speakers])
        XCTAssertEqual(devices.nextChange(after: last.addingTimeInterval(20)), last.addingTimeInterval(RouteDevices.hold))
        XCTAssertEqual(devices.available(at: last.addingTimeInterval(RouteDevices.hold)), [speakers, beRCA])
    }

    func testThreeArrivalsInTenSecondsOrFourSpreadOutAreNoFlap() {
        var devices = RouteDevices()
        for step in 0..<3 {
            let t = t0.addingTimeInterval(Double(step) * 2)
            XCTAssertEqual(devices.observe([usable(beRCA)], at: t), [])
            devices.observe([], at: t.addingTimeInterval(1))
        }
        XCTAssertEqual(devices.observe([usable(beRCA)], at: t0.addingTimeInterval(11)), [], "the first arrival is out of the window by now")
        XCTAssertEqual(devices.available(at: t0.addingTimeInterval(12)), [beRCA])
    }
}

final class RouteStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private var state = RouteState()

    private func update(_ processes: [AudioProcess], main: String? = speakers, at t: Date) -> [RouteAction] {
        state.update(rules: [spotifyRule], processes: processes, identify: identify, mainTarget: main, excluding: 99, now: t)
    }

    func testAnAppThatStartsAndStops() {
        state.observe([usable(speakers), usable(beRCA)], at: t0)
        let t = t0.addingTimeInterval(1)
        XCTAssertEqual(update([], at: t), [])
        XCTAssertEqual(update([process(10, "com.spotify.client", path: spotifyPath)], at: t), [.startEngine(beRCA), .tap(beRCA, [10]), .exclude([10])])
        XCTAssertEqual(update([process(10, "com.spotify.client", playing: false)], at: t), [], "a pause keeps the route")
        XCTAssertEqual(update([process(10, "com.spotify.client", playing: false), process(11, "com.spotify.client.helper")], at: t),
                       [.tap(beRCA, [10, 11]), .exclude([10, 11])])
        XCTAssertEqual(update([], at: t), [.exclude([]), .stopEngine(beRCA)])
    }

    func testTheTargetLeavingAndComingBackMovesTheApp() throws {
        state.observe([usable(speakers), usable(beRCA)], at: t0)
        let spotify = [process(10, "com.spotify.client", path: spotifyPath)]
        var t = t0.addingTimeInterval(1)
        _ = update(spotify, at: t)
        state.observe([usable(speakers)], at: t)
        XCTAssertEqual(update(spotify, at: t), [.exclude([]), .stopEngine(beRCA)], "the fallback is the default, so the main path takes Spotify back")
        XCTAssertEqual(state.plan.apps.first?.reason, .identity)

        t = t.addingTimeInterval(5)
        state.observe([usable(speakers), usable(beRCA, rate: 0)], at: t)
        XCTAssertEqual(update(spotify, at: t), [])
        state.observe([usable(speakers), usable(beRCA)], at: t)
        XCTAssertEqual(update(spotify, at: t), [], "not before it settles")
        let settled = try XCTUnwrap(state.devices.nextChange(after: t))
        XCTAssertEqual(update(spotify, at: settled), [.startEngine(beRCA), .tap(beRCA, [10]), .exclude([10])])
    }

    func testTheDefaultMovingToTheTargetEndsTheRoute() {
        state.observe([usable(speakers), usable(beRCA)], at: t0)
        let spotify = [process(10, "com.spotify.client", path: spotifyPath)]
        let t = t0.addingTimeInterval(1)
        _ = update(spotify, at: t)
        XCTAssertEqual(update(spotify, main: beRCA, at: t), [.exclude([]), .stopEngine(beRCA)])
        XCTAssertEqual(update(spotify, main: speakers, at: t), [.startEngine(beRCA), .tap(beRCA, [10]), .exclude([10])])
    }
}

final class RouteCurveTests: XCTestCase {
    private var config: Config {
        var config = Config.initial(builtInUID: speakers, builtInName: "MacBook Pro Speakers")
        config.devices[beRCA] = Profile(name: "BE-RCA", preamp: -2, bands: Profile.flat.bands)
        config.apps = [AppRule(app: "com.spotify.client", preset: "favourite"), AppRule(app: "com.google.Chrome", preset: "flat")]
        config.routes = [spotifyRule, chromeRule]
        config.setFollowsRoutes(true)
        return config
    }

    private let spotifyOnBE = process(10, "com.spotify.client", path: spotifyPath)
    private let chrome = process(20, "com.google.Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

    func testARouteEnginePlaysItsTargetsCurve() {
        let plan = resolve(config.activeRoutes, [spotifyOnBE], available: [speakers, beRCA])
        let heard = RouteCurve.heard(on: beRCA, in: plan, config: config, nowPlaying: nil)
        XCTAssertEqual(heard.profile, config.devices[beRCA])
        XCTAssertNil(heard.match, "apps are off")
    }

    func testWithAppsOnTheWinningRuleAmongTheEnginesAppsOverlaysTheTargetsCurve() {
        var config = config
        config.setFollowsApps(true)
        let plan = resolve(config.activeRoutes, [spotifyOnBE], available: [speakers, beRCA])
        let heard = RouteCurve.heard(on: beRCA, in: plan, config: config, nowPlaying: nil)
        XCTAssertEqual(heard.match, AppMatch(app: "com.spotify.client", name: "Spotify", preset: "favourite"))
        XCTAssertEqual(heard.profile.bands, Config.screenshotCurve)
        XCTAssertEqual(heard.profile.name, "BE-RCA")

        let both = resolve(config.activeRoutes, [spotifyOnBE, chrome], available: [speakers, beRCA])
        XCTAssertEqual(RouteCurve.candidates(for: beRCA, in: both, config: config).count, 2)
        XCTAssertEqual(RouteCurve.heard(on: beRCA, in: both, config: config, nowPlaying: "com.google.Chrome.helper").match?.app, "com.google.Chrome")
        XCTAssertEqual(RouteCurve.heard(on: beRCA, in: both, config: config, nowPlaying: nil).match?.app, "com.spotify.client")
    }

    func testAnAppOnTheMainPathOrPausedDoesNotChooseARoutesCurve() {
        var config = config
        config.setFollowsApps(true)
        config.routes = [spotifyRule]
        let plan = resolve(config.activeRoutes, [process(10, "com.spotify.client", playing: false), chrome], available: [speakers, beRCA])
        XCTAssertEqual(RouteCurve.candidates(for: beRCA, in: plan, config: config), [])
        XCTAssertEqual(RouteCurve.heard(on: beRCA, in: plan, config: config, nowPlaying: nil).profile, config.devices[beRCA])
    }
}

private extension RouteAction {
    var isExclude: Bool {
        if case .exclude = self { return true }
        return false
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What the route actions build, checked after every single action: a route tap only on an engine
/// that is up, and never a process the main tap leaves out that no route tap carries.
private struct FakeRouteSink {
    var taps: [String: Set<UInt32>] = [:]
    var excluded: Set<UInt32> = []

    mutating func apply(_ actions: [RouteAction], file: StaticString = #filePath, line: UInt = #line) {
        for action in actions {
            switch action {
            case .startEngine(let target):
                XCTAssertNil(taps[target], "\(target) started twice", file: file, line: line)
                taps[target] = []
            case .tap(let target, let processes):
                XCTAssertNotNil(taps[target], "tap on \(target) before its engine", file: file, line: line)
                taps[target] = Set(processes)
            case .exclude(let processes):
                excluded = Set(processes)
            case .stopEngine(let target):
                XCTAssertNotNil(taps[target], "\(target) stopped but never started", file: file, line: line)
                taps[target] = nil
            }
            let carried = taps.values.reduce(into: Set<UInt32>()) { $0.formUnion($1) }
            XCTAssertTrue(excluded.isSubset(of: carried), "a gap after \(action): \(excluded.subtracting(carried)) heard nowhere", file: file, line: line)
        }
    }
}

final class RoutePropertyTests: XCTestCase {
    private struct Slot {
        var bundleID: String
        var path: String?
        var pid: pid_t?
    }

    private let slots = [
        Slot(bundleID: "com.spotify.client", path: spotifyPath),
        Slot(bundleID: "com.spotify.client.helper", path: "/Applications/Spotify.app/Contents/Frameworks/Spotify Helper.app/Contents/MacOS/Spotify Helper"),
        Slot(bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        Slot(bundleID: "com.google.Chrome.helper.Renderer", path: nil),
        Slot(bundleID: "com.google.Chrome.helper", path: nil),
        Slot(bundleID: "com.apple.Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari"),
        Slot(bundleID: "com.apple.WebKit.GPU", path: webKitGPUPath),
        Slot(bundleID: "com.apple.Music", path: nil),
        Slot(bundleID: "com.servitola.eq", path: nil, pid: 99),
    ]

    private let rules = [
        RouteRule(app: "com.spotify.client", outputs: [beRCA, speakers]),
        RouteRule(app: "com.google.Chrome", outputs: [dac, beRCA]),
        RouteRule(app: "com.apple.WebKit.GPU", outputs: [airPlay, dac]),
        RouteRule(app: "com.apple.Safari", outputs: [beRCA]),
        RouteRule(app: "com.servitola.eq", outputs: [dac]),
    ]

    private let devices: [(uid: String, real: Bool)] = [(speakers, true), (beRCA, true), (dac, true), (airPlay, false), (DriverControl.deviceUID, false)]

    func testRandomChurnKeepsEveryInvariant() {
        var seen: [RouteAction] = []
        for seed in UInt64(1)...40 {
            seen += run(seed: seed, steps: 400)
        }
        XCTAssertTrue(seen.contains { if case .startEngine = $0 { return true } else { return false } }, "the churn never routed anything")
        XCTAssertTrue(seen.contains { if case .stopEngine = $0 { return true } else { return false } })
        XCTAssertTrue(seen.contains { if case .tap(_, let processes) = $0 { return processes.count > 1 } else { return false } })
    }

    private func run(seed: UInt64, steps: Int) -> [RouteAction] {
        var all: [RouteAction] = []
        var rng = SplitMix64(state: seed)
        var now = Date(timeIntervalSince1970: 1000)
        var nextObject: UInt32 = 100
        var running: [Int: AudioProcess] = [:]
        var deviceStates: [String: RouteDeviceState?] = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, RouteDeviceState(uid: $0.uid, alive: true, rate: 48000, real: $0.real)) })
        var path = AudioPaths.Path.tap
        var defaultOutput: String? = speakers
        var driverTarget: String? = speakers
        var state = RouteState()
        var sink = FakeRouteSink()

        for step in 0..<steps {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0...3:
                let index = Int.random(in: 0..<slots.count, using: &rng)
                if running[index] != nil, Bool.random(using: &rng) {
                    running[index] = nil
                } else if var process = running[index] {
                    process.playing.toggle()
                    process.path = process.playing ? slots[index].path : nil
                    running[index] = process
                } else {
                    nextObject += 1
                    let playing = Bool.random(using: &rng)
                    running[index] = AudioProcess(pid: slots[index].pid ?? pid_t(nextObject), bundleID: slots[index].bundleID,
                                                  path: playing ? slots[index].path : nil, playing: playing, object: nextObject)
                }
            case 4...6:
                let device = devices.randomElement(using: &rng)!
                deviceStates[device.uid] = [
                    nil,
                    RouteDeviceState(uid: device.uid, alive: true, rate: 0, real: device.real),
                    RouteDeviceState(uid: device.uid, alive: false, rate: 48000, real: device.real),
                    RouteDeviceState(uid: device.uid, alive: true, rate: 44100, real: device.real),
                ].randomElement(using: &rng)!
            case 7:
                path = Bool.random(using: &rng) ? .tap : .driver
                defaultOutput = [speakers, beRCA, dac, nil].randomElement(using: &rng)!
                driverTarget = [speakers, beRCA, dac].randomElement(using: &rng)!
            default:
                now = now.addingTimeInterval([0, 0.05, 0.2, 1, 3, 12].randomElement(using: &rng)!)
            }

            state.observe(deviceStates.values.compactMap { $0 }, at: now)
            let main = RouteResolver.mainTarget(path: path, defaultOutput: defaultOutput, driverTarget: driverTarget)
            let processes = running.keys.sorted().map { running[$0]! }
            let before = state.plan
            let actions = state.update(rules: rules, processes: processes, identify: identify, mainTarget: main, excluding: 99, now: now)
            let context = "seed \(seed) step \(step)"

            check(state.plan, processes: processes, available: state.devices.available(at: now), main: main, context)
            checkOrder(actions, context)
            sink.apply(actions)
            XCTAssertEqual(sink.taps, state.plan.engines.mapValues { Set($0.processes) }, context)
            XCTAssertEqual(sink.excluded, state.plan.mainExclusions, context)
            XCTAssertEqual(RoutePlanner.actions(from: state.plan, to: state.plan), [], context)
            XCTAssertEqual(RoutePlanner.actions(from: before, to: state.plan), actions, context)
            all += actions
        }
        return all
    }

    private func check(_ plan: RoutePlan, processes: [AudioProcess], available: Set<String>, main: String?, _ context: String) {
        var seen: [UInt32: Int] = [:]
        for engine in plan.engines.values {
            XCTAssertNotEqual(engine.target, main, "an engine on the main path's own device: \(context)")
            XCTAssertTrue(available.contains(engine.target), "an engine on an unavailable device: \(context)")
            XCTAssertTrue(devices.contains { $0.uid == engine.target && $0.real }, context)
            XCTAssertFalse(engine.processes.isEmpty, context)
            for object in engine.processes { seen[object, default: 0] += 1 }
        }
        XCTAssertTrue(seen.values.allSatisfy { $0 == 1 }, "a process in two engines: \(context)")
        XCTAssertEqual(plan.mainExclusions, Set(seen.keys), context)

        let own = Set(processes.filter { $0.pid == 99 }.map(\.object))
        XCTAssertTrue(plan.mainExclusions.isDisjoint(with: own), "eq routed itself: \(context)")
        for app in plan.apps {
            let rule = rules.first { $0.matches(app.app) }!
            XCTAssertEqual(app.target, rule.outputs.first(where: available.contains), context)
            let engine = plan.engines.values.first { $0.processes.contains(app.processes[0]) }
            if app.isRouted {
                XCTAssertEqual(engine?.target, app.target, context)
                XCTAssertTrue(Set(app.processes).isSubset(of: Set(engine?.processes ?? [])), context)
            } else {
                XCTAssertNil(engine, "an app on the main path is in an engine: \(context)")
            }
        }
        let identified = processes.filter { $0.pid != 99 && identify($0).map { id in rules.contains { $0.matches(id.id) } } == true }
        XCTAssertEqual(Set(plan.apps.flatMap(\.processes)), Set(identified.map(\.object)), "every process of a ruled app is placed: \(context)")
    }

    /// Engines up and taps widened, then the main tap's exclusions, then taps narrowed and engines down.
    private func checkOrder(_ actions: [RouteAction], _ context: String) {
        let excludes = actions.indices.filter { actions[$0].isExclude }
        XCTAssertLessThanOrEqual(excludes.count, 1, context)
        let phases = actions.indices.map { index -> Int in
            switch actions[index] {
            case .startEngine: return 0
            case .exclude: return 1
            case .stopEngine: return 2
            case .tap: return excludes.contains { $0 < index } ? 2 : 0
            }
        }
        XCTAssertEqual(phases, phases.sorted(), "actions out of order: \(actions) \(context)")
    }
}
