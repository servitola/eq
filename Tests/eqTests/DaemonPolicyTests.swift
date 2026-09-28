import XCTest
@testable import eq

final class DaemonPolicyTests: XCTestCase {
    func testTapCreationFailureIsReportedAsMissingPermission() {
        XCTAssertEqual(DaemonPolicy.classify("Couldn’t create audio tap (error 1852797029)."), .noPermission)
        XCTAssertEqual(DaemonPolicy.classify("Couldn’t create aggregate device (error -50)."), .failed)
        XCTAssertEqual(DaemonPolicy.classify("No output device found."), .failed)
    }

    func testRebuildOnlyWhenDefaultActuallyChanged() {
        XCTAssertFalse(DaemonPolicy.shouldRebuild(current: 42, newDefault: 42))
        XCTAssertTrue(DaemonPolicy.shouldRebuild(current: 42, newDefault: 43))
        XCTAssertTrue(DaemonPolicy.shouldRebuild(current: 0, newDefault: 43))
        XCTAssertFalse(DaemonPolicy.shouldRebuild(current: 42, newDefault: nil))
    }

    func testConstantsMatchSpec() {
        XCTAssertEqual(DaemonPolicy.rebuildAttempts, 5)
        XCTAssertEqual(DaemonPolicy.rebuildDelay, 1)
        XCTAssertEqual(DaemonPolicy.permissionRetry, 30)
        XCTAssertEqual(DaemonPolicy.statusInterval, 5)
    }

    func testHeartbeatDecision() {
        XCTAssertTrue(DaemonPolicy.shouldWriteStatus(changed: true, sinceLastWrite: 0))
        XCTAssertFalse(DaemonPolicy.shouldWriteStatus(changed: false, sinceLastWrite: 29))
        XCTAssertTrue(DaemonPolicy.shouldWriteStatus(changed: false, sinceLastWrite: 30))
        XCTAssertEqual(DaemonPolicy.heartbeat, 30)
    }

    func testStallNeedsTwoUnchangedTicks() {
        var r = DaemonPolicy.stalled(previous: 100, current: 100, unchangedTicks: 0)
        XCTAssertEqual(r.unchangedTicks, 1); XCTAssertFalse(r.stalled)
        r = DaemonPolicy.stalled(previous: 100, current: 100, unchangedTicks: 1)
        XCTAssertEqual(r.unchangedTicks, 2); XCTAssertTrue(r.stalled)
        r = DaemonPolicy.stalled(previous: 100, current: 160, unchangedTicks: 1)
        XCTAssertEqual(r.unchangedTicks, 0); XCTAssertFalse(r.stalled)
        XCTAssertEqual(DaemonPolicy.stallTicks, 2)
    }

    func testRingSlipsRisingOnThreeTicksInARowRebuild() {
        var r = DaemonPolicy.ringFailing(previous: 0, current: 4, risingTicks: 0)
        XCTAssertEqual(r.risingTicks, 1); XCTAssertFalse(r.failing)
        r = DaemonPolicy.ringFailing(previous: 4, current: 9, risingTicks: 1)
        XCTAssertEqual(r.risingTicks, 2); XCTAssertFalse(r.failing)
        r = DaemonPolicy.ringFailing(previous: 9, current: 12, risingTicks: 2)
        XCTAssertEqual(r.risingTicks, 3); XCTAssertTrue(r.failing)
        r = DaemonPolicy.ringFailing(previous: 12, current: 12, risingTicks: 2)
        XCTAssertEqual(r.risingTicks, 0); XCTAssertFalse(r.failing, "one quiet tick clears it")
        r = DaemonPolicy.ringFailing(previous: 12, current: 3, risingTicks: 2)
        XCTAssertEqual(r.risingTicks, 0); XCTAssertFalse(r.failing, "a restarted engine counts from zero")
        XCTAssertEqual(DaemonPolicy.ringFailingTicks, 3)
    }

    func testIOFramesEnv() {
        XCTAssertEqual(DaemonPolicy.ioFrames(from: ["EQ_IO_FRAMES": "512"]), 512)
        XCTAssertNil(DaemonPolicy.ioFrames(from: ["EQ_IO_FRAMES": "7"]))
        XCTAssertNil(DaemonPolicy.ioFrames(from: ["EQ_IO_FRAMES": "abc"]))
        XCTAssertNil(DaemonPolicy.ioFrames(from: [:]))
    }

    func testDriftCompensationEnv() {
        XCTAssertEqual(DaemonPolicy.driftCompensation(from: ["EQ_DRIFT_COMPENSATION": "0"]), false)
        XCTAssertEqual(DaemonPolicy.driftCompensation(from: ["EQ_DRIFT_COMPENSATION": "1"]), true)
        XCTAssertNil(DaemonPolicy.driftCompensation(from: ["EQ_DRIFT_COMPENSATION": "yes"]))
        XCTAssertNil(DaemonPolicy.driftCompensation(from: [:]))
        XCTAssertTrue(ProcessTapEngine().driftCompensation)
    }

    func testRateZeroIsSkippedAndAnyRealChangeRebuilds() {
        XCTAssertFalse(DaemonPolicy.shouldRebuildForRate(old: 48000, new: 0))
        XCTAssertFalse(DaemonPolicy.shouldRebuildForRate(old: 48000, new: 48000))
        XCTAssertTrue(DaemonPolicy.shouldRebuildForRate(old: 48000, new: 24000))
        XCTAssertTrue(DaemonPolicy.shouldRebuildForRate(old: 24000, new: 48000))
        XCTAssertTrue(DaemonPolicy.shouldRebuildForRate(old: 44100, new: 96000))
    }

    func testCallModeCoversWidebandSCO() {
        XCTAssertTrue(DaemonPolicy.isCallMode(8000))
        XCTAssertTrue(DaemonPolicy.isCallMode(16000))
        XCTAssertTrue(DaemonPolicy.isCallMode(24000))
        XCTAssertFalse(DaemonPolicy.isCallMode(44100))
        XCTAssertFalse(DaemonPolicy.isCallMode(48000))
        XCTAssertFalse(DaemonPolicy.isCallMode(0))
    }

    func testReconcileAgainstEngineTruth() {
        XCTAssertEqual(DaemonPolicy.reconcile(target: 42, newDefault: 42, engineRate: 48000, deviceRate: 48000), .keep)
        XCTAssertEqual(DaemonPolicy.reconcile(target: 42, newDefault: 43, engineRate: 48000, deviceRate: 48000), .device(43))
        XCTAssertEqual(DaemonPolicy.reconcile(target: 42, newDefault: 42, engineRate: 48000, deviceRate: 24000), .rate(24000))
        XCTAssertEqual(DaemonPolicy.reconcile(target: 42, newDefault: 42, engineRate: 48000, deviceRate: 0), .rateUnsettled)
        XCTAssertEqual(DaemonPolicy.reconcile(target: 42, newDefault: nil, engineRate: 48000, deviceRate: 48000), .keep)
        XCTAssertEqual(DaemonPolicy.reconcile(target: 42, newDefault: 42, engineRate: 48000, deviceRate: nil), .keep)
        XCTAssertEqual(DaemonPolicy.reconcile(target: 42, newDefault: 43, engineRate: 48000, deviceRate: 0), .device(43),
                       "a new default wins over the old device's unsettled rate")
    }

    func testBluetoothCallModeRoundTripRebuildsTwiceAndSkipsZero() {
        let scheduler = ManualScheduler()
        var engineRate = 48000.0
        var deviceRate = 48000.0
        var rebuilds: [Double] = []
        var debouncer: Debouncer!
        debouncer = Debouncer(delay: DaemonPolicy.settleDelay, schedule: scheduler.schedule) {
            switch DaemonPolicy.reconcile(target: 42, newDefault: 42, engineRate: engineRate, deviceRate: deviceRate) {
            case .rate(let r): rebuilds.append(r); engineRate = r
            case .rateUnsettled: debouncer.trigger()
            case .keep, .device: break
            }
        }
        for rate in [0.0, 24000] { deviceRate = rate; debouncer.trigger(); scheduler.advance(by: 0.05) }
        deviceRate = 0; debouncer.trigger()
        scheduler.advance(by: 0.15)
        XCTAssertEqual(rebuilds, [], "a rate still reading 0 after the burst is re-read, not rebuilt on")
        deviceRate = 24000
        scheduler.advance(by: 0.15)
        XCTAssertEqual(rebuilds, [24000])
        deviceRate = 48000; debouncer.trigger()
        scheduler.advance(by: 0.15)
        XCTAssertEqual(rebuilds, [24000, 48000])
    }

    func testBurstOfFiveEventsRunsOneReconcile() {
        let scheduler = ManualScheduler()
        var runs = 0
        let debouncer = Debouncer(delay: DaemonPolicy.settleDelay, schedule: scheduler.schedule) { runs += 1 }
        debouncer.trigger()
        for _ in 0..<4 {
            scheduler.advance(by: 0.03)
            debouncer.trigger()
        }
        XCTAssertEqual(runs, 0)
        scheduler.advance(by: 0.149)
        XCTAssertEqual(runs, 0)
        scheduler.advance(by: 0.001)
        XCTAssertEqual(runs, 1)
        scheduler.advance(by: 10)
        XCTAssertEqual(runs, 1)
    }

    func testCancelledDebounceNeverFires() {
        let scheduler = ManualScheduler()
        var runs = 0
        let debouncer = Debouncer(delay: 0.15, schedule: scheduler.schedule) { runs += 1 }
        debouncer.trigger()
        debouncer.cancel()
        scheduler.advance(by: 1)
        XCTAssertEqual(runs, 0)
        debouncer.trigger()
        scheduler.advance(by: 1)
        XCTAssertEqual(runs, 1)
    }

    func testPowerMessagesMatchIOMessageHeader() {
        let sysIOKit: UInt32 = 0x38 << 26
        XCTAssertEqual(SystemPower.canSystemSleep, sysIOKit | 0x270)
        XCTAssertEqual(SystemPower.systemWillSleep, sysIOKit | 0x280)
        XCTAssertEqual(SystemPower.systemHasPoweredOn, sysIOKit | 0x300)
    }

    func testEventTimingConstants() {
        XCTAssertEqual(DaemonPolicy.settleDelay, 0.15)
        XCTAssertEqual(DaemonPolicy.wakeDelay, 1)
        XCTAssertEqual(DaemonPolicy.callModeBelow, 44100)
    }

    func testUsableRateRejectsZeroAndNonFinite() {
        XCTAssertFalse(DaemonPolicy.usableRate(0))
        XCTAssertFalse(DaemonPolicy.usableRate(-1))
        XCTAssertFalse(DaemonPolicy.usableRate(.nan))
        XCTAssertFalse(DaemonPolicy.usableRate(.infinity))
        XCTAssertTrue(DaemonPolicy.usableRate(44100))
        XCTAssertTrue(DaemonPolicy.usableRate(48000))
    }

    func testWakeFallbackFiresOnlyPastTheTimeout() {
        let since = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(DaemonPolicy.wakeFallbackDue(asleepSince: since, now: since + 119))
        XCTAssertFalse(DaemonPolicy.wakeFallbackDue(asleepSince: since, now: since + 120))
        XCTAssertTrue(DaemonPolicy.wakeFallbackDue(asleepSince: since, now: since + 121))
        XCTAssertEqual(DaemonPolicy.wakeFallbackTimeout, 120)
    }
}

private final class ManualScheduler {
    private var now: TimeInterval = 0
    private var pending: [(at: TimeInterval, order: Int, work: () -> Void)] = []
    private var order = 0

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        order += 1
        pending.append((now + delay, order, work))
    }

    func advance(by interval: TimeInterval) {
        let end = now + interval
        while let next = pending.filter({ $0.at <= end + 1e-9 }).min(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
            pending.removeAll { $0.order == next.order }
            now = max(now, next.at)
            next.work()
        }
        now = end
    }
}
