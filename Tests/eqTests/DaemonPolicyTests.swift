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
}
