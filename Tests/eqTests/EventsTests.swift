import XCTest
@testable import eq

final class DaemonEventTests: XCTestCase {
    private func object(_ event: DaemonEvent) throws -> [String: Any] {
        let line = try DaemonEvent.encodeLine(event, at: 1790500000.5)
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        XCTAssertEqual(line.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
    }

    func testEveryKindCarriesTimeAndName() throws {
        let events: [DaemonEvent] = [
            .device(name: "AirPods", uid: "BT-1", transport: "bluetooth", rate: 48000),
            .rate(device: "AirPods", rate: 24000),
            .profile(device: "AirPods", preset: "favourite", source: .device),
            .enabled(false),
            .solo(SoloRange(low: 300, high: 2800)),
            .daemon(state: .noPermission, version: "1", error: "no tap"),
        ]
        XCTAssertEqual(try events.map { try object($0)["event"] as? String }, ["device", "rate", "profile", "enabled", "solo", "daemon"])
        for event in events { XCTAssertEqual(try object(event)["t"] as? Double, 1790500000.5) }
    }

    func testExactLines() throws {
        func text(_ event: DaemonEvent) throws -> String {
            String(decoding: try DaemonEvent.encodeLine(event, at: 1.5), as: UTF8.self)
        }
        XCTAssertEqual(try text(.device(name: "AirPods", uid: "BT-1", transport: "bluetooth", rate: 48000)),
                       #"{"device":"AirPods","event":"device","rate":48000,"t":1.5,"transport":"bluetooth","uid":"BT-1"}"# + "\n")
        XCTAssertEqual(try text(.rate(device: "AirPods", rate: 24000)), #"{"device":"AirPods","event":"rate","rate":24000,"t":1.5}"# + "\n")
        XCTAssertEqual(try text(.profile(device: "JBL", preset: nil, source: .default)),
                       #"{"device":"JBL","event":"profile","preset":null,"source":"default","t":1.5}"# + "\n")
        XCTAssertEqual(try text(.enabled(true)), #"{"enabled":true,"event":"enabled","t":1.5}"# + "\n")
        XCTAssertEqual(try text(.solo(nil)), #"{"event":"solo","solo":null,"t":1.5}"# + "\n")
        XCTAssertEqual(try text(.solo(SoloRange(low: 40, high: 250))), #"{"event":"solo","solo":{"high":250,"low":40},"t":1.5}"# + "\n")
        XCTAssertEqual(try text(.daemon(state: .running, version: "2026.09.28", error: nil)),
                       #"{"error":null,"event":"daemon","state":"running","t":1.5,"version":"2026.09.28"}"# + "\n")
    }
}

final class EventTrackerTests: XCTestCase {
    private var published: [DaemonEvent] = []
    private var runs: [HookRun] = []
    private var scheduled: [() -> Void] = []
    private var hooks: Hooks!
    private var tracker: EventTracker!

    private let speakers = Status.Device(uid: "BUILTIN", name: "MacBook Pro Speakers", transport: "builtin")
    private let airpods = Status.Device(uid: "BT-1", name: "AirPods", transport: "bluetooth")
    private let curve = Profile(name: "MacBook Pro Speakers", preamp: 0, bands: Config.screenshotCurve, preset: "favourite")

    override func setUp() {
        published = []
        runs = []
        scheduled = []
        hooks = Hooks(schedule: { [unowned self] _, work in self.scheduled.append(work) }, run: { [unowned self] in self.runs.append($0) })
        hooks.configure(["device": "true", "preset": "true"])
        tracker = EventTracker(enabled: true, hooks: hooks) { [unowned self] in self.published.append($0) }
    }

    private func settle() {
        let due = scheduled
        scheduled = []
        due.forEach { $0() }
    }

    func testFirstApplyAnnouncesDeviceAndProfile() {
        tracker.applied(device: speakers, rate: 48000, profile: curve, source: .device)
        XCTAssertEqual(published, [
            .device(name: "MacBook Pro Speakers", uid: "BUILTIN", transport: "builtin", rate: 48000),
            .profile(device: "MacBook Pro Speakers", preset: "favourite", source: .device),
        ])
    }

    func testReapplyingTheSameStateIsSilent() {
        tracker.applied(device: speakers, rate: 48000, profile: curve, source: .device)
        published = []
        var renamed = curve
        renamed.name = "Speakers"
        tracker.applied(device: speakers, rate: 48000, profile: renamed, source: .device)
        tracker.enabled(true)
        tracker.solo(nil)
        XCTAssertEqual(published, [])
    }

    func testRateCurveEnabledAndSoloEachPublishOnce() {
        tracker.applied(device: speakers, rate: 48000, profile: curve, source: .device)
        published = []
        tracker.applied(device: speakers, rate: 44100, profile: curve, source: .device)
        var louder = curve
        louder.preamp = 2
        tracker.applied(device: speakers, rate: 44100, profile: louder, source: .device)
        tracker.enabled(false)
        tracker.enabled(false)
        tracker.solo(SoloRange(low: 300, high: 2800))
        tracker.solo(SoloRange(low: 300, high: 2800))
        tracker.solo(nil)
        XCTAssertEqual(published, [
            .rate(device: "MacBook Pro Speakers", rate: 44100),
            .profile(device: "MacBook Pro Speakers", preset: "favourite", source: .device),
            .enabled(false),
            .solo(SoloRange(low: 300, high: 2800)),
            .solo(nil),
        ])
    }

    func testStateIsPublishedOnlyWhenItChangesAndHelloIsTheCurrentOne() {
        XCTAssertEqual(tracker.current, .daemon(state: .starting, version: Build.version, error: nil))
        tracker.state(.starting, error: nil)
        tracker.state(.running, error: nil)
        tracker.state(.running, error: nil)
        tracker.state(.failed, error: "gone")
        XCTAssertEqual(published, [
            .daemon(state: .running, version: Build.version, error: nil),
            .daemon(state: .failed, version: Build.version, error: "gone"),
        ])
        XCTAssertEqual(tracker.current, .daemon(state: .failed, version: Build.version, error: "gone"))
    }

    func testABurstOfDeviceChangesRunsTheHookOnceForTheLastDevice() {
        tracker.applied(device: speakers, rate: 48000, profile: curve, source: .device)
        tracker.applied(device: airpods, rate: 24000, profile: curve, source: .device)
        tracker.applied(device: airpods, rate: 48000, profile: curve, source: .device)
        XCTAssertEqual(runs, [])
        settle()
        XCTAssertEqual(runs.filter { $0.name == "device" },
                       [HookRun(name: "device", command: "true", environment: ["EQ_DEVICE": "AirPods", "EQ_PRESET": "favourite", "EQ_RATE": "48000"])])
    }

    func testPresetHookRunsOnlyWhenThePresetChanges() {
        tracker.applied(device: speakers, rate: 48000, profile: curve, source: .device)
        settle()
        runs = []
        var edited = curve
        edited.bands[0] = 1
        tracker.applied(device: speakers, rate: 48000, profile: edited, source: .device)
        settle()
        XCTAssertEqual(runs, [])
        edited.preset = "night"
        tracker.applied(device: speakers, rate: 48000, profile: edited, source: .device)
        settle()
        XCTAssertEqual(runs, [HookRun(name: "preset", command: "true", environment: ["EQ_DEVICE": "MacBook Pro Speakers", "EQ_PRESET": "night", "EQ_RATE": "48000"])])
    }
}

final class EventsCLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!
    private var socketURL: URL { dir.appendingPathComponent("m.sock") }

    override func setUpWithError() throws {
        Paint.forced = false
        // sockaddr_un caps the path near 104 bytes; NSTemporaryDirectory is too long for that.
        dir = URL(fileURLWithPath: "/tmp/eq-events-\(getpid())-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [] },
            defaultOutput: { nil },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-28" })
        context.meterSocketURL = socketURL
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    func testWithoutADaemonExitsOne() {
        let result = CLI.run(["events"], context: context)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("not serving events"), result.output)
    }

    func testPrintsTheHelloThenEachEvent() throws {
        let queue = DispatchQueue(label: "events-cli-test")
        var frames = 0
        let server = MeterServer(socketURL: socketURL, queue: queue, tick: 0.01,
                                 source: { frames += 1; return MeterFrameTests.sample }, onClientsChanged: { _ in })
        try server.start()
        defer { queue.sync { server.stop() } }
        queue.asyncAfter(deadline: .now() + 0.1) {
            server.publish(.device(name: "AirPods", uid: "BT-1", transport: "bluetooth", rate: 48000))
            server.publish(.enabled(false))
        }
        var lines: [String] = []
        context.emit = { lines.append($0) }
        context.streamLimit = 3
        let result = CLI.run(["events", "--json"], context: context)
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(result.output, "")
        let kinds = try lines.map { try XCTUnwrap(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])["event"] as? String }
        XCTAssertEqual(kinds, ["daemon", "device", "enabled"])
        XCTAssertEqual(queue.sync { frames }, 0)
    }

    func testExitsOneWhenTheDaemonGoesAway() throws {
        let queue = DispatchQueue(label: "events-cli-eof-test")
        let server = MeterServer(socketURL: socketURL, queue: queue, tick: 0.01,
                                 source: { MeterFrameTests.sample }, onClientsChanged: { _ in })
        try server.start()
        queue.asyncAfter(deadline: .now() + 0.1) { server.stop() }
        var lines: [String] = []
        context.emit = { lines.append($0) }
        let result = CLI.run(["events"], context: context)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("daemon closed the event stream"), result.output)
        XCTAssertEqual(lines.count, 1)
    }

    /// A daemon from before events: it ignores the subscribe line and streams frames.
    func testADaemonThatPredatesEventsExitsOne() throws {
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in socketURL.path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        defer { close(listener) }
        let served = expectation(description: "served")
        DispatchQueue.global().async {
            let fd = accept(listener, nil, nil)
            if let line = try? MeterFrame.encodeLine(MeterFrameTests.sample) {
                for _ in 0..<3 { _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }
            }
            usleep(200_000)
            close(fd)
            served.fulfill()
        }
        var lines: [String] = []
        context.emit = { lines.append($0) }
        let result = CLI.run(["events"], context: context)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("not serving events"), result.output)
        XCTAssertEqual(lines, [], "a meter frame is never passed off as an event")
        wait(for: [served], timeout: 2)
    }
}
