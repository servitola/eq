import Darwin
import XCTest
@testable import eq

final class FakeAgent: LaunchAgentControl {
    var serviceStatus: AgentServiceStatus = .notRegistered
    var job: LoadedJob?
    var legacyExists = false
    var registerError: Error?
    var calls: [String] = []
    let legacyPlist = URL(fileURLWithPath: "/Users/someone/Library/LaunchAgents/com.servitola.eq.plist")
    var bundlePath: String? = "/Applications/EQ.app"

    func register() throws {
        calls.append("register")
        if let registerError { throw registerError }
        serviceStatus = .enabled
        job = LoadedJob(managedByServiceManagement: true, path: nil, pid: 42)
    }

    func unregister() throws {
        calls.append("unregister")
        serviceStatus = .notRegistered
        if job?.managedByServiceManagement == true { job = nil }
    }

    func loadedJob() -> LoadedJob? { job }

    func bootout() throws {
        calls.append("bootout")
        job = nil
    }

    func legacyPlistExists() -> Bool { legacyExists }

    func setAsideLegacyPlist() throws -> URL {
        calls.append("setAside")
        legacyExists = false
        return URL(fileURLWithPath: "/Users/someone/.Trash/com.servitola.eq.plist")
    }

    static func legacyRunning() -> FakeAgent {
        let agent = FakeAgent()
        agent.legacyExists = true
        agent.job = LoadedJob(managedByServiceManagement: false, path: agent.legacyPlist.path, pid: 7)
        return agent
    }
}

final class LaunchAgentTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    // MARK: - launchctl print

    func testParsesAServiceManagementJob() {
        let text = """
            gui/501/app.glasswings.daemon = {
            \tactive count = 1
            \tpath = (submitted by smd.324)
            \ttype = LaunchAgent
            \tstate = running
            \tprogram identifier = Contents/MacOS/Glasswings (mode: 2)
            \tpid = 1539
            \tmanaged_by = com.apple.xpc.ServiceManagement
            \tendpoints = {
            \t\t"pid" = 2
            \t\tstate = active
            \t}
            }
            """
        XCTAssertEqual(LoadedJob.parse(text), LoadedJob(managedByServiceManagement: true, path: nil, pid: 1539))
    }

    func testParsesALegacyJob() {
        let text = """
            gui/501/com.servitola.eq = {
            \tpath = /Users/someone/projects/dotfiles/launchagents/com.servitola.eq.plist
            \tstate = running
            \tprogram = /Applications/EQ.app/Contents/MacOS/eq
            \tpid = 89423
            }
            """
        XCTAssertEqual(LoadedJob.parse(text),
                       LoadedJob(managedByServiceManagement: false, path: "/Users/someone/projects/dotfiles/launchagents/com.servitola.eq.plist",
                                 pid: 89423))
    }

    func testAJobThatIsNotRunningHasNoPid() {
        XCTAssertNil(LoadedJob.parse("gui/501/com.servitola.eq = {\n\tstate = not running\n}").pid)
    }

    // MARK: - Which launcher

    func testLauncher() {
        let agent = FakeAgent()
        XCTAssertEqual(LaunchAgent.launcher(agent), .notRegistered)
        agent.serviceStatus = .notFound
        XCTAssertEqual(LaunchAgent.launcher(agent), .unavailable)
        agent.serviceStatus = .requiresApproval
        XCTAssertEqual(LaunchAgent.launcher(agent), .needsApproval)
        agent.serviceStatus = .enabled
        XCTAssertEqual(LaunchAgent.launcher(agent), .bundled(loaded: false))
        agent.job = LoadedJob(managedByServiceManagement: true, path: nil, pid: 1)
        XCTAssertEqual(LaunchAgent.launcher(agent), .bundled(loaded: true))
        let legacy = FakeAgent.legacyRunning()
        XCTAssertEqual(LaunchAgent.launcher(legacy), .legacy(path: legacy.legacyPlist.path, loaded: true))
        legacy.job = nil
        XCTAssertEqual(LaunchAgent.launcher(legacy), .legacy(path: legacy.legacyPlist.path, loaded: false))
    }

    func testSummaryPointsAtTheFix() {
        XCTAssertEqual(LaunchAgent.summary(.bundled(loaded: true)).detail, "bundled (login item \"EQ\")")
        XCTAssertTrue(LaunchAgent.summary(.bundled(loaded: true)).ok)
        let legacy = LaunchAgent.summary(.legacy(path: "/x/com.servitola.eq.plist", loaded: true))
        XCTAssertTrue(legacy.ok)
        XCTAssertTrue(legacy.detail.hasPrefix("legacy /x/com.servitola.eq.plist"), legacy.detail)
        XCTAssertTrue(legacy.detail.contains("eq agent install --replace-legacy"), legacy.detail)
        XCTAssertTrue(LaunchAgent.summary(.needsApproval).detail.contains("System Settings → General → Login Items"))
        XCTAssertFalse(LaunchAgent.summary(.needsApproval).ok)
        XCTAssertTrue(LaunchAgent.summary(.notRegistered).detail.contains("eq agent install"))
        XCTAssertFalse(LaunchAgent.summary(.legacy(path: "/x", loaded: false)).ok)
    }

    // MARK: - Starting it from any command

    func testRegistersWhenNothingRunsTheDaemon() {
        let agent = FakeAgent()
        XCTAssertEqual(LaunchAgent.ensureRunning(agent, daemonAlive: false, optedOut: false), .started)
        XCTAssertEqual(agent.calls, ["register"])
        XCTAssertNil(LaunchAgent.ensureRunning(agent, daemonAlive: false, optedOut: false), "registered already: nothing to say twice")
        XCTAssertEqual(agent.calls, ["register"])
    }

    func testLeavesARunningDaemonAlone() {
        let agent = FakeAgent()
        XCTAssertNil(LaunchAgent.ensureRunning(agent, daemonAlive: true, optedOut: false))
        XCTAssertEqual(agent.calls, [])
    }

    func testNeverStacksASecondDaemonOnTheLegacyPlist() {
        let agent = FakeAgent.legacyRunning()
        XCTAssertNil(LaunchAgent.ensureRunning(agent, daemonAlive: false, optedOut: false))
        agent.job = nil
        XCTAssertNil(LaunchAgent.ensureRunning(agent, daemonAlive: false, optedOut: false), "an unloaded legacy plist is still the user's choice")
        XCTAssertEqual(agent.calls, [])
    }

    func testWaitingForApprovalIsAHintNotARetry() {
        let agent = FakeAgent()
        agent.serviceStatus = .requiresApproval
        XCTAssertEqual(LaunchAgent.ensureRunning(agent, daemonAlive: false, optedOut: false), .needsApproval)
        XCTAssertEqual(agent.calls, [])
        XCTAssertTrue(LaunchAgent.text(.needsApproval, paint: false).contains("System Settings → General → Login Items"))
    }

    func testAFailedRegistrationIsANote() {
        let agent = FakeAgent()
        agent.registerError = NSError(domain: NSOSStatusErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        XCTAssertEqual(LaunchAgent.ensureRunning(agent, daemonAlive: false, optedOut: false), .failed("Operation not permitted (1)"))
    }

    func testRegisteredButUnloadedOrMissingIsLeftToDoctor() {
        let agent = FakeAgent()
        agent.serviceStatus = .enabled
        XCTAssertNil(LaunchAgent.ensureRunning(agent, daemonAlive: false, optedOut: false))
        agent.serviceStatus = .notFound
        XCTAssertNil(LaunchAgent.ensureRunning(agent, daemonAlive: false, optedOut: false))
        XCTAssertEqual(agent.calls, [])
    }

    func testAnOptOutKeepsItOff() {
        let agent = FakeAgent()
        XCTAssertNil(LaunchAgent.ensureRunning(agent, daemonAlive: false, optedOut: true))
        agent.serviceStatus = .requiresApproval
        XCTAssertNil(LaunchAgent.ensureRunning(agent, daemonAlive: false, optedOut: true))
        XCTAssertEqual(agent.calls, [])
    }

    func testStartedNoteNamesTheLoginItemAndThePermission() {
        let text = LaunchAgent.text(.started, paint: false)
        XCTAssertEqual(text, "started the eq daemon (login item \"EQ\") — allow System Audio Recording when macOS asks")
        XCTAssertTrue(LaunchAgent.text(.started, paint: true).hasPrefix("\u{1B}[2m"))
    }

    // MARK: - eq agent install / uninstall

    func testInstallRegisters() throws {
        let agent = FakeAgent()
        XCTAssertEqual(try LaunchAgent.install(agent, replaceLegacy: false), .started(setAside: nil))
        XCTAssertEqual(try LaunchAgent.install(agent, replaceLegacy: false), .alreadyRunning)
        XCTAssertEqual(agent.calls, ["register"])
    }

    func testInstallRefusesToStackOnTheLegacyPlistUnlessAsked() throws {
        let agent = FakeAgent.legacyRunning()
        XCTAssertThrowsError(try LaunchAgent.install(agent, replaceLegacy: false)) { error in
            XCTAssertEqual(error as? CLIError, .legacyAgent(agent.legacyPlist.path))
            XCTAssertTrue("\(error)".contains("eq agent install --replace-legacy"))
        }
        XCTAssertEqual(agent.calls, [])
    }

    func testReplaceLegacyBootsItOutAndMovesItAside() throws {
        let agent = FakeAgent.legacyRunning()
        let result = try LaunchAgent.install(agent, replaceLegacy: true)
        XCTAssertEqual(result, .started(setAside: URL(fileURLWithPath: "/Users/someone/.Trash/com.servitola.eq.plist")))
        XCTAssertEqual(agent.calls, ["bootout", "setAside", "register"])
    }

    func testAFailedReplaceSaysWhereTheLegacyPlistWentAndHowToGoBack() {
        let agent = FakeAgent.legacyRunning()
        agent.registerError = NSError(domain: NSOSStatusErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        XCTAssertThrowsError(try LaunchAgent.install(agent, replaceLegacy: true)) { error in
            XCTAssertEqual("\(error)", "launch agent: Operation not permitted (1); the legacy plist is in /Users/someone/.Trash/com.servitola.eq.plist "
                + "— to go back, Put Back in Finder, then: launchctl bootstrap gui/$UID /Users/someone/Library/LaunchAgents/com.servitola.eq.plist")
        }
        XCTAssertEqual(agent.calls, ["bootout", "setAside", "register"])
    }

    func testAFailedReplaceOfAJobLoadedFromElsewhereSaysHowToReloadIt() {
        let agent = FakeAgent()
        agent.job = LoadedJob(managedByServiceManagement: false, path: "/Users/someone/dotfiles/com.servitola.eq.plist", pid: 7)
        agent.registerError = NSError(domain: "x", code: 3, userInfo: [NSLocalizedDescriptionKey: "nope"])
        XCTAssertThrowsError(try LaunchAgent.install(agent, replaceLegacy: true)) { error in
            XCTAssertEqual("\(error)", "launch agent: nope; the legacy job was booted out "
                + "— to go back: launchctl bootstrap gui/$UID /Users/someone/dotfiles/com.servitola.eq.plist")
        }
    }

    func testInstallReloadsARegistrationLaunchdLost() throws {
        let agent = FakeAgent()
        agent.serviceStatus = .enabled
        XCTAssertEqual(try LaunchAgent.install(agent, replaceLegacy: false), .restarted(setAside: nil))
        XCTAssertEqual(agent.calls, ["unregister", "register"])
    }

    func testInstallExplainsApprovalAndAMissingPlist() {
        let agent = FakeAgent()
        agent.serviceStatus = .requiresApproval
        XCTAssertThrowsError(try LaunchAgent.install(agent, replaceLegacy: false)) { XCTAssertTrue("\($0)".contains("Login Items"), "\($0)") }
        agent.serviceStatus = .notFound
        XCTAssertThrowsError(try LaunchAgent.install(agent, replaceLegacy: false)) { XCTAssertTrue("\($0)".contains("/Applications/EQ.app"), "\($0)") }
        XCTAssertEqual(agent.calls, [])
    }

    func testUninstallTouchesOnlyTheBundledAgent() throws {
        let agent = FakeAgent()
        XCTAssertFalse(try LaunchAgent.uninstall(agent))
        agent.serviceStatus = .enabled
        XCTAssertTrue(try LaunchAgent.uninstall(agent))
        let legacy = FakeAgent.legacyRunning()
        XCTAssertFalse(try LaunchAgent.uninstall(legacy))
        XCTAssertEqual(agent.calls, ["unregister"])
        XCTAssertEqual(legacy.calls, [])
    }
}

final class AgentCLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!
    private var agent: FakeAgent!
    private var warnings: [String] = []

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        agent = FakeAgent()
        warnings = []
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-28" })
        context.agent = agent
        context.checksDaemon = true
        context.warn = { [unowned self] in warnings.append($0) }
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func run(_ args: [String]) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private func writeStatus(_ state: Status.State) throws {
        try Status(state: state, device: nil, sampleRate: 0, profile: nil, framesProcessed: 0, callbacks: 0, writes: 1, enabled: true,
                   error: nil, pid: getpid(), version: Build.version, updatedAt: Date())
            .write(to: context.statusURL)
    }

    func testFirstCommandStartsTheDaemonAndSaysSoOnce() {
        XCTAssertEqual(run([]).exitCode, 0)
        XCTAssertEqual(warnings, ["started the eq daemon (login item \"EQ\") — allow System Audio Recording when macOS asks"])
        run([])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(agent.calls, ["register"])
    }

    func testAFailedStartNeverFailsTheCommand() {
        agent.registerError = NSError(domain: "x", code: 3, userInfo: [NSLocalizedDescriptionKey: "nope"])
        let result = run(["zones"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(warnings, ["could not start the eq daemon (nope) — see eq doctor"])
    }

    func testCompletionHelpAndTheAgentCommandStartNothing() {
        for args in [["__complete", "presets"], ["completions", "zsh"], ["man"], ["help"], ["set", "--help"], ["agent", "status"]] {
            run(args)
        }
        XCTAssertEqual(agent.calls, [])
        XCTAssertEqual(warnings, [])
    }

    func testOffInTestsAndSandboxedRuns() {
        context.checksDaemon = false
        run([])
        XCTAssertEqual(agent.calls, [])
    }

    func testMissingPermissionIsNamedOnEveryCommandButStatusAndDoctor() throws {
        try writeStatus(.noPermission)
        run([])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("Screen & System Audio Recording"), warnings[0])
        run(["status"])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(agent.calls, [])
    }

    func testAgentStatus() throws {
        let text = run(["agent", "status"]).output
        XCTAssertTrue(text.contains("launcher: not registered — eq agent install"), text)
        XCTAssertTrue(text.contains("service: notRegistered"), text)
        XCTAssertTrue(text.contains("bundle: /Applications/EQ.app"), text)
        agent.serviceStatus = .requiresApproval
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run(["agent", "status", "--json"]).output.utf8)) as? [String: Any])
        XCTAssertEqual(json["service"] as? String, "requiresApproval")
        XCTAssertEqual(json["launcher"] as? String, "needs-approval")
        XCTAssertEqual(json["loaded"] as? Bool, false)
    }

    func testAgentInstallFromTheCaskIgnoresAProcessSerialNumber() throws {
        let result = run(["agent", "install", "-psn_0_12345"])
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("started the eq daemon"), result.output)
        XCTAssertEqual(agent.calls, ["register"])
    }

    func testAgentInstallReplaceLegacy() throws {
        agent = FakeAgent.legacyRunning()
        context.agent = agent
        let refused = run(["agent", "install"])
        XCTAssertEqual(refused.exitCode, 1)
        XCTAssertTrue(refused.output.contains("--replace-legacy"), refused.output)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run(["agent", "install", "--replace-legacy", "--json"]).output.utf8))
            as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "started")
        XCTAssertEqual(json["launcher"] as? String, "bundled")
        XCTAssertEqual(json["setAside"] as? String, "/Users/someone/.Trash/com.servitola.eq.plist")
    }

    func testAgentUninstallAndUsage() {
        XCTAssertTrue(run(["agent", "uninstall"]).output.contains("was not registered"))
        agent.serviceStatus = .enabled
        XCTAssertTrue(run(["agent", "uninstall"]).output.contains("removed the login item"))
        XCTAssertEqual(run(["agent", "bogus"]).exitCode, 2)
    }

    private var optOutMarker: URL { context.cacheDirectory.deletingLastPathComponent().appendingPathComponent("agent-off") }

    func testUninstallKeepsItOffUntilInstall() {
        agent.serviceStatus = .enabled
        agent.job = LoadedJob(managedByServiceManagement: true, path: nil, pid: 42)
        XCTAssertTrue(run(["agent", "uninstall"]).output.contains("stays off until eq agent install"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: optOutMarker.path))
        run([])
        XCTAssertEqual(agent.calls, ["unregister"])
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(run(["agent", "install"]).exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: optOutMarker.path))
        XCTAssertEqual(agent.calls, ["unregister", "register"])
    }

    func testUninstallForAnUpgradeLeavesAutoStartOn() {
        agent.serviceStatus = .enabled
        XCTAssertEqual(run(["agent", "uninstall", "--for-upgrade"]).exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: optOutMarker.path))
        run([])
        XCTAssertEqual(agent.calls, ["unregister", "register"])
    }

    func testAgentStaysOutOfHelpAndCompletions() {
        XCTAssertFalse(HelpRenderer.plain(width: 200).contains("eq agent"))
        for shell in ["zsh", "bash", "fish"] { XCTAssertFalse(run(["completions", shell]).output.contains("agent"), shell) }
    }
}
