import XCTest
@testable import eq

final class DoctorTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private func probes(status: Status?, configThrows: Bool = false, agent: Bool = true, exe: String? = "/Applications/EQ.app/Contents/MacOS/eq",
                        callbacksLater: UInt64? = nil, refreshes: Bool = true,
                        output: DefaultOutput? = DefaultOutput(name: "Speakers", streams: 1, channels: 2)) -> DoctorProbes {
        var reads = 0
        return DoctorProbes(
            osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 2) },
            loadConfig: { if configThrows { throw ConfigError.bandCount("default", 3) }; return Config.initial(builtInUID: nil, builtInName: nil) },
            readStatus: {
                reads += 1
                guard var s = status else { return nil }
                if refreshes { s.writes += UInt64(reads) }
                if reads >= 3, let later = callbacksLater { s.callbacks = later }
                return s
            },
            defaultOutput: { output },
            launcher: { agent ? .bundled(loaded: true) : .notRegistered },
            executablePath: { _ in exe },
            signalStatus: { _ in true },
            sleep: { _ in },
            smoke: false)
    }

    private func running(callbacks: UInt64 = 10) -> Status {
        Status(state: .running, device: .init(uid: "u", name: "Speakers", transport: "builtin"), sampleRate: 48000, profile: .device,
               framesProcessed: 5, callbacks: callbacks, writes: 1, enabled: true, error: nil, pid: getpid(),
               version: Build.version, updatedAt: Date())
    }

    func testAllGreen() {
        let report = Doctor.run(probes(status: running(), callbacksLater: 20))
        XCTAssertTrue(report.ok, Doctor.text(report))
        XCTAssertEqual(report.checks.map(\.name), ["macOS", "config", "hooks", "output", "daemon", "permission", "launch agent", "binary", "audio", "engine", "tap", "latency", "ring", "filters"])
        XCTAssertTrue(report.checks.allSatisfy(\.ok))
    }

    func testTextPaintsNamesAndVerdict() {
        let report = Doctor.run(probes(status: running(), callbacksLater: 20))
        XCTAssertFalse(Doctor.text(report).contains("\u{1B}"))
        Paint.forced = true
        let text = Doctor.text(report)
        XCTAssertTrue(text.contains("\u{1B}[32m✓\u{1B}[0m \u{1B}[1mconfig\u{1B}[0m — ok"), text)
        XCTAssertTrue(text.hasSuffix("\u{1B}[32mok\u{1B}[0m"), text)
    }

    func testNoDaemonFailsDaemonAndEngineRows() {
        let report = Doctor.run(probes(status: nil))
        XCTAssertFalse(report.ok)
        XCTAssertFalse(report.checks.first { $0.name == "daemon" }!.ok)
        XCTAssertTrue(report.checks.first { $0.name == "daemon" }!.detail.contains("kickstart"))
        XCTAssertFalse(report.checks.first { $0.name == "engine" }!.ok)
    }

    func testPermissionAndConfigAndAgentFailures() {
        var s = running(); s.state = .noPermission
        var report = Doctor.run(probes(status: s, configThrows: true, agent: false))
        XCTAssertFalse(report.checks.first { $0.name == "permission" }!.ok)
        XCTAssertTrue(report.checks.first { $0.name == "permission" }!.detail.contains("Screen & System Audio Recording"))
        XCTAssertFalse(report.checks.first { $0.name == "config" }!.ok)
        XCTAssertFalse(report.checks.first { $0.name == "launch agent" }!.ok)
        XCTAssertTrue(report.checks.first { $0.name == "launch agent" }!.detail.contains("eq agent install"))
        report = Doctor.run(probes(status: running(), callbacksLater: 20))
        XCTAssertTrue(report.ok)
    }

    func testWarningsDoNotFail() {
        let report = Doctor.run(probes(status: running(callbacks: 10), exe: "/Volumes/SanDisk/projects/eq/.build/debug/eq", callbacksLater: 10))
        XCTAssertTrue(report.ok)
        let binary = report.checks.first { $0.name == "binary" }!
        XCTAssertTrue(binary.warning); XCTAssertFalse(binary.ok)
        let audio = report.checks.first { $0.name == "audio" }!
        XCTAssertTrue(audio.warning); XCTAssertTrue(audio.detail.contains("no IO callbacks"))
        XCTAssertTrue(Doctor.text(report).contains("! binary"))
    }

    func testStaleStatusWarnsInsteadOfComparing() {
        let report = Doctor.run(probes(status: running(), callbacksLater: 20, refreshes: false))
        XCTAssertTrue(report.ok)
        let audio = report.checks.first { $0.name == "audio" }!
        XCTAssertTrue(audio.warning)
        XCTAssertEqual(audio.detail, "status not refreshed after SIGUSR1 — daemon predates v3? restart it: launchctl kickstart -k gui/$UID/com.servitola.eq.daemon")
    }

    func testAudioCheckSendsSignal() {
        var signalCount = 0
        var p = probes(status: running(), callbacksLater: 20)
        p.signalStatus = { _ in signalCount += 1; return true }
        let report = Doctor.run(p)
        XCTAssertEqual(signalCount, 2)
        let audio = report.checks.first { $0.name == "audio" }!
        XCTAssertTrue(audio.ok, audio.detail)
    }

    func testAudioCheckWhenSignalFails() {
        var p = probes(status: running(), callbacksLater: 20)
        p.signalStatus = { _ in false }
        let report = Doctor.run(p)
        let audio = report.checks.first { $0.name == "audio" }!
        XCTAssertTrue(audio.warning)
        XCTAssertEqual(audio.detail, "could not signal the daemon")
    }

    func testZeroCallbacksPointAtRestart() {
        let report = Doctor.run(probes(status: running(callbacks: 0), callbacksLater: 0))
        let audio = report.checks.first { $0.name == "audio" }!
        XCTAssertTrue(audio.warning)
        XCTAssertTrue(audio.detail.contains("kickstart"))
    }

    func testAudioCheckSkipsSignalWhenDaemonIsPreV3() {
        var signalCount = 0
        var s = running(); s.version = nil
        var p = probes(status: s, callbacksLater: 20)
        p.signalStatus = { _ in signalCount += 1; return true }
        let report = Doctor.run(p)
        XCTAssertEqual(signalCount, 0)
        let audio = report.checks.first { $0.name == "audio" }!
        XCTAssertTrue(audio.warning)
        XCTAssertTrue(audio.detail.contains("pre-v3"))
        XCTAssertTrue(report.checks.first { $0.name == "daemon" }!.detail.hasSuffix("pre-v3"))
    }

    func testAudioCheckWarnsOnVersionMismatch() {
        var signalCount = 0
        var s = running(); s.version = "1.0"
        var p = probes(status: s, callbacksLater: 20)
        p.signalStatus = { _ in signalCount += 1; return true }
        let report = Doctor.run(p)
        XCTAssertEqual(signalCount, 2)
        XCTAssertTrue(report.ok)
        let audio = report.checks.first { $0.name == "audio" }!
        XCTAssertTrue(audio.warning); XCTAssertFalse(audio.ok)
        XCTAssertTrue(audio.detail.hasPrefix("callbacks 10 → 20"), audio.detail)
        XCTAssertTrue(audio.detail.contains("daemon v1.0, this eq v\(Build.version)"), audio.detail)
        XCTAssertTrue(audio.detail.contains("restart it"))
        XCTAssertTrue(report.checks.first { $0.name == "daemon" }!.detail.hasSuffix("v1.0"))
    }

    func testAudioCheckRefusesForeignPid() {
        var signalCount = 0
        var p = probes(status: running(), exe: "/usr/bin/sleep", callbacksLater: 20)
        p.signalStatus = { _ in signalCount += 1; return true }
        let report = Doctor.run(p)
        XCTAssertEqual(signalCount, 0)
        let audio = report.checks.first { $0.name == "audio" }!
        XCTAssertTrue(audio.warning)
        XCTAssertTrue(audio.detail.contains("not an eq daemon"), audio.detail)
    }

    func testZeroStreamOutputFails() {
        let report = Doctor.run(probes(status: running(), callbacksLater: 20, output: DefaultOutput(name: "Multi-Output Device", streams: 0, channels: 0)))
        XCTAssertFalse(report.ok)
        let output = report.checks.first { $0.name == "output" }!
        XCTAssertFalse(output.ok); XCTAssertFalse(output.warning)
        XCTAssertTrue(output.detail.contains("\"Multi-Output Device\" has no output streams"), output.detail)
        XCTAssertTrue(output.detail.contains("Sound"), output.detail)
    }

    func testZeroChannelOutputFails() {
        let report = Doctor.run(probes(status: running(), callbacksLater: 20, output: DefaultOutput(name: "Odd", streams: 1, channels: 0)))
        XCTAssertFalse(report.checks.first { $0.name == "output" }!.ok)
    }

    func testUnreadableStreamCountWarnsInsteadOfFailing() {
        let report = Doctor.run(probes(status: running(), callbacksLater: 20, output: DefaultOutput(name: "Speakers", streams: nil, channels: 2)))
        XCTAssertTrue(report.ok, Doctor.text(report))
        let output = report.checks.first { $0.name == "output" }!
        XCTAssertTrue(output.warning); XCTAssertFalse(output.ok)
        XCTAssertEqual(output.detail, "could not read the output's streams")
    }

    func testMissingDefaultOutputFails() {
        let report = Doctor.run(probes(status: running(), callbacksLater: 20, output: nil))
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.checks.first { $0.name == "output" }!.detail, "no default output device")
    }

    func testHealthyOutputShowsChannels() {
        let report = Doctor.run(probes(status: running(), callbacksLater: 20))
        XCTAssertEqual(report.checks.first { $0.name == "output" }!.detail, "Speakers, 2 ch")
    }

    func testSilentTapWarnsButDoesNotFail() {
        var s = running(); s.tapSilentSeconds = 45.7
        let report = Doctor.run(probes(status: s, callbacksLater: 20))
        XCTAssertTrue(report.ok, Doctor.text(report))
        let tap = report.checks.first { $0.name == "tap" }!
        XCTAssertTrue(tap.warning); XCTAssertFalse(tap.ok)
        XCTAssertEqual(tap.detail, "no audio reached the tap for 45 s — if something is playing, check System Audio Recording permission")
    }

    func testFiltersCheckSkipsWhenEngineNotRunning() {
        var s = running(); s.state = .failed; s.warnings = ["filter 2 unstable at 192000 Hz — bypassed"]
        let filters = Doctor.run(probes(status: s)).checks.first { $0.name == "filters" }!
        XCTAssertTrue(filters.ok); XCTAssertFalse(filters.warning)
        XCTAssertEqual(filters.detail, "skipped (engine not running)")
    }

    func testTapRowUsesTheStatusRefreshedBySIGUSR1() {
        var reads = 0
        let probes = DoctorProbes(
            osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 2) },
            loadConfig: { Config.initial(builtInUID: nil, builtInName: nil) },
            readStatus: { [self] in
                reads += 1
                var s = running(callbacks: reads == 3 ? 20 : 10)
                s.writes = UInt64(reads)
                // The first read (Doctor.run's `live`) looks silent; only the SIGUSR1-refreshed
                // reads that follow report audio has resumed.
                s.tapSilentSeconds = reads == 1 ? 40 : 0
                return s
            },
            defaultOutput: { DefaultOutput(name: "Speakers", streams: 1, channels: 2) },
            launcher: { .bundled(loaded: true) },
            executablePath: { _ in "/Applications/EQ.app/Contents/MacOS/eq" },
            signalStatus: { _ in true },
            sleep: { _ in },
            smoke: false)
        let report = Doctor.run(probes)
        let tap = report.checks.first { $0.name == "tap" }!
        XCTAssertTrue(tap.ok, Doctor.text(report)); XCTAssertFalse(tap.warning)
        XCTAssertEqual(tap.detail, "audio arriving")
    }

    func testBypassedFilterWarnsButDoesNotFail() {
        var s = running(); s.warnings = ["filter 2 unstable at 192000 Hz — bypassed"]
        let report = Doctor.run(probes(status: s, callbacksLater: 20))
        XCTAssertTrue(report.ok, Doctor.text(report))
        let filters = report.checks.first { $0.name == "filters" }!
        XCTAssertTrue(filters.warning); XCTAssertFalse(filters.ok)
        XCTAssertEqual(filters.detail, "filter 2 unstable at 192000 Hz — bypassed — raise its frequency to use it at this rate")
        s.warnings = []
        XCTAssertEqual(Doctor.run(probes(status: s, callbacksLater: 20)).checks.first { $0.name == "filters" }!.detail, "stable at 48000 Hz")
        let unreported = Doctor.run(probes(status: running(), callbacksLater: 20)).checks.first { $0.name == "filters" }!
        XCTAssertTrue(unreported.ok); XCTAssertTrue(unreported.detail.hasPrefix("skipped"))
    }

    func testTapWithinLimitOrUnreportedIsOK() {
        for (seconds, detail) in [(30.0, "silent for 30 s"), (0.2, "audio arriving")] {
            var s = running(); s.tapSilentSeconds = seconds
            let tap = Doctor.run(probes(status: s, callbacksLater: 20)).checks.first { $0.name == "tap" }!
            XCTAssertTrue(tap.ok); XCTAssertFalse(tap.warning); XCTAssertEqual(tap.detail, detail)
        }
        let unreported = Doctor.run(probes(status: running(), callbacksLater: 20)).checks.first { $0.name == "tap" }!
        XCTAssertTrue(unreported.ok); XCTAssertTrue(unreported.detail.hasPrefix("skipped"))
        var failed = running(); failed.state = .failed; failed.tapSilentSeconds = 99
        let skipped = Doctor.run(probes(status: failed)).checks.first { $0.name == "tap" }!
        XCTAssertTrue(skipped.ok); XCTAssertFalse(skipped.warning)
    }

    func testSmokeSkipsLaunchAgentRow() {
        var p = probes(status: running(), agent: false, callbacksLater: 20); p.smoke = true
        let report = Doctor.run(p)
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.checks.first { $0.name == "launch agent" }!.detail, "skipped (EQ_SMOKE)")
    }

    private func hooksCheck(_ hooks: [String: String]?) -> DoctorCheck {
        var p = probes(status: running(), callbacksLater: 20)
        var config = Config.initial(builtInUID: nil, builtInName: nil)
        config.hooks = hooks
        p.loadConfig = { config }
        return Doctor.run(p).checks.first { $0.name == "hooks" }!
    }

    func testHooksCheckFlagsMissingAndNonExecutableAbsolutePaths() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-doctor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("on device.sh")
        FileManager.default.createFile(atPath: script.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o644])

        XCTAssertEqual(hooksCheck(nil), DoctorCheck(name: "hooks", ok: true, detail: "none", warning: false))
        XCTAssertEqual(hooksCheck(["device": "osascript -e 'beep'", "preset": "/bin/echo \"$EQ_PRESET\""]),
                       DoctorCheck(name: "hooks", ok: true, detail: "device, preset", warning: false))

        let bad = hooksCheck(["device": "'\(script.path)' --now", "preset": "\(dir.path)/gone.sh", "volume": "true"])
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.warning, "a hook never affects audio, so it cannot fail the doctor")
        XCTAssertEqual(bad.detail, "unknown hook \"volume\" is ignored; device: \(script.path) is not executable; preset: \(dir.path)/gone.sh does not exist")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertTrue(hooksCheck(["device": "\"\(script.path)\""]).ok)
    }

    func testProgramOfACommand() {
        XCTAssertEqual(Doctor.program(of: "  /usr/bin/say hi"), "/usr/bin/say")
        XCTAssertEqual(Doctor.program(of: "'/a b/c' x"), "/a b/c")
        XCTAssertEqual(Doctor.program(of: "\"/a b/c"), "/a b/c")
        XCTAssertEqual(Doctor.program(of: "echo"), "echo")
        XCTAssertNil(Doctor.program(of: "   "))
    }

    func testRingWarnsOnceTheTapAndTheOutputSlip() {
        var s = running()
        XCTAssertEqual(Doctor.ringCheck(s), DoctorCheck(name: "ring", ok: true, detail: "skipped (not reported by this daemon)", warning: false))
        s.underruns = 0
        s.overruns = 0
        s.dropouts = 0
        XCTAssertEqual(Doctor.ringCheck(s), DoctorCheck(name: "ring", ok: true, detail: "no slips", warning: false))
        s.dropouts = 3
        let slipped = Doctor.ringCheck(s)
        XCTAssertFalse(slipped.ok)
        XCTAssertTrue(slipped.warning)
        XCTAssertTrue(slipped.detail.hasPrefix("0 underruns, 0 overruns, 3 dropouts — "), slipped.detail)
        s.state = .failed
        XCTAssertEqual(Doctor.ringCheck(s).detail, "skipped (engine not running)")
    }

    func testLatencyWarnsPastTheLipSyncLimit() {
        var s = running()
        XCTAssertEqual(Doctor.latencyCheck(s), DoctorCheck(name: "latency", ok: true, detail: "skipped (not measured yet)", warning: false))
        s.addedLatencyMs = 45
        XCTAssertEqual(Doctor.latencyCheck(s), DoctorCheck(name: "latency", ok: true, detail: "eq adds 45 ms", warning: false))
        s.addedLatencyMs = 212.4
        let late = Doctor.latencyCheck(s)
        XCTAssertFalse(late.ok)
        XCTAssertTrue(late.warning)
        XCTAssertTrue(late.detail.hasPrefix("eq adds 212 ms — "), late.detail)
        XCTAssertTrue(late.detail.contains("45 ms"), late.detail)
        let report = Doctor.run(probes(status: s, callbacksLater: 20))
        XCTAssertTrue(report.ok, "a warning must not fail doctor: \(Doctor.text(report))")
        s.state = .failed
        XCTAssertEqual(Doctor.latencyCheck(s).detail, "skipped (engine not running)")
    }
}
