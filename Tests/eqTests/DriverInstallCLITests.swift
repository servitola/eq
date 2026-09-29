import XCTest
@testable import eq

/// `eq mode driver` installing what EQ.app carries, and `eq driver uninstall` taking it out, against fakes:
/// the privileged step only records what it was asked.
final class DriverInstallCLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!
    private var driver: FakeDriver!
    private var system: FakeAudioSystem!
    private var journal: Journal!
    private var present = false
    private var files = DriverFiles()
    private var elevation = DriverInstall.Elevation.sudo
    private var refuse: DriverInstall.Failure?
    private var warnings: [String] = []

    private let old = DriverBuild(version: "2026.09.29", revision: 13, protocolVersion: 1)
    private let new = DriverBuild(version: "2026.10.01", revision: 14, protocolVersion: 1)
    private let source = URL(fileURLWithPath: "/Applications/EQ.app/Contents/PlugIns/EQDriver.driver")

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        journal = Journal()
        driver = FakeDriver()
        driver.journal = journal
        driver.names = ["BT-RCA": "BE-RCA", "BUILTIN": "MacBook Pro Speakers"]
        driver.state["hidden"] = true
        system = FakeAudioSystem()
        system.journal = journal
        present = false
        files = DriverFiles(installed: nil, bundled: new, bundledURL: source)
        elevation = .sudo
        refuse = nil
        warnings = []
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-RCA", "BE-RCA", "bluetooth")] },
            defaultOutput: { [unowned self] in self.system.defaultOutput().map { ($0.uid, $0.name) } },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-29" })
        context.warn = { [unowned self] in self.warnings.append($0) }
        context.driver = { [unowned self] in self.present ? self.driver : nil }
        context.audioSystem = system
        context.modeDeadline = 0.5
        context.modeWait = { _ in }
        context.driverSerial = { 7 }
        context.driverAppearDeadline = 0.2
        context.driverFiles = { [unowned self] in self.files }
        context.driverElevation = { [unowned self] in self.elevation }
        context.privileged = { [unowned self] action, elevation in
            if let refuse = self.refuse { throw refuse }
            switch action {
            case .install(let url):
                self.journal.add("install \(url.path) \(elevation.rawValue)")
                self.files.installed = self.files.bundled
                self.present = true
                self.driver.state["hidden"] = false
            case .uninstall:
                self.journal.add("uninstall \(elevation.rawValue)")
                self.files.installed = nil
                self.present = false
            }
        }
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private func savedMode() throws -> AudioMode? { try context.store.load().mode }

    // MARK: - eq mode driver

    func testTheFirstSwitchInstallsTheDriverWithOnePrompt() throws {
        let result = run("mode", "driver")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(result.output, """
        installed the EQ driver build 14 (2026.10.01) into /Library/Audio/Plug-Ins/HAL
        mode: tap → driver
        BE-RCA · EQ is the default output, playing on BE-RCA with the default profile
        note: the daemon is not running: the EQ device plays, but picking another output in the Sound menu bypasses eq until it runs
        """)
        XCTAssertEqual(journal.all, ["install \(source.path) sudo", "target BT-RCA", "push BT-RCA", "default \(DriverControl.deviceUID)"])
        XCTAssertEqual(warnings, ["driver: about to install the EQ driver build 14 (2026.10.01) into /Library/Audio/Plug-Ins/HAL — "
                                  + "sudo asks for your password in this terminal, then coreaudiod restarts and eq waits for the EQ device "
                                  + "(every app's sound drops for about a second)"])
        XCTAssertEqual(try savedMode(), .driver)
        XCTAssertEqual(run("mode", "driver").exitCode, 0)
        XCTAssertEqual(journal.all.filter { $0.hasPrefix("install") }.count, 1)
    }

    func testWithoutATerminalTheDialogAsks() throws {
        elevation = .dialog
        XCTAssertEqual(run("mode", "driver").exitCode, 0)
        XCTAssertEqual(journal.all.first, "install \(source.path) dialog")
        XCTAssertTrue(warnings[0].contains("macOS asks for an administrator password in a dialog"), warnings[0])
    }

    func testAnOlderDriverIsUpdatedAndANewerOneLeftAlone() throws {
        present = true
        files.installed = old
        let result = run("mode", "driver")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.hasPrefix("updated the EQ driver from build 13 (2026.09.29) to build 14 (2026.10.01)\n"), result.output)
        XCTAssertEqual(journal.all.first, "install \(source.path) sudo")
        journal.clear()
        files.installed = DriverBuild(version: "dev", revision: 30)
        XCTAssertEqual(run("mode", "driver").exitCode, 0)
        XCTAssertFalse(journal.all.contains { $0.hasPrefix("install") })
    }

    func testAnIncompatibleDriverIsReplaced() throws {
        present = true
        files.installed = DriverBuild(version: "2026.09.01", revision: 20)
        driver.state["settingsVersion"] = nil
        context.privileged = { [unowned self] action, _ in
            self.journal.add("\(action)")
            self.driver.state["settingsVersion"] = 1
            self.files.installed = self.new
        }
        let result = run("mode", "driver")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.hasPrefix("replaced the EQ driver, too old for this eq, with build 14 (2026.10.01)\n"), result.output)
    }

    /// The kill file is the user's own recovery step: eq never installs over it.
    func testADisabledDriverIsNotReinstalled() throws {
        present = true
        files.installed = old
        driver.state["killed"] = true
        let result = run("mode", "driver")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("kill file"), result.output)
        XCTAssertEqual(journal.all, [])
    }

    func testACancelledPromptChangesNothing() throws {
        refuse = .cancelled
        let result = run("mode", "driver")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.output, "error: mode: cannot install the EQ driver: cancelled at the password prompt")
        XCTAssertFalse(context.store.exists())
        XCTAssertEqual(journal.all, [])
    }

    func testADeviceThatNeverComesUpIsReported() throws {
        context.privileged = { _, _ in }
        let result = run("mode", "driver")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("installed the EQ driver, but its device did not come up within 0 s"), result.output)
        XCTAssertTrue(result.output.contains("run eq mode driver again"), result.output)
        XCTAssertFalse(context.store.exists())
    }

    func testDryRunSaysWhatTheInstallWouldDo() throws {
        let result = run("mode", "driver", "--dry-run")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(result.output, """
        dry run: nothing changed
        mode tap → driver
        would install the EQ driver build 14 (2026.10.01) into /Library/Audio/Plug-Ins/HAL: sudo asks for your password in this terminal, \
        then coreaudiod restarts and eq waits for the EQ device (every app's sound drops for about a second)
        would show BE-RCA · EQ, point it at BE-RCA, send it the default profile and make it the default output
        """)
        let json = run("mode", "driver", "--dry-run", "--json").output
        XCTAssertTrue(json.contains("\"action\" : \"install\""), json)
        XCTAssertTrue(json.contains("\"elevation\" : \"sudo\""), json)
        XCTAssertTrue(json.contains("\"revision\" : 14"), json)
        present = true
        files.installed = old
        XCTAssertTrue(run("mode", "driver", "--dry-run").output.contains("would update the EQ driver from build 13 (2026.09.29) to build 14 (2026.10.01)"))
        XCTAssertEqual(journal.all, [])
        XCTAssertEqual(warnings, [])
        XCTAssertFalse(context.store.exists())
    }

    func testModeShowsTheBuildAndAWaitingUpdate() {
        XCTAssertEqual(run("mode").output, "mode: tap\ndriver: not installed — eq mode driver installs build 14 (2026.10.01)")
        present = true
        files.installed = old
        XCTAssertEqual(run("mode").output, """
        mode: tap
        driver: installed, protocol 1, build 13 (2026.09.29), plays on MacBook Pro Speakers, hidden
        update: the EQ driver is build 13 (2026.09.29), this eq carries build 14 (2026.10.01) — run `eq mode driver` to update it
        """)
    }

    // MARK: - eq driver uninstall

    func testUninstallMovesTheDefaultOffFirst() throws {
        XCTAssertEqual(run("mode", "driver").exitCode, 0)
        journal.clear()
        warnings = []
        let result = run("driver", "uninstall")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(result.output, """
        mode: driver → tap
        the default output is BE-RCA; the EQ device is hidden
        removed /Library/Audio/Plug-Ins/HAL/EQDriver.driver; coreaudiod restarted
        """)
        XCTAssertEqual(journal.all, ["default BT-RCA", "hidden true", "uninstall sudo"])
        XCTAssertEqual(try savedMode(), .tap)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].hasPrefix("driver: about to remove /Library/Audio/Plug-Ins/HAL/EQDriver.driver — sudo asks"), warnings[0])
        XCTAssertEqual(run("driver", "uninstall").output, "the EQ driver is not installed")
        XCTAssertEqual(journal.all.filter { $0.hasPrefix("uninstall") }.count, 1)
    }

    func testTheCaskStepKeepsTheDriverThroughAnUpgrade() throws {
        XCTAssertEqual(run("mode", "driver").exitCode, 0)
        journal.clear()
        for command in ["upgrade", "reinstall", "install", "bundle"] {
            context.brewCommand = { command }
            let result = run("driver", "uninstall", "--cask")
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertEqual(result.output, "brew \(command) is not removing eq: the EQ driver stays installed")
        }
        context.brewCommand = { nil }
        XCTAssertEqual(run("driver", "uninstall", "--cask").output, "brew (not found) is not removing eq: the EQ driver stays installed")
        XCTAssertEqual(journal.all, [])
        XCTAssertEqual(try savedMode(), .driver)
        context.brewCommand = { "uninstall" }
        XCTAssertEqual(run("driver", "uninstall", "--cask", "--dry-run").output, """
        dry run: nothing changed
        would switch to tap mode: the default output back on a real device, the EQ device hidden
        would remove /Library/Audio/Plug-Ins/HAL/EQDriver.driver, build 14 (2026.10.01): sudo asks for your password in this terminal, \
        then coreaudiod restarts (every app's sound drops for about a second)
        """)
        XCTAssertEqual(journal.all, [])
        XCTAssertEqual(run("driver", "uninstall", "--cask").exitCode, 0)
        XCTAssertEqual(journal.all.last, "uninstall sudo")
        XCTAssertEqual(try savedMode(), .tap)
    }

    func testAFailedRemovalSaysHowByHand() throws {
        files.installed = old
        refuse = .failed("/usr/bin/sudo exited with status 1")
        let result = run("driver", "uninstall")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.output, "error: driver: cannot remove the EQ driver: /usr/bin/sudo exited with status 1 — by hand: "
                       + "sudo rm -rf /Library/Audio/Plug-Ins/HAL/EQDriver.driver && sudo killall coreaudiod")
        XCTAssertEqual(run("driver", "uninstall", "extra").exitCode, 2)
    }

    func testHelpListsUninstall() {
        XCTAssertTrue(run("help").output.contains("eq driver uninstall"))
        XCTAssertEqual(CommandHelp.form(matching: ["driver", "uninstall"])?.writes, true)
    }

    // MARK: - eq doctor

    func testDoctorSuggestsTheUpdate() {
        present = true
        files.installed = old
        var probes = DoctorProbes(
            osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0) },
            loadConfig: { Config.initial(builtInUID: nil, builtInName: nil) },
            readStatus: { nil }, defaultOutput: { nil }, launcher: { .notRegistered }, executablePath: { _ in nil },
            signalStatus: { _ in false }, sleep: { _ in }, smoke: false)
        probes.driver = { [unowned self] in self.present ? self.driver : nil }
        probes.driverFiles = { [unowned self] in self.files }
        let checks = Doctor.driverChecks(probes, mode: .tap, hidesWhileDefault: false, live: nil)
        XCTAssertEqual(checks[0].detail, "installed, protocol 1, build 13 (2026.09.29)")
        XCTAssertEqual(checks[1], DoctorCheck(name: "driver update", ok: false, detail: DriverFiles(installed: old, bundled: new).updateNote!, warning: true))
        present = false
        XCTAssertTrue(Doctor.driverChecks(probes, mode: .driver, hidesWhileDefault: false, live: nil)[0].detail
            .contains("run `eq mode driver` to install it"))
    }
}
