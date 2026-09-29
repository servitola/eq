import XCTest
@testable import eq

private let speakers = "BuiltInSpeakerDevice"
private let beRCA = "EB-06-EF-24-61-CF:output"
private let dac = "USB-DAC"

private final class FakeSink: RouteSink {
    var calls: [String] = []
    var refuseStart: Set<String> = []
    var refuseTap: Set<String> = []
    var refuseExclude = false
    var healths: [String: RouteHealth] = [:]

    func startEngine(_ target: String) -> String? {
        calls.append("start \(target)")
        return refuseStart.contains(target) ? "gone" : nil
    }

    func tap(_ target: String, _ processes: [UInt32]) -> String? {
        calls.append("tap \(target) \(processes)")
        return refuseTap.contains(target) ? "no tap" : nil
    }

    func exclude(_ processes: [UInt32]) -> Bool {
        calls.append("exclude \(processes)")
        return !refuseExclude
    }

    func stopEngine(_ target: String) {
        calls.append("stop \(target)")
    }

    func health(_ target: String) -> RouteHealth? { healths[target] }

    func take() -> [String] {
        defer { calls = [] }
        return calls
    }
}

private func plan(_ engines: [String: [UInt32]], playing: Bool = true) -> RoutePlan {
    var plan = RoutePlan()
    for (target, processes) in engines {
        let app = "app.\(target)"
        plan.apps.append(RoutedApp(app: app, name: app, target: target, reason: .first, processes: processes, playing: playing))
        plan.engines[target] = RouteEnginePlan(target: target, apps: [app], processes: processes, playing: playing)
        plan.mainExclusions.formUnion(processes)
    }
    return plan
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

final class RouteControllerTests: XCTestCase {
    private var sink: FakeSink!
    private var controller: RouteController!

    override func setUp() {
        sink = FakeSink()
        controller = RouteController(sink: sink)
    }

    private func go(_ new: RoutePlan, from old: RoutePlan = RoutePlan(), at now: Date = t0) -> Bool {
        controller.apply(RoutePlanner.actions(from: old, to: new), plan: new, now: now)
    }

    private func healthy(_ n: UInt64, signal: UInt64? = nil, slips: UInt64 = 0) -> RouteHealth {
        RouteHealth(failure: nil, callbacks: n, tapCallbacks: n, signalCallbacks: signal ?? n, slips: slips)
    }

    func testARouteStartsItsOutputThenItsTapThenLeavesTheMainTap() {
        XCTAssertFalse(go(plan([beRCA: [10, 11]])))
        XCTAssertEqual(sink.take(), ["start \(beRCA)", "tap \(beRCA) [10, 11]", "exclude [10, 11]"])
        XCTAssertEqual(controller.live, [beRCA])
    }

    func testARouteEndsWithTheMainTapTakingTheAppBackFirst() {
        let routed = plan([beRCA: [10]])
        _ = go(routed)
        sink.calls = []
        _ = go(RoutePlan(), from: routed)
        XCTAssertEqual(sink.take(), ["exclude []", "stop \(beRCA)"])
        XCTAssertTrue(controller.live.isEmpty)
    }

    func testMovingTargetsCapturesOnTheNewOneBeforeTheOldOneLetsGo() {
        let old = plan([beRCA: [10]])
        _ = go(old)
        sink.calls = []
        _ = go(plan([dac: [10]]), from: old)
        XCTAssertEqual(sink.take(), ["start \(dac)", "tap \(dac) [10]", "stop \(beRCA)"],
                       "the process never leaves the exclusion, so it is never sent again")
    }

    func testAProcessJoiningARunningRouteWidensItsTapLive() {
        let old = plan([beRCA: [10]])
        _ = go(old)
        sink.calls = []
        _ = go(plan([beRCA: [10, 12]]), from: old)
        XCTAssertEqual(sink.take(), ["tap \(beRCA) [10, 12]", "exclude [10, 12]"])
    }

    func testAFailedStartLeavesTheAppOnTheMainPathAndRetriesOnTheTick() {
        sink.refuseStart = [beRCA]
        XCTAssertFalse(go(plan([beRCA: [10]])))
        XCTAssertEqual(sink.take(), ["start \(beRCA)", "stop \(beRCA)"], "no tap, no exclusion")
        XCTAssertEqual(controller.failures[beRCA], "gone")
        sink.refuseStart = []
        XCTAssertFalse(controller.tick(now: t0 + 5))
        XCTAssertEqual(sink.take(), ["stop \(beRCA)", "start \(beRCA)", "tap \(beRCA) [10]", "exclude [10]"])
        XCTAssertEqual(controller.live, [beRCA])
    }

    func testThreeFailuresInAMinuteSuspendTheAppAndTheSuspensionLapses() {
        sink.refuseTap = [beRCA]
        XCTAssertFalse(go(plan([beRCA: [10]])))
        XCTAssertFalse(controller.tick(now: t0 + 5))
        XCTAssertTrue(controller.tick(now: t0 + 10), "the third failure")
        XCTAssertEqual(controller.suspended(at: t0 + 10), ["app.\(beRCA)".lowercased()])
        XCTAssertTrue(controller.live.isEmpty)
        XCTAssertEqual(controller.suspended(at: t0 + 10 + RouteController.suspension), [])
        XCTAssertTrue(controller.tick(now: t0 + 10 + RouteController.suspension), "lapsing is a change too")
        XCTAssertTrue(controller.suspensions.isEmpty)
    }

    func testFailuresSpreadOverMoreThanAMinuteDoNotSuspend() {
        sink.refuseTap = [beRCA]
        _ = go(plan([beRCA: [10]]))
        XCTAssertFalse(controller.tick(now: t0 + 40))
        XCTAssertFalse(controller.tick(now: t0 + 80))
        XCTAssertFalse(controller.tick(now: t0 + 120))
        XCTAssertTrue(controller.suspensions.isEmpty)
    }

    func testAStalledEngineIsRebuiltWithTheAppOnTheMainPathMeanwhile() {
        _ = go(plan([beRCA: [10]]))
        sink.healths[beRCA] = healthy(100)
        controller.tick(now: t0 + 5)
        controller.tick(now: t0 + 10)
        sink.calls = []
        controller.tick(now: t0 + 15)
        XCTAssertEqual(sink.take(), ["exclude []", "stop \(beRCA)", "start \(beRCA)", "tap \(beRCA) [10]", "exclude [10]"])
    }

    func testARingThatKeepsSlippingIsRebuilt() {
        _ = go(plan([beRCA: [10]]))
        for tick in 1...3 {
            sink.healths[beRCA] = healthy(UInt64(tick) * 100, slips: UInt64(tick) * 4)
            sink.calls = []
            controller.tick(now: t0 + Double(tick) * 5)
        }
        XCTAssertTrue(sink.calls.contains("stop \(beRCA)"))
    }

    func testZerosWhileTheAppPlaysRebuildOnceUntilSoundComesBack() {
        _ = go(plan([beRCA: [10]]))
        var n: UInt64 = 100
        func tick(_ at: Double, signal: UInt64) -> [String] {
            n += 100
            sink.healths[beRCA] = healthy(n, signal: signal)
            sink.calls = []
            controller.tick(now: t0 + at)
            return sink.calls
        }
        XCTAssertEqual(tick(5, signal: 7), [])
        XCTAssertEqual(tick(10, signal: 7), [])
        XCTAssertTrue(tick(15, signal: 7).contains("stop \(beRCA)"))
        for at in stride(from: 20.0, to: 120, by: 5) { XCTAssertEqual(tick(at, signal: 0), [], "a browser's open, silent stream") }
        XCTAssertEqual(tick(120, signal: 3), [])
        XCTAssertEqual(tick(125, signal: 3), [])
        XCTAssertTrue(tick(130, signal: 3).contains("stop \(beRCA)"), "sound came back in between")
    }

    func testZerosWhileTheAppIsPausedAreNotAFailure() {
        _ = go(plan([beRCA: [10]], playing: false))
        for tick in 1...10 {
            sink.healths[beRCA] = healthy(UInt64(tick) * 100, signal: 0)
            sink.calls = []
            controller.tick(now: t0 + Double(tick) * 5)
            XCTAssertEqual(sink.calls, [])
        }
    }

    func testAnEngineThatReportsAFailureIsRebuilt() {
        _ = go(plan([beRCA: [10]]))
        sink.healths[beRCA] = RouteHealth(failure: "device gone", callbacks: 1, tapCallbacks: 1, signalCallbacks: 1, slips: 0)
        sink.calls = []
        controller.tick(now: t0 + 5)
        XCTAssertTrue(sink.calls.contains("start \(beRCA)"))
    }

    func testARefusedExclusionAsksForAMainRebuild() {
        var asked = 0
        controller.onExclusionRefused = { asked += 1 }
        sink.refuseExclude = true
        _ = go(plan([beRCA: [10]]))
        XCTAssertEqual(asked, 1)
    }

    func testStoppingEverythingGivesTheAppsBackBeforeTheEnginesGo() {
        _ = go(plan([beRCA: [10], dac: [20]]))
        sink.calls = []
        controller.stopAll()
        XCTAssertEqual(sink.take(), ["exclude []", "stop \(beRCA)", "stop \(dac)"])
        XCTAssertTrue(controller.live.isEmpty)
    }
}

/// The daemon's loop without Core Audio: devices and processes observed, the plan resolved, the
/// actions run on the fake, and a suspension fed back into the next resolve.
final class RouteLoopTests: XCTestCase {
    private let rule = RouteRule(app: "com.spotify.client", outputs: [beRCA, speakers])
    private let spotify = [AudioProcess(pid: 10, bundleID: "com.spotify.client", path: nil, playing: false, object: 10)]
    private let identify: (AudioProcess) -> PlayingApp? = { AppIdentity.identify($0, bundleInfo: { _ in nil }) }

    private func devices(_ uids: [String]) -> [RouteDeviceState] {
        uids.map { RouteDeviceState(uid: $0, alive: true, rate: 48000, real: true) }
    }

    func testAnAppThatOpensAudioIsTappedBeforeItPlaysAndSuspensionSendsItBack() {
        let sink = FakeSink()
        let controller = RouteController(sink: sink)
        var state = RouteState()
        state.observe(devices([speakers, beRCA]), at: t0)
        let later = t0 + 1
        func step(_ processes: [AudioProcess], at now: Date) {
            let actions = state.update(rules: [rule], processes: processes, identify: identify, mainTarget: speakers,
                                       excluding: 99, suspended: controller.suspended(at: now), now: now)
            if controller.apply(actions, plan: state.plan, now: now) {
                let again = state.update(rules: [rule], processes: processes, identify: identify, mainTarget: speakers,
                                         excluding: 99, suspended: controller.suspended(at: now), now: now)
                controller.apply(again, plan: state.plan, now: now)
            }
        }
        step(spotify, at: later)
        XCTAssertEqual(sink.take(), ["start \(beRCA)", "tap \(beRCA) [10]", "exclude [10]"], "audio open, not yet playing")
        sink.healths[beRCA] = RouteHealth(failure: "IO failed", callbacks: 0, tapCallbacks: 0, signalCallbacks: 0, slips: 0)
        sink.refuseTap = [beRCA]
        XCTAssertFalse(controller.tick(now: later + 5))
        XCTAssertFalse(controller.tick(now: later + 10))
        XCTAssertTrue(controller.tick(now: later + 15))
        step(spotify, at: later + 15)
        XCTAssertEqual(state.plan.apps.first?.reason, .suspended)
        XCTAssertTrue(state.plan.engines.isEmpty)
        XCTAssertTrue(state.plan.routedApps.isEmpty, "the main path's app rules see it again")
    }
}

final class RoutePolicyTests: XCTestCase {
    private func config(routes: Bool = true) -> Config {
        var config = Config.initial(builtInUID: speakers, builtInName: "MacBook Pro Speakers")
        config.routes = [RouteRule(app: "com.spotify.client", outputs: [beRCA])]
        config.setFollowsRoutes(routes)
        return config
    }

    func testTapModeRoutesByTheRules() {
        let active = RoutePolicy.rules(config(), path: .tap, mainPathOff: false)
        XCTAssertEqual(active.rules.count, 1)
        XCTAssertNil(active.note)
    }

    func testDriverModeRoutesNothingAndSaysWhy() {
        let active = RoutePolicy.rules(config(), path: .driver, mainPathOff: false)
        XCTAssertTrue(active.rules.isEmpty)
        XCTAssertNotNil(active.note)
    }

    func testTheFlagOffIsNoRulesAndNoNote() {
        let active = RoutePolicy.rules(config(routes: false), path: .driver, mainPathOff: false)
        XCTAssertTrue(active.rules.isEmpty)
        XCTAssertNil(active.note)
    }

    func testWithTheMainPathOffOnlyRoutesPlay() {
        XCTAssertEqual(RoutePolicy.rules(config(), path: nil, mainPathOff: true).rules.count, 1)
        XCTAssertTrue(RoutePolicy.rules(config(), path: nil, mainPathOff: false).rules.isEmpty, "no path chosen yet")
    }

    func testTheMainPathSwitchIsAnExplicitOff() {
        XCTAssertTrue(RoutePolicy.mainPathOff(["EQ_MAIN_PATH": "off"]))
        XCTAssertFalse(RoutePolicy.mainPathOff(["EQ_MAIN_PATH": "on"]))
        XCTAssertFalse(RoutePolicy.mainPathOff([:]))
    }
}
