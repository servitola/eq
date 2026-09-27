import XCTest
@testable import eq

final class CLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func runCLI(_ args: String...) -> (exitCode: Int32, output: String) {
        CLI.run(args, context: context)
    }

    func testInitWritesScreenshotCurveForBuiltIn() throws {
        let result = runCLI("init")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains(context.store.url.path))
        let config = try context.store.load()
        XCTAssertEqual(config.devices["BUILTIN"]?.bands, Config.screenshotCurve)
        XCTAssertEqual(config.devices["BUILTIN"]?.name, "MacBook Pro Speakers")
    }

    func testShowPrintsCurrentDeviceProfileAsTable() {
        _ = runCLI("init")
        let result = runCLI()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("MacBook Pro Speakers"))
        XCTAssertTrue(result.output.contains("32Hz"))
        XCTAssertTrue(result.output.contains("+4.8"))
        XCTAssertTrue(result.output.contains("-3.1"))
        XCTAssertTrue(result.output.contains("preamp"))
    }

    func testShowWithoutConfigHintsInit() {
        let result = runCLI()
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("eq init"), result.output)
    }

    func testShowPrefersDaemonDeviceWhenStatusIsFresh() throws {
        _ = runCLI("init")
        try Status(state: .running, device: .init(uid: "BT-1", name: "JBL Big", transport: "bluetooth"), sampleRate: 48000,
                   profile: .default, framesProcessed: 1, callbacks: 1, enabled: true, error: nil, pid: getpid(), updatedAt: Date())
            .write(to: context.statusURL)
        let result = runCLI()
        XCTAssertTrue(result.output.contains("JBL Big"))
        XCTAssertTrue(result.output.contains("default profile"))
    }

    func testSetOnCurrentDeviceCreatesProfileFromDefault() throws {
        _ = runCLI("init")
        try Status(state: .running, device: .init(uid: "BT-1", name: "JBL Big", transport: "bluetooth"), sampleRate: 48000,
                   profile: .default, framesProcessed: 1, callbacks: 1, enabled: true, error: nil, pid: getpid(), updatedAt: Date())
            .write(to: context.statusURL)
        let result = runCLI("set", "1khz", "-3", "64hz", "+2")
        XCTAssertEqual(result.exitCode, 0, result.output)
        let profile = try XCTUnwrap(try context.store.load().devices["BT-1"])
        XCTAssertEqual(profile.name, "JBL Big")
        XCTAssertEqual(profile.bands[5], -3)
        XCTAssertEqual(profile.bands[1], 2)
        XCTAssertEqual(profile.bands[0], Config.screenshotCurve[0])
    }

    func testSetWithDeviceSubstring() throws {
        _ = runCLI("init")
        let result = runCLI("set", "--device", "jbl", "16khz", "+1")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(try context.store.load().devices["BT-1"]?.bands[9], 1)
    }

    func testSetRejectsUnknownBandWithoutWriting() throws {
        _ = runCLI("init")
        let before = try context.store.load()
        let result = runCLI("set", "77hz", "+1")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("unknown band"))
        XCTAssertEqual(try context.store.load(), before)
    }

    func testAmbiguousAndMissingDevice() {
        _ = runCLI("init")
        context.connectedDevices = { [("A", "Speakers One", "usb"), ("B", "Speakers Two", "usb")] }
        XCTAssertTrue(runCLI("set", "--device", "speakers", "1khz", "0").output.contains("matches several"))
        XCTAssertTrue(runCLI("set", "--device", "nothing", "1khz", "0").output.contains("no device or profile"))
    }

    func testPreampFlatAndCopy() throws {
        _ = runCLI("init")
        XCTAssertEqual(runCLI("preamp", "-1.5").exitCode, 0)
        XCTAssertEqual(try context.store.load().devices["BUILTIN"]?.preamp, -1.5)
        XCTAssertEqual(runCLI("copy", "--to", "JBL").exitCode, 0)
        XCTAssertEqual(try context.store.load().devices["BT-1"]?.preamp, -1.5)
        XCTAssertEqual(try context.store.load().devices["BT-1"]?.name, "JBL Big")
        XCTAssertEqual(runCLI("flat").exitCode, 0)
        XCTAssertEqual(try context.store.load().devices["BUILTIN"], Profile(name: "MacBook Pro Speakers", preamp: 0, bands: Profile.flat.bands))
        XCTAssertEqual(try context.store.load().devices["BT-1"]?.preamp, -1.5)
    }

    func testOnOffToggleEnabled() throws {
        _ = runCLI("init")
        XCTAssertEqual(runCLI("off").exitCode, 0)
        XCTAssertFalse(try context.store.load().enabled)
        XCTAssertEqual(runCLI("on").exitCode, 0)
        XCTAssertTrue(try context.store.load().enabled)
    }

    func testDevicesListsConnectedAndProfiles() throws {
        _ = runCLI("init")
        _ = runCLI("set", "--device", "jbl", "1khz", "0")
        context.connectedDevices = { [("BUILTIN", "MacBook Pro Speakers", "builtin")] }
        let out = runCLI("devices").output
        XCTAssertTrue(out.contains("MacBook Pro Speakers"))
        XCTAssertTrue(out.contains("JBL Big"))
        XCTAssertTrue(out.contains("disconnected"))
        XCTAssertTrue(out.contains("* "))
    }

    func testStatusWhenDaemonMissingAndWhenNoPermission() throws {
        var result = runCLI("status")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("not running"))
        try Status(state: .noPermission, device: nil, sampleRate: 0, profile: nil, framesProcessed: 0, callbacks: 0, enabled: true,
                   error: "Couldn’t create audio tap (error 1852797029).", pid: getpid(), updatedAt: Date())
            .write(to: context.statusURL)
        result = runCLI("status")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Screen & System Audio Recording"))
        XCTAssertTrue(runCLI("status", "--json").output.contains("\"no-permission\""))
    }

    func testUnknownCommandShowsUsage() {
        let result = runCLI("bogus")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("eq set"))
    }

    private func json(_ args: String...) throws -> [String: Any] {
        let result = CLI.run(args + ["--json"], context: context)
        let data = Data(result.output.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], result.output)
    }

    func testJSONShow() throws {
        _ = runCLI("init")
        let j = try json()
        XCTAssertEqual((j["device"] as? [String: Any])?["name"] as? String, "MacBook Pro Speakers")
        XCTAssertEqual(j["source"] as? String, "device")
        let profile = try XCTUnwrap(j["profile"] as? [String: Any])
        XCTAssertEqual((profile["bands"] as? [Double])?.count, 10)
        XCTAssertEqual((profile["filters"] as? [Any])?.count, 0)
    }

    func testJSONSetDevicesToggleInitStatusHelp() throws {
        var j = try json("init")
        XCTAssertEqual(j["created"] as? Bool, true)
        XCTAssertEqual(j["path"] as? String, context.store.url.path)
        j = try json("set", "1khz", "-3")
        XCTAssertEqual(((j["profile"] as? [String: Any])?["bands"] as? [Double])?[5], -3)
        j = try json("devices")
        XCTAssertEqual(j["current"] as? String, "BUILTIN")
        let devices = try XCTUnwrap(j["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first { $0["uid"] as? String == "BUILTIN" }?["profile"] as? String, "own")
        j = try json("off")
        XCTAssertEqual(j["enabled"] as? Bool, false)
        j = try json("help")
        XCTAssertTrue((j["usage"] as? String ?? "").contains("eq set"))
        try Status(state: .running, device: .init(uid: "BUILTIN", name: "MacBook Pro Speakers", transport: "builtin"), sampleRate: 48000,
                   profile: .device, framesProcessed: 1, callbacks: 2, enabled: true, error: nil, pid: getpid(), updatedAt: Date())
            .write(to: context.statusURL)
        j = try json("status")
        XCTAssertEqual(j["state"] as? String, "running")
        XCTAssertEqual(j["callbacks"] as? Int, 2)
    }

    func testJSONErrorKeepsExitCode() throws {
        _ = runCLI("init")
        let result = CLI.run(["set", "77hz", "+1", "--json"], context: context)
        XCTAssertEqual(result.exitCode, 2)
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let error = try XCTUnwrap(j["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "unknownBand")
        XCTAssertTrue((error["message"] as? String ?? "").contains("77hz"))
        let missing = CLI.run(["status", "--json"], context: context)
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(missing.output.contains("\"daemonNotRunning\""))
    }
}
