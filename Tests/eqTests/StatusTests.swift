import XCTest
@testable import eq

final class StatusTests: XCTestCase {
    private func sample(pid: Int32 = getpid(), at date: Date = Date()) -> Status {
        Status(state: .running, device: .init(uid: "u", name: "JBL", transport: "bluetooth"), sampleRate: 48000,
               profile: .device, framesProcessed: 42, enabled: true, error: nil, pid: pid, updatedAt: date)
    }

    func testDefaultURLHonoursOverride() {
        setenv("EQ_STATUS", "/tmp/s/status.json", 1)
        defer { unsetenv("EQ_STATUS") }
        XCTAssertEqual(Status.defaultURL.path, "/tmp/s/status.json")
        unsetenv("EQ_STATUS")
        XCTAssertTrue(Status.defaultURL.path.hasSuffix("/.cache/eq/status.json"))
    }

    func testWriteThenReadRoundTripsWithISO8601DatesAndKebabState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eq-status-\(UUID().uuidString)/status.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var status = sample(at: Date(timeIntervalSince1970: 1_700_000_000))
        status.state = .noPermission
        try status.write(to: url)
        let text = try String(contentsOf: url)
        XCTAssertTrue(text.contains("\"no-permission\""))
        XCTAssertTrue(text.contains("2023-11-14T22:13:20Z"))
        XCTAssertEqual(Status.read(from: url), status)
    }

    func testReadReturnsNilWhenMissing() {
        XCTAssertNil(Status.read(from: URL(fileURLWithPath: "/nonexistent/status.json")))
    }

    func testFreshnessAndLiveness() {
        let now = Date()
        XCTAssertTrue(sample(at: now.addingTimeInterval(-5)).isFresh(now: now))
        XCTAssertFalse(sample(at: now.addingTimeInterval(-16)).isFresh(now: now))
        XCTAssertTrue(sample(pid: getpid(), at: now).isAlive(now: now))
        XCTAssertFalse(sample(pid: 2_000_000_000, at: now).isAlive(now: now))
        XCTAssertFalse(sample(pid: getpid(), at: now.addingTimeInterval(-60)).isAlive(now: now))
    }
}
