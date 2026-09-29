import XCTest
@testable import eq

final class DriverInstallTests: XCTestCase {
    private let old = DriverBuild(version: "2026.09.29", revision: 13, protocolVersion: 1)
    private let new = DriverBuild(version: "2026.10.01", revision: 14, protocolVersion: 1)

    // MARK: - Reading a bundle

    private func bundle(_ info: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eq-driver-\(UUID().uuidString)/EQDriver.driver")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        XCTAssertTrue((info as NSDictionary).write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true))
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    func testABuildIsReadFromItsInfoPlist() throws {
        let url = try bundle(["CFBundleIdentifier": "com.servitola.eq.driver", "CFBundleShortVersionString": "2026.10.01",
                              "EQDriverRevision": 14, "EQDriverProtocol": 1])
        XCTAssertEqual(DriverBuild(bundle: url), new)
        XCTAssertEqual(new.label, "build 14 (2026.10.01)")
    }

    /// The driver installed before eq carried one has neither key, so any bundled driver is newer.
    func testADriverFromBeforeTheKeysIsRevisionZero() throws {
        let url = try bundle(["CFBundleIdentifier": "com.servitola.eq.driver", "CFBundleShortVersionString": "2026.09.29"])
        XCTAssertEqual(DriverBuild(bundle: url), DriverBuild(version: "2026.09.29", revision: 0, protocolVersion: nil))
    }

    func testAnotherBundleIsNoDriver() throws {
        XCTAssertNil(DriverBuild(bundle: try bundle(["CFBundleIdentifier": "net.briankendall.ProxyAudioDevice"])))
        XCTAssertNil(DriverBuild(bundle: URL(fileURLWithPath: "/nonexistent/EQDriver.driver")))
    }

    func testDriverFilesOutsideAnAppCarryNothing() {
        let files = DriverFiles.live(app: URL(fileURLWithPath: "/usr/local/bin"))
        XCTAssertNil(files.bundled)
        XCTAssertNil(files.bundledURL)
    }

    func testTheUpdateNoteOnlyForAnOlderInstall() {
        XCTAssertEqual(DriverFiles(installed: old, bundled: new).updateNote,
                       "the EQ driver is build 13 (2026.09.29), this eq carries build 14 (2026.10.01) — run `eq mode driver` to update it")
        XCTAssertNil(DriverFiles(installed: new, bundled: new).updateNote)
        XCTAssertNil(DriverFiles(installed: new, bundled: old).updateNote)
        XCTAssertNil(DriverFiles(installed: nil, bundled: new).updateNote)
        XCTAssertNil(DriverFiles(installed: old, bundled: nil).updateNote)
    }

    // MARK: - The decision table

    func testWhatEachCallerDoes() {
        typealias Case = (runtime: DriverInstall.Runtime, installed: DriverBuild?, sudo: DriverInstall.Plan, dialog: DriverInstall.Plan, daemon: DriverInstall.Plan)
        let notInstalled = "\(ModeSwitch.Failure.notInstalled)"
        let cases: [(String, Case)] = [
            ("absent", (.absent, nil, .install(.install, .sudo), .install(.install, .dialog), .unavailable(notInstalled))),
            ("files but no device", (.absent, old, .install(.install, .sudo), .install(.install, .dialog), .unavailable("the EQ device is missing"))),
            ("older", (.ready, old, .install(.update, .sudo), .install(.update, .dialog),
                       .useOutdated(DriverFiles(installed: old, bundled: new).updateNote!))),
            ("same", (.ready, new, .use, .use, .use)),
            ("newer", (.ready, DriverBuild(version: "dev", revision: 20), .use, .use, .use)),
            ("unknown build", (.ready, nil, .use, .use, .use)),
            ("incompatible", (.incompatible(0), old, .install(.replace, .sudo), .install(.replace, .dialog),
                              .unavailable("\(ModeSwitch.Failure.tooOld(0))"))),
            ("disabled", (.disabled, old, .use, .use, .use)),
        ]
        for (name, c) in cases {
            XCTAssertEqual(DriverInstall.plan(c.runtime, installed: c.installed, bundled: new, role: .cli(.sudo)), c.sudo, name)
            XCTAssertEqual(DriverInstall.plan(c.runtime, installed: c.installed, bundled: new, role: .cli(.dialog)), c.dialog, name)
            XCTAssertEqual(DriverInstall.plan(c.runtime, installed: c.installed, bundled: new, role: .daemon), c.daemon, name)
        }
        XCTAssertTrue(notInstalled.contains("run `eq mode driver` to install it"))
        XCTAssertTrue("\(ModeSwitch.Failure.tooOld(0))".contains("run `eq mode driver` to update it"))
    }

    func testWithNothingBundledTheCLIPointsAtABuild() {
        guard case .unavailable(let absent) = DriverInstall.plan(.absent, installed: nil, bundled: nil, role: .cli(.sudo)),
              case .unavailable(let stale) = DriverInstall.plan(.incompatible(nil), installed: nil, bundled: nil, role: .cli(.dialog)) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertEqual(absent, "the EQ driver is not installed, and this eq carries no driver to install — build EQ.app with scripts/build-app.sh, or: sudo Driver/dev-install.sh")
        XCTAssertTrue(stale.hasPrefix("the EQ driver speaks settings protocol 0, this eq needs 1, and this eq carries no driver"), stale)
        XCTAssertEqual(DriverInstall.plan(.ready, installed: old, bundled: nil, role: .cli(.sudo)), .use)
    }

    // MARK: - The privileged step

    func testTheRequirementPinsTheTeamOnlyWhenThereIsOne() {
        XCTAssertEqual(DriverInstall.requirement(team: "NZNV266K59"),
                       #"identifier "com.servitola.eq.driver" and anchor apple generic and certificate leaf[subject.OU] = "NZNV266K59""#)
        XCTAssertEqual(DriverInstall.requirement(team: nil), #"identifier "com.servitola.eq.driver""#)
        XCTAssertEqual(DriverInstall.requirement(team: #"X" or anchor apple generic or identifier "a"#), #"identifier "com.servitola.eq.driver""#)
    }

    private let hostile = URL(fileURLWithPath: "/Applications/E'Q $(touch /tmp/eq-pwned); `id`\".app/Contents/PlugIns/EQDriver.driver")

    func testEveryValueIsItsOwnArgument() {
        let requirement = DriverInstall.requirement(team: "NZNV266K59")
        let sudo = DriverInstall.sudoCommand(.install(hostile), requirement: requirement)
        XCTAssertEqual(Array(sudo.prefix(3)), ["/usr/bin/sudo", "-p", "Password to install the EQ driver (%u): "])
        XCTAssertEqual(Array(sudo.dropFirst(3)), ["/bin/sh", "-c", DriverInstall.script, "eq-driver", "install", hostile.path, requirement])
        XCTAssertEqual(DriverInstall.sudoCommand(.uninstall, requirement: requirement).suffix(2), ["eq-driver", "uninstall"])
        let dialog = DriverInstall.dialogCommand(.install(hostile), requirement: requirement)
        XCTAssertEqual(dialog[0], "/usr/bin/osascript")
        XCTAssertEqual(Array(dialog.dropFirst(3)), [DriverInstall.script, "eq wants to install its audio driver.", "install", hostile.path, requirement])
        XCTAssertFalse(dialog[2].contains(hostile.path))
        XCTAssertEqual(dialog[2].components(separatedBy: "quoted form of").count - 1, 2)
    }

    /// The AppleScript's command line, run without the administrator part: what arrives is exactly what was passed.
    func testTheDialogQuotesEveryArgument() throws {
        let requirement = DriverInstall.requirement(team: "NZNV266K59")
        var command = DriverInstall.dialogCommand(.install(hostile), requirement: requirement)
        command[2] = command[2].replacingOccurrences(of: " with prompt (item 2 of argv) with administrator privileges", with: " without altering line endings")
        command[3] = #"for a in "$0" "$@"; do printf '%s\n' "$a"; done"#
        let result = try shell(command)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertEqual(result.output, ["eq-driver", "install", hostile.path, requirement].joined(separator: "\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/eq-pwned"))
    }

    /// The script checks its arguments before it asks whether it is root, so all of this runs as the user.
    func testTheScriptRefusesAnythingButItsTwoForms() throws {
        let requirement = DriverInstall.requirement(team: "NZNV266K59")
        func script(_ args: String...) throws -> Int32 { try shell(["/bin/sh", "-c", DriverInstall.script, "eq-driver"] + args).status }
        XCTAssertEqual(try script(), 64)
        XCTAssertEqual(try script("rm", "-rf", "/"), 64)
        XCTAssertEqual(try script("uninstall", "extra"), 64)
        XCTAssertEqual(try script("install", "/tmp/Other.driver", requirement), 64)
        XCTAssertEqual(try script("install", "relative/EQDriver.driver", requirement), 64)
        XCTAssertEqual(try script("install", hostile.path, "anchor apple"), 64)
        XCTAssertEqual(try script("install", hostile.path), 64)
        XCTAssertEqual(try script("install", hostile.path, requirement, "extra"), 64)
        XCTAssertEqual(try script("install", hostile.path, requirement), 77)
        XCTAssertEqual(try script("uninstall"), 77)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/eq-pwned"))
    }

    /// The install half against a scratch folder instead of /Library, as the user and without restarting
    /// anything: the staged copy must meet the requirement, and a tampered one never lands.
    func testTheScriptInstallsOnlyASignedDriver() throws {
        let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Driver/build/EQDriver.driver")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: built.path), "no Driver/build/EQDriver.driver; run Driver/build.sh --adhoc")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eq-script-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("EQ.app/Contents/PlugIns/EQDriver.driver")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: built, to: source)
        let script = DriverInstall.script
            .replacingOccurrences(of: "/Library/Audio/Plug-Ins", with: root.path + "/Plug-Ins")
            .replacingOccurrences(of: "[ \"$(/usr/bin/id -u)\" -eq 0 ]", with: "true")
            .replacingOccurrences(of: "/usr/sbin/chown -R root:wheel \"$stage\"", with: ":")
            .replacingOccurrences(of: "/usr/bin/killall coreaudiod || :", with: "echo restarted")
        let installed = root.appendingPathComponent("Plug-Ins/HAL/EQDriver.driver")
        let requirement = DriverInstall.requirement(team: nil)
        var result = try shell(["/bin/sh", "-c", script, "eq-driver", "install", source.path, requirement])
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertEqual(result.output, "restarted")
        XCTAssertEqual(DriverBuild(bundle: installed), DriverBuild(bundle: built))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Plug-Ins/.EQDriver.driver.staging").path))

        try Data("tampered".utf8).write(to: source.appendingPathComponent("Contents/Resources/extra"))
        try FileManager.default.removeItem(at: installed)
        result = try shell(["/bin/sh", "-c", script, "eq-driver", "install", source.path, requirement])
        XCTAssertEqual(result.status, 65, result.errors)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Plug-Ins/.EQDriver.driver.staging").path))

        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        result = try shell(["/bin/sh", "-c", script, "eq-driver", "uninstall"])
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        result = try shell(["/bin/sh", "-c", script, "eq-driver", "uninstall"])
        XCTAssertEqual(result.output, "", "nothing to remove restarts nothing")
    }

    func testTheScriptParses() throws {
        XCTAssertEqual(try shell(["/bin/sh", "-n", "-c", DriverInstall.script]).status, 0)
    }

    private func shell(_ command: [String]) throws -> (status: Int32, output: String, errors: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output.trimmingCharacters(in: .newlines), errors)
    }

    // MARK: - Which brew command runs the cask step

    func testTheBrewCommandIsTheWordAfterBrewRb() {
        let ruby = ["/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby", "-W1", "--disable=gems,rubyopt",
                    "/opt/homebrew/Library/Homebrew/brew.rb"]
        XCTAssertEqual(BrewParent.command(argv: ruby + ["uninstall", "--cask", "eq"]), "uninstall")
        XCTAssertEqual(BrewParent.command(argv: ruby + ["upgrade"]), "upgrade")
        XCTAssertEqual(BrewParent.command(argv: ruby + ["--help", "rm", "eq"]), "rm")
        XCTAssertNil(BrewParent.command(argv: ruby))
        XCTAssertNil(BrewParent.command(argv: ["/bin/zsh", "-c", "brew uninstall eq"]))
    }

    func testOnlyARemovalTakesTheDriver() {
        for command in ["uninstall", "uninstal", "rm", "remove"] { XCTAssertTrue(BrewParent.removes(command), command) }
        for command in ["upgrade", "reinstall", "install", "bundle", nil] as [String?] { XCTAssertFalse(BrewParent.removes(command), command ?? "nil") }
    }

    func testThisProcessHasNoBrewAbove() {
        XCTAssertNil(BrewParent.live())
    }

    /// The built eq under a shell whose command line looks like brew's: it finds the command two levels up.
    func testTheCaskStepReadsTheBrewCommandAboveIt() throws {
        let eq = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("eq")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: eq.path), "no built eq beside the tests")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-brew-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func caskStep(_ command: String) throws -> String {
            // The trailing `:` keeps sh from exec-ing eq in its own place.
            let line = "EQ_CONFIG=\(dir.path)/eq.json EQ_STATUS=\(dir.path)/status.json \"$EQ\" driver uninstall --cask --dry-run; :"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", line, "/opt/homebrew/Library/Homebrew/brew.rb", command, "eq"]
            process.environment = ["EQ": eq.path, "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return text
        }
        XCTAssertEqual(try caskStep("upgrade"), "brew upgrade is not removing eq: the EQ driver stays installed\n")
        XCTAssertEqual(try caskStep("reinstall"), "brew reinstall is not removing eq: the EQ driver stays installed\n")
        let removal = try caskStep("uninstall")
        XCTAssertFalse(removal.contains("not removing"), removal)
    }
}
