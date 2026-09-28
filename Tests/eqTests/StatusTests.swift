import XCTest
@testable import eq

final class StatusTests: XCTestCase {
    private func sample(pid: Int32 = getpid(), at date: Date = Date()) -> Status {
        Status(state: .running, device: .init(uid: "u", name: "JBL", transport: "bluetooth"), sampleRate: 48000,
               profile: .device, framesProcessed: 42, callbacks: 7, writes: 1, enabled: true, error: nil, pid: pid,
               version: "2026.09.27.1", updatedAt: date)
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
        XCTAssertFalse(sample(at: now.addingTimeInterval(-91)).isFresh(now: now))
        XCTAssertTrue(sample(pid: getpid(), at: now).isAlive(now: now))
        XCTAssertFalse(sample(pid: 2_000_000_000, at: now).isAlive(now: now))
        XCTAssertFalse(sample(pid: getpid(), at: now.addingTimeInterval(-91)).isAlive(now: now))
    }

    func testFreshnessDefaultIsNinetySeconds() {
        let now = Date()
        XCTAssertTrue(sample(at: now.addingTimeInterval(-60)).isFresh(now: now))
        XCTAssertFalse(sample(at: now.addingTimeInterval(-91)).isFresh(now: now))
    }

    func testV1StatusWithoutCallbacksDecodes() throws {
        let json = """
        {"enabled":true,"framesProcessed":1,"pid":1,"sampleRate":48000,"state":"running","updatedAt":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eq-v1-\(UUID().uuidString).json")
        try json.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(Status.read(from: url)?.callbacks, 0)
    }

    func testV2StatusWithoutVersionDecodesNil() throws {
        let json = """
        {"enabled":true,"framesProcessed":1,"callbacks":3,"pid":1,"sampleRate":48000,"state":"running","updatedAt":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eq-v2-\(UUID().uuidString).json")
        try json.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(Status.read(from: url)?.version)
    }

    func testStatusWithoutLatencyOrSilenceDecodesNil() throws {
        let json = """
        {"enabled":true,"framesProcessed":1,"callbacks":3,"writes":2,"pid":1,"sampleRate":48000,"state":"running","version":"1","updatedAt":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eq-v3-\(UUID().uuidString).json")
        try json.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let status = try XCTUnwrap(Status.read(from: url))
        XCTAssertNil(status.latencyMs)
        XCTAssertNil(status.tapSilentSeconds)
        XCTAssertNil(status.addedLatencyMs)
        XCTAssertNil(status.lastOnset)
        XCTAssertNil(status.underruns)
    }

    func testLatencyAndSilenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eq-status-\(UUID().uuidString)/status.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var status = sample(at: Date(timeIntervalSince1970: 1_700_000_000))
        status.latencyMs = 11.6
        status.tapSilentSeconds = 42
        try status.write(to: url)
        XCTAssertEqual(Status.read(from: url), status)
    }

    func testAddedLatencyAndOnsetRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eq-status-\(UUID().uuidString)/status.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var status = sample(at: Date(timeIntervalSince1970: 1_700_000_000))
        status.deviceLatencyMs = 210.3
        status.addedLatencyMs = 23.2
        status.addedLatencyFrames = 1024
        status.lastOnset = Status.Onset(tapHostSeconds: 100.25, outputHostSeconds: 100.5, count: 3)
        status.underruns = 2
        status.overruns = 0
        try status.write(to: url)
        XCTAssertEqual(Status.read(from: url), status)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["addedLatencyMs"] as? Double, 23.2)
        XCTAssertEqual((json["lastOnset"] as? [String: Any])?["outputHostSeconds"] as? Double, 100.5)
    }

    func testV2StatusWithoutWritesDecodesZero() throws {
        let json = """
        {"enabled":true,"framesProcessed":1,"callbacks":3,"pid":1,"sampleRate":48000,"state":"running","updatedAt":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eq-v2w-\(UUID().uuidString).json")
        try json.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(Status.read(from: url)?.writes, 0)
    }
}
