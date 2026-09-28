import XCTest
@testable import eq

/// A Mac that has never run `eq init`: no config directory at all.
final class FreshInstallTests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-fresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("config/eq/eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-28" })
        context.doctorProbes = {
            DoctorProbes(
                osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0) },
                loadConfig: { try self.context.store.loadOrDefault { nil } },
                configFileExists: self.context.store.exists,
                readStatus: { nil },
                defaultOutput: { DefaultOutput(name: "Speakers", streams: 1, channels: 2) },
                launcher: { .bundled(loaded: true) },
                executablePath: { _ in nil },
                signalStatus: { _ in true },
                sleep: { _ in },
                smoke: false)
        }
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func run(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private var configDirectoryExists: Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("config").path)
    }

    func testReadOnlyCommandsUseTheDefaultsAndWriteNothing() {
        let commands: [[String]] = [
            [], ["show"], ["device", "list"], ["preset", "list"], ["preset", "show", "flat"], ["filter", "list"],
            ["history"], ["export"], ["zones"], ["boost"], ["__complete", "presets"], ["__complete", "devices"],
        ]
        for args in commands {
            let result = CLI.run(args, context: context)
            XCTAssertEqual(result.exitCode, 0, "eq \(args.joined(separator: " ")): \(result.output)")
            XCTAssertFalse(result.output.contains("eq init"), "eq \(args.joined(separator: " ")): \(result.output)")
        }
        XCTAssertFalse(configDirectoryExists)
    }

    func testShowIsTheCurveInitWouldWrite() {
        let result = CLI.run([], context: context)
        XCTAssertTrue(result.output.contains("MacBook Pro Speakers (own profile)"), result.output)
        XCTAssertTrue(result.output.contains("+4.8"), result.output)
    }

    /// The cask cannot start the daemon (its install steps cannot launch the app), so the first
    /// `eq` after `brew install` registers the login item and still prints the curve.
    func testTheFirstEqStartsTheDaemonAndStillShowsTheCurve() {
        let agent = FakeAgent()
        var warnings: [String] = []
        context.agent = agent
        context.checksDaemon = true
        context.warn = { warnings.append($0) }
        let result = CLI.run([], context: context)
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(agent.calls, ["register"])
        XCTAssertEqual(warnings, ["started the eq daemon (login item \"EQ\") — allow System Audio Recording when macOS asks"])
        XCTAssertTrue(result.output.contains("MacBook Pro Speakers (own profile)"), result.output)
        XCTAssertTrue(result.output.contains("+4.8"), result.output)
        XCTAssertFalse(configDirectoryExists)
    }

    func testPresetCompletionOffersTheSeededPresets() {
        XCTAssertTrue(run("__complete", "presets").output.split(separator: "\n").contains("flat"))
    }

    func testDoctorCallsTheDefaultsHealthy() {
        let result = run("doctor")
        XCTAssertTrue(result.output.contains("✓ config — defaults (no file yet)"), result.output)
        XCTAssertFalse(configDirectoryExists)
    }

    func testHistorySaysThereIsNone() throws {
        let result = run("history")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("no history yet"), result.output)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run("history", "--json").output.utf8)) as? [String: Any])
        XCTAssertEqual((json["entries"] as? [Any])?.count, 0)
    }

    func testUndoAndRedoHaveNothingToStepTo() {
        XCTAssertTrue(run("undo").output.contains("nothing to undo"))
        XCTAssertTrue(run("redo").output.contains("nothing to redo"))
        XCTAssertFalse(configDirectoryExists)
    }

    func testFirstChangeWritesTheDefaultsWithTheChange() throws {
        let result = run("set", "1khz", "-3")
        XCTAssertEqual(result.exitCode, 0, result.output)
        let config = try context.store.load()
        XCTAssertEqual(config.devices["BUILTIN"]?.bands[5], -3)
        XCTAssertEqual(config.devices["BUILTIN"]?.bands[0], Config.screenshotCurve[0])
        XCTAssertEqual(config.presets, Config.initial(builtInUID: nil, builtInName: nil).presets)
        XCTAssertTrue(context.store.backups().isEmpty, "the first save has no previous version to back up")
    }

    func testOffWritesTheFile() throws {
        XCTAssertEqual(run("off").exitCode, 0)
        XCTAssertEqual(try context.store.load().enabled, false)
    }

    func testAChangeThatLeavesTheDefaultsWritesNothing() {
        XCTAssertEqual(run("on").exitCode, 0)
        XCTAssertFalse(configDirectoryExists)
    }

    func testInitStillWritesExplicitly() {
        XCTAssertTrue(run("init").output.contains("wrote"))
        XCTAssertTrue(context.store.exists())
    }

    func testDryRunComparesAgainstTheDefaultsAndWritesNothing() throws {
        let result = run("set", "1khz", "-3", "--dry-run")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("before"), result.output)
        XCTAssertTrue(result.output.contains("after"), result.output)
        XCTAssertFalse(configDirectoryExists)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run("off", "--dry-run", "--json").output.utf8)) as? [String: Any])
        XCTAssertEqual((json["before"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual((json["after"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertFalse(configDirectoryExists)
    }

    func testDryRunOfInitSaysItWouldWriteTheDefaults() {
        let result = run("init", "--dry-run")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("would write \(context.store.url.path)"), result.output)
        XCTAssertFalse(configDirectoryExists)
    }
}
