import XCTest
@testable import eq

final class CLIShapeTests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!
    private var switchedTo: [String] = []

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-shape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        switchedTo = []
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-28" })
        context.setDefaultOutput = { [unowned self] uid in switchedTo.append(uid) }
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func run(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private func json(_ args: String...) throws -> [String: Any] {
        let result = CLI.run(args + ["--json"], context: context)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any], result.output)
    }

    // MARK: - Noun groups and their aliases

    func testDeviceListAndItsOldSpellings() {
        run("init")
        let list = run("device", "list")
        XCTAssertEqual(list.exitCode, 0, list.output)
        XCTAssertTrue(list.output.contains("JBL Big"))
        XCTAssertEqual(run("devices").output, list.output)
        XCTAssertEqual(run("device").output, list.output)
    }

    func testDeviceCopyTakesToOrDeviceAndTheOldCopy() throws {
        run("init")
        run("preamp", "-1.5")
        for args in [["copy", "--to", "JBL"], ["device", "copy", "--to", "JBL"], ["device", "copy", "--device", "JBL"], ["copy", "--device", "JBL"]] {
            try FileManager.default.removeItem(at: context.store.url)
            run("init")
            run("preamp", "-1.5")
            let result = CLI.run(args, context: context)
            XCTAssertEqual(result.exitCode, 0, "\(args): \(result.output)")
            XCTAssertEqual(try context.store.load().devices["BT-1"]?.preamp, -1.5, "\(args)")
        }
        let both = run("device", "copy", "--to", "JBL", "--device", "JBL")
        XCTAssertEqual(both.exitCode, 2, both.output)
    }

    func testDeviceUseSwitchesTheSystemOutput() throws {
        run("init")
        let result = run("device", "use", "jbl")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(switchedTo, ["BT-1"])
        XCTAssertTrue(result.output.contains("JBL Big"), result.output)
        let report = try json("device", "use", "jbl")
        XCTAssertEqual((report["device"] as? [String: Any])?["uid"] as? String, "BT-1")
    }

    func testDeviceUseRefusesADisconnectedProfile() throws {
        run("init")
        run("set", "--device", "jbl", "1khz", "0")
        context.connectedDevices = { [("BUILTIN", "MacBook Pro Speakers", "builtin")] }
        let result = run("device", "use", "jbl")
        XCTAssertEqual(result.exitCode, 1, result.output)
        XCTAssertTrue(result.output.contains("not connected"), result.output)
        XCTAssertEqual(switchedTo, [])
        XCTAssertEqual(run("device", "use").exitCode, 2)
    }

    func testPresetAndFilterListSpellings() {
        run("init")
        XCTAssertEqual(run("preset", "list").output, run("preset").output)
        XCTAssertTrue(run("preset", "list").output.contains("favourite"))
        XCTAssertEqual(run("filter", "list").output, run("filter").output)
    }

    func testOldImportAndUndoSpellingsStillParse() throws {
        run("init")
        run("set", "1khz", "-3")
        XCTAssertEqual(run("import", "--clear").exitCode, 0)
        XCTAssertEqual(run("undo", "--list").output, run("history").output)
    }

    func testNoSuchDeviceNamesTheNewListCommand() {
        run("init")
        let result = run("set", "--device", "nothing", "1khz", "0")
        XCTAssertTrue(result.output.contains("eq device list"), result.output)
    }

    func testHelpForAnOldSpellingShowsItsNewBlock() {
        let devices = run("devices", "--help").output
        XCTAssertTrue(devices.contains("eq device [list]"), devices)
        XCTAssertFalse(devices.contains("eq preamp"), devices)
        XCTAssertTrue(run("copy", "--help").output.contains("eq device copy"))
    }
}
