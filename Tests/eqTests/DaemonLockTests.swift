import Darwin
import XCTest
@testable import eq

final class DaemonLockTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-lock-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { dir.appendingPathComponent("cache/daemon.lock") }

    func testASecondDaemonFindsTheLockHeldAndWhoHoldsIt() throws {
        guard case .acquired(let fd) = DaemonLock.acquire(url) else { return XCTFail("first acquire") }
        defer { close(fd) }
        XCTAssertEqual(DaemonLock.acquire(url), .held(by: getpid()))
        XCTAssertEqual(DaemonLock.acquire(url), .held(by: getpid()), "a refused attempt leaves the holder's pid in place")
    }

    func testTheLockGoesWithItsHolder() throws {
        guard case .acquired(let fd) = DaemonLock.acquire(url) else { return XCTFail("first acquire") }
        close(fd)
        guard case .acquired(let again) = DaemonLock.acquire(url) else { return XCTFail("lock outlived its holder") }
        close(again)
    }

    func testHookChildrenDoNotInheritIt() throws {
        guard case .acquired(let fd) = DaemonLock.acquire(url) else { return XCTFail("first acquire") }
        defer { close(fd) }
        XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)
    }

    func testAnUnwritableLockIsReportedNotFatal() {
        guard case .failed = DaemonLock.acquire(URL(fileURLWithPath: "/dev/null/daemon.lock")) else { return XCTFail("expected failed") }
    }
}

final class LegacyYieldTests: XCTestCase {
    private let bundled = ["EQ_LAUNCHER": "bundled"]

    func testTheBundledDaemonYieldsToTheLegacyJobOrItsPlist() {
        let agent = FakeAgent()
        XCTAssertFalse(LaunchAgent.bundledDaemonYields(environment: bundled, agent: agent))
        agent.legacyExists = true
        XCTAssertTrue(LaunchAgent.bundledDaemonYields(environment: bundled, agent: agent))
        agent.legacyExists = false
        agent.legacyJob = LoadedJob(path: "/Users/someone/dotfiles/com.servitola.eq.plist", pid: 7)
        XCTAssertTrue(LaunchAgent.bundledDaemonYields(environment: bundled, agent: agent))
    }

    func testTheLegacyDaemonAndAHandRunOneNeverYield() {
        let agent = FakeAgent.legacyRunning()
        XCTAssertFalse(LaunchAgent.bundledDaemonYields(environment: [:], agent: agent))
    }

    func testTheBundledPlistMarksItsDaemon() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(LaunchAgent.plistName)")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let environment = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(environment["EQ_LAUNCHER"], "bundled")
        XCTAssertGreaterThanOrEqual(plist["ThrottleInterval"] as? Int ?? 0, 5)
    }

    func testARefusedDaemonWaitsBeforeLaunchdRestartsIt() {
        XCTAssertGreaterThanOrEqual(DaemonPolicy.refusedExitDelay, 30)
    }
}
