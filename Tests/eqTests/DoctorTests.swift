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
            launchAgentLoaded: { agent },
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
        XCTAssertEqual(report.checks.map(\.name), ["macOS", "config", "output", "daemon", "permission", "launch agent", "binary", "audio", "engine", "tap"])
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
        XCTAssertTrue(report.checks.first { $0.name == "launch agent" }!.detail.contains("bootstrap"))
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
        XCTAssertEqual(audio.detail, "status not refreshed after SIGUSR1 — daemon predates v3? restart it: launchctl kickstart -k gui/$UID/com.servitola.eq")
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
}
