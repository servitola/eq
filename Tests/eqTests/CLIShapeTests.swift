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

    // MARK: - --dry-run

    private func snapshot() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            files[name] = try Data(contentsOf: url) + Data("@\(date)".utf8)
        }
        return files
    }

    private func history() throws {
        run("init")
        run("set", "1khz", "-3")
        run("filter", "add", "peak", "3k", "-2")
        run("set", "2khz", "+2")
        run("undo")
    }

    func testDryRunWritesNothingForEveryStateChangingCommand() throws {
        try history()
        let file = dir.appendingPathComponent("import.txt")
        try "Preamp: -2 dB\nFilter 1: ON PK Fc 100 Hz Gain -3 dB Q 1\n".write(to: file, atomically: true, encoding: .utf8)
        let commands: [[String]] = [
            ["set", "1khz", "+5"], ["preamp", "-1"], ["flat"], ["bass", "+3"], ["treble", "-2"], ["tilt", "0.5"],
            ["boost", "voice", "+3"], ["on"], ["off"], ["copy", "--to", "JBL"], ["device", "copy", "--device", "JBL"],
            ["filter", "add", "peak", "3k", "-2"], ["filter", "set", "1", "gain=-4"], ["filter", "rm", "all"],
            ["preset", "save", "night"], ["preset", "use", "flat"], ["preset", "rm", "favourite"],
            ["preset", "rename", "favourite", "fav"], ["import", file.path], ["import", "--clear"],
            ["undo"], ["redo"], ["init"],
        ]
        for args in commands {
            let before = try snapshot()
            let result = CLI.run(args + ["--dry-run"], context: context)
            XCTAssertEqual(result.exitCode, 0, "\(args): \(result.output)")
            XCTAssertFalse(result.isError, "\(args)")
            XCTAssertEqual(try snapshot(), before, "\(args) --dry-run touched the config directory")
        }
    }

    func testDryRunShowsBeforeAndAfterInThePaintedForm() throws {
        run("init")
        let result = run("set", "1khz", "-6", "--dry-run")
        XCTAssertTrue(result.output.contains("dry run"), result.output)
        let lines = result.output.components(separatedBy: "\n")
        let before = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("before") })
        let after = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("after") })
        XCTAssertLessThan(before, after)
        XCTAssertTrue(lines[before...after].contains { $0.contains("-3.1") }, result.output)
        XCTAssertTrue(lines[after...].contains { $0.contains("-6.0") }, result.output)
        XCTAssertTrue(result.output.contains("32Hz"))
    }

    func testDryRunJSONIsBeforeAndAfter() throws {
        run("init")
        let report = try json("set", "1khz", "-6", "--dry-run")
        XCTAssertEqual(Set(report.keys), ["before", "after"])
        func bands(_ side: String) throws -> [Double] {
            let devices = try XCTUnwrap((report[side] as? [String: Any])?["devices"] as? [[String: Any]])
            return try XCTUnwrap((devices.first?["profile"] as? [String: Any])?["bands"] as? [Double])
        }
        XCTAssertEqual(try bands("before")[5], Config.screenshotCurve[5])
        XCTAssertEqual(try bands("after")[5], -6)
    }

    func testDryRunOnOffAndPresetChanges() throws {
        run("init")
        let off = run("off", "--dry-run")
        XCTAssertTrue(off.output.contains("on → off"), off.output)
        let rm = run("preset", "rm", "flat", "--dry-run")
        XCTAssertTrue(rm.output.contains("flat"), rm.output)
        XCTAssertTrue(rm.output.contains("removed"), rm.output)
        XCTAssertTrue(run("on", "--dry-run").output.contains("nothing would change"))
    }

    func testDryRunInitWithoutAConfig() throws {
        let result = run("init", "--dry-run")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertFalse(context.store.exists())
        XCTAssertTrue(result.output.contains("no config"), result.output)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testDryRunStillValidates() throws {
        run("init")
        let before = try snapshot()
        let result = run("set", "99hz", "+1", "--dry-run")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("unknown band"), result.output)
        XCTAssertEqual(try snapshot(), before)
    }

    func testDryRunOfDeviceUseSwitchesNothing() {
        run("init")
        let result = run("device", "use", "jbl", "--dry-run")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(switchedTo, [])
        XCTAssertTrue(result.output.contains("MacBook Pro Speakers → JBL Big"), result.output)
    }

    func testDryRunIsRefusedWhereNothingIsWritten() {
        run("init")
        for args in [["devices"], ["device", "list"], ["export"], ["watch"], ["status"], ["import", "--search", "hd600"], ["preset", "show", "flat"], ["history"]] {
            let result = CLI.run(args + ["--dry-run"], context: context)
            XCTAssertEqual(result.exitCode, 2, "\(args): \(result.output)")
            XCTAssertTrue(result.output.contains("--dry-run"), "\(args): \(result.output)")
        }
    }
}
