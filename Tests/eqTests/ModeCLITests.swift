import CoreAudio
import EQCore
import XCTest
@testable import eq

final class ModeCLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!
    private var driver: FakeDriver!
    private var system: FakeAudioSystem!
    private var journal: Journal!
    private var installed = true

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        journal = Journal()
        driver = FakeDriver()
        driver.journal = journal
        driver.names = ["BT-RCA": "BE-RCA", "BUILTIN": "MacBook Pro Speakers"]
        driver.state["hidden"] = true
        system = FakeAudioSystem()
        system.journal = journal
        installed = true
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-RCA", "BE-RCA", "bluetooth")] },
            defaultOutput: { [unowned self] in self.system.defaultOutput().map { ($0.uid, $0.name) } },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-29" })
        context.driver = { [unowned self] in self.installed ? self.driver : nil }
        context.audioSystem = system
        context.modeDeadline = 0.5
        context.modeWait = { _ in }
        context.driverSerial = { 7 }
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private func savedMode() throws -> AudioMode? { try context.store.load().mode }

    func testShowsTheMode() {
        XCTAssertEqual(run("mode").output, "mode: tap\ndriver: installed, protocol 1, plays on MacBook Pro Speakers, hidden")
        installed = false
        XCTAssertEqual(run("mode").output, "mode: tap\ndriver: not installed")
        let json = run("mode", "--json").output
        XCTAssertTrue(json.contains("\"mode\" : \"tap\""), json)
        XCTAssertTrue(json.contains("\"installed\" : false"), json)
        XCTAssertEqual(run("mode", "sideways").exitCode, 2)
    }

    func testDriverRefusedWithoutTheDevice() throws {
        installed = false
        let result = run("mode", "driver")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("not installed"), result.output)
        XCTAssertTrue(result.output.contains("sudo Driver/dev-install.sh"), result.output)
        XCTAssertFalse(context.store.exists())
        XCTAssertEqual(journal.all, [])
    }

    func testDriverRefusedWhenTooOld() {
        driver.state["settingsVersion"] = nil
        let result = run("mode", "driver")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("settings protocol 0, this eq needs 1"), result.output)
        XCTAssertEqual(journal.all, [])
        let json = run("mode", "driver", "--json").output
        XCTAssertTrue(json.contains("\"code\" : \"mode\""), json)
    }

    func testSwitchingToDriver() throws {
        XCTAssertEqual(run("set", "--device", "BE-RCA", "1khz", "+4").exitCode, 0)
        let result = run("mode", "driver")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(result.output, """
        mode: tap → driver
        BE-RCA · EQ is the default output, playing on BE-RCA with its own profile
        note: the daemon is not running: the EQ device plays, but picking another output in the Sound menu bypasses eq until it runs
        """)
        XCTAssertEqual(journal.all, ["hidden false", "target BT-RCA", "push BT-RCA", "default \(DriverControl.deviceUID)"])
        XCTAssertEqual(try savedMode(), .driver)
        let profile = try XCTUnwrap(try context.store.load().devices["BT-RCA"])
        XCTAssertEqual(driver.written, [DriverControl.record(EQProcessor.settings(profile: profile, enabled: true), targetUID: "BT-RCA", serial: 7)])
        XCTAssertEqual(run("mode").output, "mode: driver — daemon not running\ndriver: installed, protocol 1, plays on BE-RCA")
    }

    /// With the EQ device already default, `eq show` edits and shows the curve of the device it plays on.
    func testTheCurrentDeviceIsTheTargetNotTheEQDevice() throws {
        XCTAssertEqual(run("mode", "driver").exitCode, 0)
        XCTAssertEqual(system.current, DriverControl.deviceUID)
        XCTAssertTrue(run("show").output.hasPrefix("BE-RCA (default profile)"), run("show").output)
        XCTAssertEqual(run("mode", "driver").exitCode, 0)
        XCTAssertEqual(driver.pushedUIDs, ["BT-RCA", "BT-RCA"])
    }

    func testAnUnsignedEqCannotSwitchAlone() throws {
        driver.refuses = true
        let result = run("mode", "driver")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("signed EQ.app"), result.output)
        XCTAssertFalse(context.store.exists())
        XCTAssertNotEqual(system.current, DriverControl.deviceUID)
    }

    func testDryRunChangesNothing() throws {
        let result = run("mode", "driver", "--dry-run")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(result.output, """
        dry run: nothing changed
        mode tap → driver
        would show BE-RCA · EQ, point it at BE-RCA, send it the default profile and make it the default output
        """)
        XCTAssertEqual(journal.all, [])
        XCTAssertFalse(context.store.exists())
        XCTAssertEqual(run("mode", "tap", "--dry-run").exitCode, 0)
        XCTAssertEqual(journal.all, [])
        XCTAssertEqual(run("mode", "--dry-run").exitCode, 2)
        installed = false
        XCTAssertEqual(run("mode", "driver", "--dry-run").exitCode, 1)
    }

    /// The escape hatch: the mode saved first, the default output back on the real device, then the EQ device hidden.
    func testSwitchingBackToTap() throws {
        XCTAssertEqual(run("mode", "driver").exitCode, 0)
        journal.clear()
        let result = run("mode", "tap")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(result.output, "mode: driver → tap\nthe default output is BE-RCA; the EQ device is hidden")
        XCTAssertEqual(journal.all, ["default BT-RCA", "hidden true"])
        XCTAssertEqual(try savedMode(), .tap)
    }

    func testTapRestoresSoundPastAWedgedDriver() throws {
        XCTAssertEqual(run("mode", "driver").exitCode, 0)
        driver.hangs = 1
        context.modeDeadline = 0.1
        let result = run("mode", "tap")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(system.current, "BUILTIN")
        XCTAssertTrue(result.output.contains("the default output is MacBook Pro Speakers"), result.output)
        XCTAssertTrue(result.output.contains("did not answer"), result.output)
        XCTAssertEqual(try savedMode(), .tap)
    }

    func testTapSaysHowToRecoverWhenTheDefaultWillNotMove() throws {
        XCTAssertEqual(run("mode", "driver").exitCode, 0)
        system.refuses = ["BT-RCA", "BUILTIN", "USB-DAC"]
        let result = run("mode", "tap")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("sound may be gone"), result.output)
        XCTAssertTrue(result.output.contains("sudo killall coreaudiod"), result.output)
        XCTAssertEqual(try savedMode(), .tap)
    }

    func testTapStillRestoresSoundWithABrokenConfig() throws {
        XCTAssertEqual(run("mode", "driver").exitCode, 0)
        try Data("{".utf8).write(to: context.store.url)
        let result = run("mode", "tap")
        XCTAssertEqual(system.current, "BT-RCA")
        XCTAssertTrue(result.output.contains("the config is unreadable"), result.output)
    }

    private func driverStatus(isDefault: Bool = true) -> Status {
        Status(state: .running, device: .init(uid: "BT-RCA", name: "BE-RCA", transport: "bluetooth"), sampleRate: 48000,
               profile: .device, framesProcessed: 0, callbacks: 0, writes: 1, enabled: true, error: nil, pid: getpid(),
               version: Build.version, updatedAt: Date(), latencyMs: 152.4, warnings: [], mode: .driver,
               driver: .init(deviceName: "BE-RCA · EQ", target: .init(uid: "BT-RCA", name: "BE-RCA", transport: "bluetooth"),
                             isDefault: isDefault, ioRunning: true, eqActive: true, underruns: 0, overruns: 2, clockPpm: -12.34,
                             latencyMs: 152.4, hidden: false))
    }

    func testStatusInDriverMode() throws {
        try driverStatus().write(to: context.statusURL)
        XCTAssertEqual(run("status").output, """
        state: running
        mode: driver (BE-RCA · EQ → BE-RCA)
        device: BE-RCA [bluetooth] 48000 Hz, latency 152 ms (reported to players), device profile
        driver: IO running, EQ active, 0 underruns, 2 overruns, clock -12.3 ppm
        enabled: true  pid: \(getpid())  version: \(Build.version)
        """)
        try driverStatus(isDefault: false).write(to: context.statusURL)
        XCTAssertTrue(run("status").output.contains("\nwarning: BE-RCA · EQ is not the default output\n"), run("status").output)
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.mode = .driver
        try context.store.save(config)
        XCTAssertEqual(run("mode").output.split(separator: "\n").first, "mode: driver (BE-RCA · EQ → BE-RCA)")
        let back = try XCTUnwrap(Status.read(from: context.statusURL))
        XCTAssertEqual(back.mode, .driver)
        XCTAssertEqual(back.driver?.overruns, 2)
    }

    func testModeSaysWhenTheDaemonFellBackToTheTap() throws {
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.mode = .driver
        try context.store.save(config)
        var status = driverStatus()
        status.mode = .tap
        status.driver = nil
        status.warnings = ["driver mode: the EQ device is missing — the tap plays instead"]
        try status.write(to: context.statusURL)
        XCTAssertEqual(run("mode").output.split(separator: "\n").first,
                       "mode: driver — the daemon runs the tap: the EQ device is missing — the tap plays instead")
    }

    func testAnOldStatusHasNoMode() throws {
        let old = #"{"state":"running","sampleRate":48000,"framesProcessed":1,"enabled":true,"pid":1,"updatedAt":"2026-09-28T10:00:00Z"}"#
        let status = try JSONDecoder.iso8601.decode(Status.self, from: Data(old.utf8))
        XCTAssertNil(status.mode)
        XCTAssertNil(status.driver)
    }

    func testHelpListsMode() {
        XCTAssertTrue(run("help").output.contains("eq mode driver|tap"))
        XCTAssertEqual(CommandHelp.form(matching: ["mode", "driver"])?.writes, true)
        XCTAssertEqual(CommandHelp.form(matching: ["mode"])?.writes, false)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
