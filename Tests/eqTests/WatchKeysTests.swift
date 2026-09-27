import XCTest
@testable import eq

final class WatchKeysTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private struct Source: MeterSource {
        let lines: [String]
        func lines(maxLines: Int?, handle: (String) -> Bool) -> Bool {
            for line in lines { guard handle(line) else { return false } }
            return true
        }
    }

    private func frameLine() throws -> String {
        let f = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: Array(repeating: -60, count: 10),
                           out: Array(repeating: -40, count: 10), peak: -6, limiting: false,
                           gains: Array(repeating: 0, count: 10), preamp: -1.5, enabled: true)
        return String(decoding: try MeterFrame.encodeLine(f).dropLast(), as: UTF8.self)
    }

    private func frames(_ emitted: [String]) -> [String] { emitted.filter { $0.contains("\u{1B}[H") } }

    private func context() throws -> CLIContext {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-keys-\(UUID().uuidString)")
        let ctx = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [] },
            defaultOutput: { ("SPK", "Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-27" })
        _ = try ctx.store.loadOrCreate(builtInUID: nil, builtInName: nil)
        return ctx
    }

    private func profile(_ ctx: CLIContext) throws -> Profile {
        try ctx.store.load().profile(forDeviceUID: "SPK").profile
    }

    func testDigitsRaiseTheirBand() {
        for (i, key) in "1234567890".enumerated() {
            XCTAssertEqual(WatchKeys.action(for: String(key)), .bandStep(i, 0.5), String(key))
        }
    }

    func testShiftedDigitsLowerTheirBand() {
        for (i, key) in "!@#$%^&*()".enumerated() {
            XCTAssertEqual(WatchKeys.action(for: String(key)), .bandStep(i, -0.5), String(key))
        }
        for (i, key) in "!\"№;%:?*()".enumerated() where key != "?" {
            XCTAssertEqual(WatchKeys.action(for: String(key)), .bandStep(i, -0.5), String(key))
        }
        XCTAssertEqual(WatchKeys.action(for: "№"), .bandStep(2, -0.5))
        XCTAssertEqual(Array("№".utf8).count, 3)
    }

    func testOtherKeys() {
        XCTAssertEqual(WatchKeys.action(for: "+"), .preamp(0.5))
        XCTAssertEqual(WatchKeys.action(for: "="), .preamp(0.5))
        XCTAssertEqual(WatchKeys.action(for: "-"), .preamp(-0.5))
        XCTAssertEqual(WatchKeys.action(for: "_"), .preamp(-0.5))
        XCTAssertEqual(WatchKeys.action(for: "z"), .zones)
        XCTAssertEqual(WatchKeys.action(for: "?"), .help, "help wins over Russian Shift+7")
        XCTAssertEqual(WatchKeys.action(for: "h"), .help)
        XCTAssertEqual(WatchKeys.action(for: "р"), .help)
        XCTAssertEqual(WatchKeys.action(for: "x"), .dismissHelp)
        XCTAssertEqual(WatchKeys.action(for: "q"), .quit)
        XCTAssertEqual(WatchKeys.action(for: "Q"), .quit)
        XCTAssertEqual(WatchKeys.action(for: "й"), .quit)
        for unknown in ["a", " ", "\u{1B}[A", "12", ""] { XCTAssertNil(WatchKeys.action(for: unknown), unknown) }
    }

    func testEditStepsAndReturns() throws {
        let ctx = try context()
        let start = try profile(ctx).bands[5]
        try CLI.watchEdit(.bandStep(5, 0.5), ctx)
        XCTAssertEqual(try profile(ctx).bands[5], start + 0.5)
        XCTAssertEqual(try ctx.store.load().devices["SPK"]?.name, "Speakers")
        try CLI.watchEdit(WatchKeys.action(for: "^")!, ctx)
        XCTAssertEqual(try profile(ctx).bands[5], start)
        try CLI.watchEdit(.preamp(-0.5), ctx)
        XCTAssertEqual(try profile(ctx).preamp, -0.5)
    }

    func testEditClamps() throws {
        let ctx = try context()
        for _ in 0..<40 { try CLI.watchEdit(.bandStep(0, 0.5), ctx) }
        XCTAssertEqual(try profile(ctx).bands[0], 12)
        for _ in 0..<80 { try CLI.watchEdit(.preamp(-0.5), ctx) }
        XCTAssertEqual(try profile(ctx).preamp, -30)
    }

    func testEditWithoutConfigThrows() throws {
        var ctx = try context()
        ctx.store = ConfigStore(url: ctx.store.url.deletingLastPathComponent().appendingPathComponent("none.json"))
        XCTAssertThrowsError(try CLI.watchEdit(.bandStep(0, 0.5), ctx))
    }

    func testHintOnFirstFrameUntilAnyKey() throws {
        let line = try frameLine()
        var emitted: [String] = []
        var keys: [String?] = [nil, "a", nil]
        _ = Watch.run(source: Source(lines: Array(repeating: line, count: 3)), size: { (100, 30) },
                      emit: { emitted.append($0) }, readKey: { keys.isEmpty ? nil : keys.removeFirst() })
        XCTAssertEqual(frames(emitted).map { $0.contains("┌ tune") }, [true, true, false])
        XCTAssertTrue(frames(emitted)[0].contains("│ x     hide this for good  │"))
    }

    func testHintHidesAfterEightSeconds() throws {
        let line = try frameLine()
        var emitted: [String] = []
        _ = Watch.run(source: Source(lines: Array(repeating: line, count: Watch.hintFrames + 1)), size: { (100, 30) },
                      emit: { emitted.append($0) }, readKey: { nil })
        XCTAssertTrue(frames(emitted)[Watch.hintFrames - 1].contains("┌ tune"))
        XCTAssertFalse(frames(emitted)[Watch.hintFrames].contains("┌ tune"))
    }

    func testDismissedHintStaysOffUntilHelp() throws {
        let line = try frameLine()
        var emitted: [String] = []
        var keys: [String?] = [nil, "h", nil]
        _ = Watch.run(source: Source(lines: Array(repeating: line, count: 3)), size: { (100, 30) }, hintDismissed: true,
                      emit: { emitted.append($0) }, readKey: { keys.isEmpty ? nil : keys.removeFirst() })
        XCTAssertEqual(frames(emitted).map { $0.contains("┌ tune") }, [false, false, true])
    }

    func testXDismissesOnce() throws {
        let line = try frameLine()
        var emitted: [String] = []
        var dismissals = 0
        var keys: [String?] = ["x", "x"]
        _ = Watch.run(source: Source(lines: Array(repeating: line, count: 3)), size: { (100, 30) },
                      emit: { emitted.append($0) }, readKey: { keys.isEmpty ? nil : keys.removeFirst() },
                      dismissHint: { dismissals += 1 })
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(frames(emitted).map { $0.contains("┌ tune") }, [true, false, false])
    }

    func testNarrowShowsOneLineHint() throws {
        let line = try frameLine()
        var emitted: [String] = []
        _ = Watch.run(source: Source(lines: [line]), size: { (56, 24) },
                      emit: { emitted.append($0) }, readKey: { nil })
        let drawn = try XCTUnwrap(frames(emitted).first)
        XCTAssertFalse(drawn.contains("┌ tune"))
        XCTAssertTrue(drawn.contains("1…0 up · ⇧ down · +/− preamp"), drawn)
    }

    func testBoxSitsTopRightOverTheMeter() {
        let layout = WatchLayout.fit(cols: 100, rows: 30)
        let f = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: [], out: [], peak: -6, limiting: false,
                           gains: [], preamp: 0, enabled: true)
        let lines = Watch.frame(f, layout: layout, hint: true)
        XCTAssertEqual(lines.count, Watch.frame(f, layout: layout).count)
        XCTAssertTrue(lines[1].hasSuffix("┌ tune ─────────────────────┐"), lines[1])
        XCTAssertTrue(lines[8].hasSuffix("└───────────────────────────┘"), lines[8])
        XCTAssertEqual(lines[1].count, 90)
    }

    func testOverlayKeepsColourAroundTheBox() {
        Paint.forced = true
        let line = "\u{1B}[32m" + String(repeating: "█", count: 6) + "\u{1B}[0m"
        XCTAssertEqual(Watch.overlay(line, "ab", at: 2, width: 2),
                       "\u{1B}[32m██\u{1B}[0mab\u{1B}[32m██\u{1B}[0m")
    }

    func testEditFlashesLabelAndErrorsShowInFooter() throws {
        Paint.forced = true
        let line = try frameLine()
        var emitted: [String] = []
        var keys: [String?] = ["6", "7"]
        var edits: [WatchAction] = []
        _ = Watch.run(source: Source(lines: Array(repeating: line, count: 3)), size: { (100, 30) }, hintDismissed: true,
                      emit: { emitted.append($0) }, readKey: { keys.isEmpty ? nil : keys.removeFirst() },
                      edit: { action in
                          edits.append(action)
                          if action == .bandStep(6, 0.5) { throw CLIError.usage("no config") }
                      })
        XCTAssertEqual(edits, [.bandStep(5, 0.5), .bandStep(6, 0.5)])
        let drawn = frames(emitted)
        XCTAssertTrue(drawn[1].contains("\u{1B}[1m    1kHz"), drawn[1])
        XCTAssertTrue(drawn[2].contains("no config"), drawn[2])
    }
}
