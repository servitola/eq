import XCTest
@testable import eq

/// The one terminal offer to update an outdated driver, against fakes: the answers are scripted and the
/// privileged step only records what it was asked.
final class DriverUpdatePromptTests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!
    private var driver: FakeDriver!
    private var system: FakeAudioSystem!
    private var journal: Journal!
    private var files = DriverFiles()
    private var interactive = true
    private var environment: [String: String] = [:]
    private var answers: [String?] = []
    private var questions: [String] = []
    private var warnings: [String] = []

    private let old = DriverBuild(version: "2026.09.29", revision: 14, protocolVersion: 1)
    private let new = DriverBuild(version: "2026.10.05", revision: 18, protocolVersion: 2)
    private let source = URL(fileURLWithPath: "/Applications/EQ.app/Contents/PlugIns/EQDriver.driver")

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        journal = Journal()
        driver = FakeDriver()
        driver.journal = journal
        driver.names = ["BT-RCA": "BE-RCA", "BUILTIN": "MacBook Pro Speakers"]
        system = FakeAudioSystem()
        system.journal = journal
        files = DriverFiles(installed: old, bundled: new, bundledURL: source)
        interactive = true
        environment = [:]
        answers = []
        questions = []
        warnings = []
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-RCA", "BE-RCA", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache/autoeq"),
            today: { "2026-10-09" })
        context.warn = { [unowned self] in self.warnings.append($0) }
        context.driver = { [unowned self] in self.driver }
        context.audioSystem = system
        context.modeDeadline = 0.5
        context.modeWait = { _ in }
        context.driverSerial = { 7 }
        context.driverAppearDeadline = 0.2
        context.driverFiles = { [unowned self] in self.files }
        context.driverElevation = { .sudo }
        context.privileged = { [unowned self] action, elevation in
            self.journal.add("privileged \(action == .uninstall ? "uninstall" : "install") \(elevation.rawValue)")
            if case .install = action { self.files.installed = self.files.bundled }
        }
        context.driverPrompt = CLI.DriverPrompt(
            interactive: { [unowned self] in self.interactive },
            environment: environment,
            ask: { [unowned self] question in
                self.questions.append(question)
                return self.answers.isEmpty ? nil : self.answers.removeFirst()
            })
        try saveMode(.driver)
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func saveMode(_ mode: AudioMode) throws {
        var config = Config.initial(builtInUID: "BUILTIN", builtInName: "MacBook Pro Speakers")
        config.mode = mode
        try context.store.save(config)
    }

    @discardableResult
    private func run(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private var installs: [String] { journal.all.filter { $0.hasPrefix("privileged") } }
    private var declined: Int? { RevisionMarker(url: dir.appendingPathComponent("cache/\(DriverUpdate.declinedName)")).read() }

    func testTheChangesBetweenTwoRevisions() {
        XCTAssertEqual(DriverUpdate.summary(from: 14, to: 18), "spectrum analyser, true silence for silent outputs")
        XCTAssertEqual(DriverUpdate.summary(from: 17, to: 18), "true silence for silent outputs")
        XCTAssertEqual(DriverUpdate.summary(from: 14, to: 16), nil)
        XCTAssertEqual(DriverUpdate.summary(from: 18, to: 18), nil)
    }

    func testTheQuestion() {
        XCTAssertEqual(CLI.driverPromptQuestion(from: old, to: new, paint: false),
                       "A newer EQ driver is in this eq (build 14 → 18): spectrum analyser, true silence for silent outputs.\n"
                       + "Update it now? sudo asks for your password; sound drops for about a second. [y/N] ")
        XCTAssertTrue(CLI.driverPromptQuestion(from: old, to: DriverBuild(version: "x", revision: 16), paint: false)
            .hasPrefix("A newer EQ driver is in this eq (build 14 → 16).\n"))
    }

    func testWhichCommandsMayAsk() {
        XCTAssertTrue(CLI.driverPromptApplies(to: [], environment: [:]))
        XCTAssertTrue(CLI.driverPromptApplies(to: ["tui"], environment: [:]))
        XCTAssertTrue(CLI.driverPromptApplies(to: ["status"], environment: ["EQ_NO_DRIVER_PROMPT": "0"]))
        XCTAssertTrue(CLI.driverPromptApplies(to: ["driver", "status"], environment: [:]))
        for args in [["__complete", "set"], ["completions", "zsh"], ["man"], ["help"], ["set", "--help"], ["mode", "driver"],
                     ["mode"], ["daemon"], ["driver", "uninstall"]] {
            XCTAssertFalse(CLI.driverPromptApplies(to: args, environment: [:]), "\(args)")
        }
        XCTAssertFalse(CLI.driverPromptApplies(to: ["status"], environment: ["EQ_NO_DRIVER_PROMPT": "1"]))
    }

    func testYesInstallsThenRunsTheCommand() throws {
        answers = ["y"]
        let shown = run("show")
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(installs, ["privileged install sudo"])
        XCTAssertTrue(warnings.contains { $0.hasPrefix("updated the EQ driver from build 14 (2026.09.29) to build 18 (2026.10.05)") }, "\(warnings)")
        XCTAssertFalse(shown.output.contains("updated the EQ driver"), shown.output)
        run("show")
        XCTAssertEqual(questions.count, 1, "an up-to-date driver asks nothing")
        XCTAssertNil(declined)
    }

    /// Seen live: the EQ device was the default, coreaudiod brought it back at once, and the Bluetooth
    /// speaker it plays on only reconnected seconds later.
    private func updateWhileTheSpeakerReconnects(after seconds: TimeInterval?) {
        driver.state["target"] = "BT-RCA"
        driver.state["targetName"] = "BE-RCA"
        system.current = DriverControl.deviceUID
        var clock: TimeInterval = 0
        context.modeWait = { [unowned self] in
            clock += $0
            if let seconds, clock >= seconds, !self.system.devices.contains(FakeAudioSystem.speaker) {
                self.system.devices.append(FakeAudioSystem.speaker)
            }
        }
        let install = context.privileged
        context.privileged = { [unowned self] action, elevation in
            try install(action, elevation)
            self.system.devices.removeAll { $0 == FakeAudioSystem.speaker }
            clock = 0
        }
        answers = ["y"]
        run("show")
    }

    func testAnUpdateWaitsForTheTargetToReconnect() throws {
        updateWhileTheSpeakerReconnects(after: 3)
        XCTAssertEqual(installs, ["privileged install sudo"])
        XCTAssertFalse(warnings.contains { $0.contains("error:") }, "\(warnings)")
        XCTAssertTrue(warnings.contains { $0.contains("BE-RCA · EQ is the default output, playing on BE-RCA") }, "\(warnings)")
        XCTAssertEqual(system.current, DriverControl.deviceUID)
        XCTAssertEqual(driver.state["target"] as? String, "BT-RCA")
        XCTAssertEqual(try context.store.load().mode, .driver)
    }

    func testATargetThatNeverReconnectsIsNamed() {
        updateWhileTheSpeakerReconnects(after: nil)
        XCTAssertEqual(warnings.last, "error: mode: cannot switch to driver: BE-RCA, the output the EQ device plays on, is not connected — "
                       + "connect it or pick another output in the Sound menu, then run eq mode driver again")
        XCTAssertEqual(driver.state["target"] as? String, "BT-RCA", "nothing repointed to a device the user did not pick")
    }

    func testNoIsRememberedForThatRevisionOnly() throws {
        answers = [""]
        run("show")
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(declined, 18)
        XCTAssertTrue(installs.isEmpty)
        run("show")
        XCTAssertEqual(questions.count, 1)
        files.bundled = DriverBuild(version: "2026.11.01", revision: 19, protocolVersion: 2)
        answers = ["n"]
        run("show")
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(declined, 19)
    }

    func testTheEndOfInputCountsAsNo() {
        run("show")
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(declined, 18)
    }

    func testAFailedInstallStillRunsTheCommandAndAsksAgain() {
        answers = ["yes"]
        context.privileged = { _, _ in throw DriverInstall.Failure.cancelled }
        let result = run("show")
        XCTAssertEqual(warnings.last, "error: mode: cannot install the EQ driver: cancelled at the password prompt")
        XCTAssertFalse(result.isError, result.output)
        XCTAssertNil(declined)
        run("show")
        XCTAssertEqual(questions.count, 2)
    }

    func testNothingAsksOutsideAnInteractiveDriverModeWithAnOlderDriver() throws {
        interactive = false
        run("show")
        interactive = true
        run("show", "--json")
        run("set", "1k=+1", "--dry-run")
        context.driverPrompt?.environment = ["EQ_NO_DRIVER_PROMPT": "1"]
        run("show")
        context.driverPrompt?.environment = [:]
        files.installed = new
        run("show")
        files.installed = nil
        run("show")
        files.installed = old
        driver.state["killed"] = true
        run("show")
        driver.state["killed"] = nil
        try saveMode(.tap)
        run("show")
        XCTAssertTrue(questions.isEmpty, "\(questions)")
        XCTAssertTrue(installs.isEmpty)
    }

    func testAnIncompatibleDriverIsOfferedTheReplacement() {
        driver.state["settingsVersion"] = nil
        run("show")
        XCTAssertEqual(questions.count, 1)
    }

    func testDoctorStillSaysSoAfterANo() {
        answers = ["n"]
        run("show")
        XCTAssertEqual(DriverFiles(installed: old, bundled: new).updateNote,
                       "the EQ driver is build 14 (2026.09.29), this eq carries build 18 (2026.10.05) — run `eq mode driver` to update it")
        var probes = DoctorProbes(
            osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0) },
            loadConfig: { Config.initial(builtInUID: nil, builtInName: nil) },
            readStatus: { nil }, defaultOutput: { nil }, launcher: { .notRegistered }, executablePath: { _ in nil },
            signalStatus: { _ in false }, sleep: { _ in }, smoke: false)
        probes.driver = { [unowned self] in self.driver }
        probes.driverFiles = { [unowned self] in self.files }
        let checks = Doctor.driverChecks(probes, mode: .driver, hidesWhileDefault: false, live: nil)
        XCTAssertTrue(checks.contains { $0.name == "driver update" && $0.warning }, "\(checks)")
    }
}
