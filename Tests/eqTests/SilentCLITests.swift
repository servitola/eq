import XCTest
@testable import eq

final class SilentCLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!
    private var connected: [CLIContext.ConnectedDevice] = [("BUILTIN", "Mac Studio Speakers", "builtin"), ("USB-1", "Headphones", "usb")]

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-silent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [unowned self] in self.connected },
            defaultOutput: { ("USB-1", "Headphones") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-10-05" })
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private func json(_ args: String...) throws -> [String: Any] {
        let result = CLI.run(args + ["--json"], context: context)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any], result.output)
    }

    func testSilenceMarksTheDeviceAndUnsilenceDropsIt() throws {
        let result = run("device", "silence", "studio")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.hasPrefix("Mac Studio Speakers: silent"), result.output)
        XCTAssertEqual(try context.store.load().silent, ["BUILTIN"])
        XCTAssertNil(try context.store.load().devices["USB-1"])

        XCTAssertEqual(run("device", "silence", "Mac Studio Speakers").exitCode, 0)
        XCTAssertEqual(try context.store.load().silent, ["BUILTIN"])

        XCTAssertEqual(run("device", "unsilence", "studio").exitCode, 0)
        XCTAssertNil(try context.store.load().silent)
        XCTAssertFalse(try String(contentsOf: context.store.url, encoding: .utf8).contains("silent"))
    }

    func testAGoneSilentDeviceIsListedAndUnsilencedByItsUID() throws {
        XCTAssertEqual(run("device", "silence", "Headphones").exitCode, 0)
        connected = [("BUILTIN", "Mac Studio Speakers", "builtin")]
        let list = run("device", "list").output
        XCTAssertTrue(list.contains("USB-1  [disconnected]  default profile  silent"), list)
        XCTAssertFalse(list.split(separator: "\n").first { $0.contains("Mac Studio") }!.contains("silent"), list)
        let rows = try XCTUnwrap(try json("device", "list")["devices"] as? [[String: Any]])
        XCTAssertEqual(rows.first { $0["uid"] as? String == "USB-1" }?["silent"] as? Bool, true)
        XCTAssertEqual(rows.first { $0["uid"] as? String == "BUILTIN" }?["silent"] as? Bool, false)
        XCTAssertEqual(run("device", "unsilence", "USB-1").exitCode, 0)
        XCTAssertNil(try context.store.load().silent)
    }

    func testTheCurrentOutputSaysItIsSilent() throws {
        _ = run("device", "silence", "Headphones")
        XCTAssertTrue(run().output.hasPrefix("Headphones (default profile, silent)"), run().output)
    }

    func testJSONAndErrors() throws {
        let report = try json("device", "silence", "studio")
        XCTAssertEqual(report["silent"] as? Bool, true)
        XCTAssertEqual(report["devices"] as? [String], ["BUILTIN"])
        XCTAssertEqual((report["device"] as? [String: Any])?["uid"] as? String, "BUILTIN")
        XCTAssertEqual(run("device", "silence").exitCode, 2)
        XCTAssertEqual(run("device", "silence", "nothing-like-it").exitCode, 1)
    }

    func testDryRunWritesNothing() throws {
        _ = run("init")
        let before = try Data(contentsOf: context.store.url)
        let result = run("device", "silence", "studio", "--dry-run")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("Mac Studio Speakers: silent"), result.output)
        XCTAssertEqual(try Data(contentsOf: context.store.url), before)
        let report = try json("device", "silence", "studio", "--dry-run")
        XCTAssertEqual((report["before"] as? [String: Any])?["silent"] as? [String], [])
        XCTAssertEqual((report["after"] as? [String: Any])?["silent"] as? [String], ["BUILTIN"])
    }

    func testHelpCompletionsAndManKnowIt() throws {
        XCTAssertTrue(run("device", "--help").output.contains("silence|unsilence"))
        XCTAssertEqual(CommandHelp.form(matching: ["device", "silence", "x"])?.writes, true)
        XCTAssertTrue(Completions.subcommands(of: "device").contains("unsilence"))
        let zsh = try XCTUnwrap(try? Completions.command(["zsh"]).text)
        XCTAssertTrue(zsh.contains("silence"))
        XCTAssertTrue(try ManPage.command([]).text.contains("silence"))
    }
}
