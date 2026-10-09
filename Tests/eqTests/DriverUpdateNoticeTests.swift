import UserNotifications
import XCTest
@testable import eq

/// The daemon's notification about a newer bundled driver, against a fake poster: nothing reaches
/// Notification Center from a test.
final class DriverUpdateNoticeTests: XCTestCase {
    private var dir: URL!
    private var posted: [DriverUpdateNotice] = []
    private var notifier: DriverUpdateNotifier!

    private let old = DriverBuild(version: "2026.09.29", revision: 14, protocolVersion: 1)
    private let new = DriverBuild(version: "2026.10.05", revision: 18, protocolVersion: 2)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-notice-\(UUID().uuidString)")
        posted = []
        notifier = DriverUpdateNotifier(marker: RevisionMarker(url: dir.appendingPathComponent(DriverUpdate.notifiedName))) { [unowned self] in
            self.posted.append($0)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testTheNotice() {
        XCTAssertEqual(DriverUpdateNotice.due(DriverFiles(installed: old, bundled: new), notified: nil),
                       DriverUpdateNotice(title: "EQ driver update",
                                          body: "Build 14 → 18: spectrum analyser, true silence for silent outputs. Click to install."))
        XCTAssertEqual(DriverUpdateNotice.due(DriverFiles(installed: DriverBuild(version: "x", revision: 15), bundled: DriverBuild(version: "y", revision: 16)),
                                              notified: nil)?.body, "Build 15 → 16. Click to install.")
    }

    func testOncePerBundledRevision() {
        notifier.check(DriverFiles(installed: old, bundled: new))
        notifier.check(DriverFiles(installed: old, bundled: new))
        XCTAssertEqual(posted.count, 1)
        notifier.check(DriverFiles(installed: old, bundled: DriverBuild(version: "2026.11.01", revision: 19)))
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(RevisionMarker(url: dir.appendingPathComponent(DriverUpdate.notifiedName)).read(), 19)
    }

    func testNothingForAnAbsentCurrentOrNewerDriver() {
        notifier.check(DriverFiles(installed: nil, bundled: new))
        notifier.check(DriverFiles(installed: new, bundled: new))
        notifier.check(DriverFiles(installed: DriverBuild(version: "dev", revision: 30), bundled: new))
        notifier.check(DriverFiles(installed: old, bundled: nil))
        XCTAssertTrue(posted.isEmpty)
    }

    func testAMarkerItCannotWriteMeansNoNotification() throws {
        try Data().write(to: dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent))
        notifier.check(DriverFiles(installed: old, bundled: new))
        XCTAssertTrue(posted.isEmpty)
    }

    func testOnlyTheBodyClickInstalls() {
        XCTAssertTrue(DriverUpdateNotice.isInstallClick(category: "driver-update", action: UNNotificationDefaultActionIdentifier))
        XCTAssertFalse(DriverUpdateNotice.isInstallClick(category: "driver-update", action: UNNotificationDismissActionIdentifier))
        XCTAssertFalse(DriverUpdateNotice.isInstallClick(category: "other", action: UNNotificationDefaultActionIdentifier))
    }

    func testTheResult() {
        XCTAssertEqual(DriverUpdateNotice.result(status: 0, output: "updated …").title, "EQ driver updated")
        XCTAssertEqual(DriverUpdateNotice.result(status: 1, output: "driver: about to update\nerror: mode: cannot install the EQ driver: cancelled at the password prompt\n"),
                       DriverUpdateNotice(title: "EQ driver not updated",
                                          body: "error: mode: cannot install the EQ driver: cancelled at the password prompt — run eq mode driver in a terminal."))
        XCTAssertEqual(DriverUpdateNotice.result(status: 1, output: "").body, "eq mode driver exited with status 1 — run eq mode driver in a terminal.")
    }

    func testOnlyALaunchServicesStartWaitsForAClick() {
        XCTAssertTrue(UserNotices.launchedForClick(arguments: [], parent: 1, stdinIsTTY: false, inApp: true))
        XCTAssertFalse(UserNotices.launchedForClick(arguments: [], parent: 1, stdinIsTTY: false, inApp: false))
        XCTAssertFalse(UserNotices.launchedForClick(arguments: [], parent: 4242, stdinIsTTY: false, inApp: true))
        XCTAssertFalse(UserNotices.launchedForClick(arguments: [], parent: 1, stdinIsTTY: true, inApp: true))
        XCTAssertFalse(UserNotices.launchedForClick(arguments: ["daemon"], parent: 1, stdinIsTTY: false, inApp: true))
        XCTAssertFalse(UserNotices.available, "a test runs outside EQ.app and can never post")
    }
}
