import EQTerm
import XCTest
@testable import eq

final class WatchKeysTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private func frameLine() throws -> String {
        let f = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: Array(repeating: -60, count: 10),
                           out: Array(repeating: -40, count: 10), peak: -6, limiting: false,
                           gains: Array(repeating: 0, count: 10), preamp: -1.5, enabled: true)
        return String(decoding: try MeterFrame.encodeLine(f).dropLast(), as: UTF8.self)
    }

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
        for (i, key) in "!\"№;%:?*()".enumerated() where key != "?" && key != ";" {
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
        XCTAssertNil(WatchKeys.action(for: "x"), "the box x hid is gone")
        XCTAssertEqual(WatchKeys.action(for: "i"), .instruments)
        XCTAssertEqual(WatchKeys.action(for: "ш"), .instruments)
        XCTAssertEqual(WatchKeys.action(for: "m"), .mouse)
        XCTAssertEqual(WatchKeys.action(for: ";"), .palette, "the palette's key, over Russian Shift+4")
        XCTAssertEqual(WatchKeys.action(for: "ж"), .palette)
        XCTAssertEqual(WatchKeys.action(for: "\u{10}"), .palette)
        XCTAssertEqual(WatchKeys.action(for: ":"), .bandStep(5, -0.5), "Russian Shift+6 still lowers 1 kHz")
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

    func testFirstEditWithoutConfigWritesIt() throws {
        var ctx = try context()
        ctx.store = ConfigStore(url: ctx.store.url.deletingLastPathComponent().appendingPathComponent("none.json"))
        try CLI.watchEdit(.bandStep(0, 0.5), ctx)
        XCTAssertTrue(ctx.store.exists())
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
        var keys: [String?] = ["6", "7"]
        var edits: [WatchAction] = []
        let drawn = MeterHarness.run(lines: Array(repeating: line, count: 3), size: { (100, 30) },
                                     readKey: { keys.isEmpty ? nil : keys.removeFirst() },
                                     edit: { action in
                                         edits.append(action)
                                         if action == .bandStep(6, 0.5) { throw CLIError.usage("no config") }
                                     }).drawn
        XCTAssertEqual(edits, [.bandStep(5, 0.5), .bandStep(6, 0.5)])
        XCTAssertTrue(drawn[1].contains("\u{1B}[1m    1kHz"), drawn[1])
        XCTAssertTrue(drawn[2].contains("no config"), drawn[2])
    }

    func testPresetUndoSaveKeysOnBothLayouts() {
        for key in ["p", "P", "з", "З"] { XCTAssertEqual(WatchKeys.action(for: key), .cyclePreset, key) }
        for key in ["u", "U", "г", "Г"] { XCTAssertEqual(WatchKeys.action(for: key), .undo, key) }
        for key in ["s", "S", "ы", "Ы"] { XCTAssertEqual(WatchKeys.action(for: key), .startSave, key) }
    }

    func testPCyclesPresetsAlphabeticallyAndWraps() throws {
        let ctx = try context()
        let session = CLI.WatchSession(ctx)
        XCTAssertNil(session.header().preset)
        try session.apply(.cyclePreset)
        XCTAssertEqual(try profile(ctx).preset, "favourite")
        XCTAssertEqual(try profile(ctx).bands, Config.screenshotCurve)
        try session.apply(.cyclePreset)
        XCTAssertEqual(try profile(ctx).preset, "flat")
        XCTAssertEqual(try profile(ctx).bands, Array(repeating: 0, count: 10))
        XCTAssertEqual(session.header().preset?.name, "flat")
        XCTAssertEqual(session.header().preset?.modified, false)
        try session.apply(.cyclePreset)
        XCTAssertEqual(try profile(ctx).preset, "favourite")
        try session.apply(.bandStep(0, 0.5))
        XCTAssertEqual(session.header().preset?.modified, true)
    }

    func testUndoWalksBackToTheSessionStart() throws {
        let ctx = try context()
        let start = try ctx.store.load()
        let session = CLI.WatchSession(ctx)
        try session.apply(.bandStep(0, 0.5))
        try session.apply(.preamp(-0.5))
        try session.apply(.undo)
        XCTAssertEqual(try profile(ctx).preamp, 0)
        XCTAssertEqual(try profile(ctx).bands[0], start.default.bands[0] + 0.5)
        try session.apply(.undo)
        XCTAssertEqual(try ctx.store.load().devices, start.devices)
        XCTAssertThrowsError(try session.apply(.undo)) { XCTAssertTrue("\($0)".contains("nothing left to undo")) }
    }

    func testOnlyTheFirstWatchSaveBacksUp() throws {
        let ctx = try context()
        let session = CLI.WatchSession(ctx)
        try session.apply(.bandStep(0, 0.5))
        try session.apply(.bandStep(1, 0.5))
        try session.apply(.cyclePreset)
        XCTAssertEqual(ctx.store.backups().map(\.index), [1])
        XCTAssertNil(try ctx.store.load(backup: 1).devices["SPK"], "the backup is the pre-session file")
    }

    func testAWatchSessionCostsOneUndoStep() throws {
        let ctx = try context()
        let start = try ctx.store.load()
        let session = CLI.WatchSession(ctx)
        try session.apply(.bandStep(0, 0.5))
        try session.apply(.bandStep(1, 0.5))
        try session.apply(.preamp(-0.5))
        XCTAssertEqual(try ctx.store.stepBack()?.index, 1, "the whole session undoes in a single eq undo")
        XCTAssertEqual(try ctx.store.load().devices, start.devices)
        XCTAssertNil(try ctx.store.stepBack(), "nothing further back than the pre-session config")
    }

    func testAnEditFromAnotherCommandBetweenWatchSavesIsBackedUp() throws {
        let ctx = try context()
        let session = CLI.WatchSession(ctx)
        try session.apply(.preamp(-1))
        var other = try ctx.store.load()
        var profile = other.profile(forDeviceUID: "SPK").profile
        profile.preamp = -7
        other.setProfile(profile, forDeviceUID: "SPK")
        try ctx.store.save(other)
        try session.apply(.bandStep(0, 0.5))
        let preamps = ctx.store.backups().map { try? ctx.store.load(backup: $0.index).profile(forDeviceUID: "SPK").profile.preamp }
        XCTAssertTrue(preamps.contains(-7), "eq set's -7 must stay in history, got \(preamps)")
    }

    func testAWatchEditAfterAnUndoElsewhereSurvivesRedo() throws {
        let ctx = try context()
        let session = CLI.WatchSession(ctx)
        try session.apply(.preamp(-3))
        XCTAssertEqual(try ctx.store.stepBack()?.index, 1, "eq undo in another terminal")
        try session.apply(.preamp(-4))
        XCTAssertEqual(try profile(ctx).preamp, -4)
        XCTAssertNil(try ctx.store.stepForward(), "the watch edit ended the redo branch")
        XCTAssertEqual(try profile(ctx).preamp, -4, "redo never overwrites the watch edit")
        let history = ctx.store.backups().map { try? ctx.store.load(backup: $0.index).profile(forDeviceUID: "SPK").profile.preamp }
        XCTAssertEqual(history, [0, -3, 0], "the version it edited, the abandoned -3, the pre-session file")
        XCTAssertEqual(try ctx.store.stepBack()?.index, 1)
        XCTAssertEqual(try ctx.store.stepForward()?.index, 0)
        XCTAssertEqual(try profile(ctx).preamp, -4, "-4 is the latest version redo returns to")
    }

    func testSaveAsStoresThePresetAndMarksTheDevice() throws {
        let ctx = try context()
        let session = CLI.WatchSession(ctx)
        try session.apply(.bandStep(0, 0.5))
        try session.apply(.savePreset("club mix"))
        let config = try ctx.store.load()
        XCTAssertEqual(config.presets?["club mix"]?.bands, try profile(ctx).bands)
        XCTAssertEqual(try profile(ctx).preset, "club mix")
        XCTAssertEqual(session.header().preset?.name, "club mix")
        XCTAssertThrowsError(try session.apply(.savePreset("bad/name"))) { XCTAssertEqual($0 as? CLIError, .badPresetName("bad/name")) }
    }

    private func runKeys(_ keys: [String?], edits: inout [WatchAction], count: Int? = nil) throws -> [String] {
        let line = try frameLine()
        var queue = keys
        var seen: [WatchAction] = []
        let drawn = MeterHarness.run(lines: Array(repeating: line, count: count ?? keys.count + 1), size: { (100, 30) },
                                     readKey: { queue.isEmpty ? nil : queue.removeFirst() }, edit: { seen.append($0) }).drawn
        edits = seen
        return drawn
    }

    func testSaveAsPromptTypesAndSavesOnEnter() throws {
        var edits: [WatchAction] = []
        let drawn = try runKeys(["s", "m", "1", "x", "\u{7F}", "y", "\n"], edits: &edits)
        XCTAssertEqual(edits, [.savePreset("m1y")], "digits type into the prompt instead of editing bands")
        XCTAssertTrue(drawn[2].contains("save as: m▏"), drawn[2])
        XCTAssertTrue(drawn[4].contains("save as: m1x▏"), drawn[4])
        XCTAssertFalse(drawn[7].contains("save as:"), drawn[7])
    }

    func testSaveAsTakesAWholeLineInOneRead() throws {
        var edits: [WatchAction] = []
        _ = try runKeys(["s", "club mix\n", "2"], edits: &edits)
        XCTAssertEqual(edits, [.savePreset("club mix"), .bandStep(1, 0.5)])
    }

    func testEscCancelsTheSavePrompt() throws {
        var edits: [WatchAction] = []
        let drawn = try runKeys(["s", "a", "\u{1B}[A", "\u{1B}", "1"], edits: &edits)
        XCTAssertEqual(edits, [.bandStep(0, 0.5)])
        XCTAssertTrue(drawn[3].contains("save as: a▏"), "an arrow does not cancel")
        XCTAssertFalse(drawn[4].contains("save as:"), drawn[4])
    }

    func testSaveErrorShowsInTheFooter() throws {
        let line = try frameLine()
        var keys: [String?] = ["s", "?\n"]
        let drawn = MeterHarness.run(lines: Array(repeating: line, count: 4), size: { (100, 30) },
                                     readKey: { keys.isEmpty ? nil : keys.removeFirst() },
                                     edit: { if case .savePreset(let name) = $0 { throw CLIError.badPresetName(name) } }).drawn
        XCTAssertTrue(drawn[2].contains("bad preset name \"?\""), drawn[2])
    }

    func testHeaderShowsThePresetAfterPreamp() throws {
        let line = try frameLine()
        var modified = false
        var keys: [String?] = [nil, "1"]
        let drawn = MeterHarness.run(lines: Array(repeating: line, count: 3), size: { (100, 30) },
                                     readKey: { keys.isEmpty ? nil : keys.removeFirst() },
                                     edit: { _ in modified = true }, header: { Watch.Header(preset: ("favourite", modified)) }).drawn
        XCTAssertTrue(drawn[0].contains("preamp -1.5 dB · favourite · peak"), drawn[0])
        XCTAssertTrue(drawn[2].contains("preamp -1.5 dB · favourite* · peak"), drawn[2])
    }

    private func feed(_ reads: [String]) -> [WatchAction] {
        var buffer = KeyBuffer()
        return reads.flatMap { WatchKeys.actions(for: buffer.feed(Array($0.utf8)) ?? "") }
    }

    func testArrowsSplitAcrossReadsStayArrows() {
        XCTAssertEqual(feed(["\u{1B}[", "B\u{1B}[B\u{1B}[B\u{1B}", "[B", ""]),
                       Array(repeating: .cyclePreset, count: 4))
        XCTAssertEqual(feed(["\u{1B}", "O", "A"]), [.previousPreset])
    }

    func testACharacterSplitAcrossReadsIsOneKey() {
        var buffer = KeyBuffer()
        let bytes = Array("й".utf8)
        XCTAssertEqual(bytes.count, 2)
        XCTAssertNil(buffer.feed([bytes[0]]))
        XCTAssertEqual(buffer.feed([bytes[1]]), "й")
        let sign = Array("№".utf8)
        XCTAssertNil(buffer.feed(Array(sign.prefix(2))))
        XCTAssertEqual(buffer.feed(Array(sign.suffix(1)) + Array("q".utf8)), "№q")
    }

    func testAStrayLeadByteDoesNotHoldBackTheNextKey() {
        var buffer = KeyBuffer()
        XCTAssertEqual(buffer.feed([0xE2, UInt8(ascii: "q")]), "\u{FFFD}q", "q quits at once, not after two more bytes")
        XCTAssertNil(buffer.feed([0xD0]), "a lead byte alone may still be completed")
        XCTAssertEqual(buffer.feed([0xB9]), "й")
    }

    func testALoneEscIsEscOnlyWhenNothingFollowsIt() {
        var buffer = KeyBuffer()
        XCTAssertEqual(buffer.feed(Array("]\u{1B}".utf8)), "]")
        XCTAssertEqual(buffer.feed([]), "\u{1B}")
        XCTAssertNil(buffer.feed([]))
        XCTAssertEqual(feed(["]", "\u{1B}", ""]), [.focusNext, .unfocus])
    }

    func testAnEndlessUnfinishedSequenceIsDropped() {
        var buffer = KeyBuffer()
        XCTAssertNil(buffer.feed(Array("\u{1B}[".utf8) + Array(repeating: UInt8(ascii: "1"), count: KeyBuffer.maxTail)))
        XCTAssertEqual(buffer.feed(Array("q".utf8)), "q")
    }
}
