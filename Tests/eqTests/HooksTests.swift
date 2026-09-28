import XCTest
@testable import eq

final class HooksTests: XCTestCase {
    func testUnknownNamesAreIgnoredAndBlankCommandsNeverRun() {
        var runs: [HookRun] = []
        var scheduled: [() -> Void] = []
        let hooks = Hooks(schedule: { _, work in scheduled.append(work) }, run: { runs.append($0) })
        XCTAssertEqual(Hooks.unknown(in: ["device": "x", "volume": "y", "Preset": "z"]), ["Preset", "volume"])
        XCTAssertEqual(Hooks.unknown(in: nil), [])
        hooks.configure(["volume": "echo no", "preset": "  "])
        hooks.fire("volume", environment: [:])
        hooks.fire("preset", environment: [:])
        hooks.fire("device", environment: [:])
        scheduled.forEach { $0() }
        XCTAssertEqual(runs, [])
    }

    func testAHookRemovedWhileWaitingDoesNotRun() {
        var runs: [HookRun] = []
        var scheduled: [() -> Void] = []
        let hooks = Hooks(schedule: { _, work in scheduled.append(work) }, run: { runs.append($0) })
        hooks.configure(["device": "true"])
        hooks.fire("device", environment: [:])
        hooks.configure(nil)
        scheduled.forEach { $0() }
        XCTAssertEqual(runs, [])
    }
}

final class HookRunnerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func hook(_ command: String) -> HookRun {
        HookRun(name: "device", command: command, environment: ["EQ_DEVICE": "AirPods Pro", "EQ_PRESET": "night", "EQ_RATE": "48000"])
    }

    func testEnvironmentReachesTheShellAndOutputIsCaptured() {
        let result = HookRunner.run(hook(#"echo "$EQ_DEVICE|$EQ_PRESET|$EQ_RATE"; echo oops >&2"#))
        XCTAssertEqual(result, HookRunner.Result(status: 0, timedOut: false, output: "AirPods Pro|night|48000\noops\n", truncated: false))
        XCTAssertEqual(HookRunner.describe("device", result), "hook device: ok: AirPods Pro|night|48000\noops")
    }

    func testFailureIsReportedWithItsStatus() {
        let result = HookRunner.run(hook("exit 3"))
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(HookRunner.describe("preset", result), "hook preset: exited 3")
    }

    func testTimeoutKillsTheHookAndItsChildren() {
        let marker = dir.appendingPathComponent("survived")
        let started = Date()
        let result = HookRunner.run(hook("(sleep 2; touch '\(marker.path)') & sleep 30"), timeout: 0.2)
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.status)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(HookRunner.describe("device", result), "hook device: timed out — killed")
        Thread.sleep(forTimeInterval: 2.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a child of a killed hook must not live on")
    }

    func testOutputIsCappedButDrainedToTheEnd() {
        let result = HookRunner.run(hook("head -c 100000 /dev/zero | tr '\\0' x; echo done >&2"), cap: 4096)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.output, String(repeating: "x", count: 4096))
        XCTAssertTrue(HookRunner.describe("device", result).hasSuffix("… (output cut at 4096 bytes)"))
    }

    func testABackgroundChildHoldingThePipeDoesNotHoldTheRunner() {
        let started = Date()
        let result = HookRunner.run(hook("sleep 3 & echo left"))
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "left\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testLiveRunnerNeverBlocksTheCaller() {
        let logged = expectation(description: "logged")
        var line = ""
        let run = HookRunner.live { line = $0; logged.fulfill() }
        let started = Date()
        run(hook("sleep 0.3; echo \"$EQ_RATE\""))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        wait(for: [logged], timeout: 5)
        XCTAssertEqual(line, "hook device: ok: 48000")
    }
}
