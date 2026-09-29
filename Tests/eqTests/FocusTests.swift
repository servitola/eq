import EQTerm
import XCTest
@testable import eq

final class FocusTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private static let voiceSolo = #"{"solo":{"low":2000,"high":5000}}"#
    private static let cymbalsSolo = #"{"solo":{"low":6000,"high":16000}}"#
    private static let soloOff = #"{"solo":null}"#

    private func frame(solo: SoloRange? = nil, rate: Double = 44100) -> MeterFrame {
        var out = Array(repeating: -24.0, count: 10)
        out[5] = -9
        return MeterFrame(t: 0, device: "BE-RCA", rate: rate, in: Array(repeating: -60, count: 10), out: out,
                          peak: -6, limiting: false, gains: Config.screenshotCurve, preamp: -1.5, enabled: true, solo: solo)
    }

    private func line(_ f: MeterFrame) throws -> String {
        String(decoding: try MeterFrame.encodeLine(f).dropLast(), as: UTF8.self)
    }

    private func instrument(_ name: String) -> Instrument { Instruments.all.first { $0.name == name }! }

    private struct Run {
        var frames: [String] = []
        var edits: [WatchAction] = []
        var sent: [String] = []
        var code: Int32 = 0
    }

    /// One key (or none) after each frame; the source ends one frame after the last key.
    private func run(_ keys: [String?], zones: Bool = false, size: (Int, Int) = (100, 30),
                     failSend: Bool = false, rate: Double = 44100) throws -> Run {
        var result = Run()
        var queue = keys
        let text = try line(frame(rate: rate))
        let run = MeterHarness.run(lines: Array(repeating: text, count: keys.count + 1), size: { size }, zones: zones,
                                   readKey: { queue.isEmpty ? nil : queue.removeFirst() },
                                   edit: { result.edits.append($0) },
                                   send: { line in
                                       if failSend { throw MeterClient.Error.notServing }
                                       result.sent.append(line)
                                   })
        result.frames = run.drawn
        result.code = run.code
        return result
    }

    private func focusName(_ drawn: String) -> String? {
        guard let range = drawn.range(of: "focus: ") else { return nil }
        return String(drawn[range.upperBound...].prefix { $0 != " " })
    }

    func testFocusAndListenKeysOnBothLayouts() {
        for key in ["]", "\t", "ъ", "Ъ"] { XCTAssertEqual(WatchKeys.action(for: key), .focusNext, key) }
        for key in ["[", "х", "Х"] { XCTAssertEqual(WatchKeys.action(for: key), .focusPrevious, key) }
        for key in ["l", "L", "д", "Д"] { XCTAssertEqual(WatchKeys.action(for: key), .listen, key) }
        XCTAssertEqual(WatchKeys.actions(for: "\u{1B}"), [.unfocus])
    }

    func testArrowsAreParsedAndOtherSequencesIgnored() {
        XCTAssertEqual(WatchKeys.actions(for: "\u{1B}[A"), [.previousPreset])
        XCTAssertEqual(WatchKeys.actions(for: "\u{1B}[B"), [.cyclePreset])
        XCTAssertEqual(WatchKeys.actions(for: "\u{1B}OA"), [.previousPreset])
        XCTAssertEqual(WatchKeys.actions(for: "\u{1B}OB"), [.cyclePreset])
        XCTAssertEqual(WatchKeys.actions(for: "\u{1B}[B\u{1B}[B"), [.cyclePreset, .cyclePreset])
        XCTAssertEqual(WatchKeys.actions(for: "\u{1B}[C\u{1B}OC\u{1B}[D\u{1B}OD"), [.knob(0.5), .knob(0.5), .knob(-0.5), .knob(-0.5)])
        for reserved in ["\u{1B}[15~", "\u{1B}[1;2P", "\u{1B}x"] {
            XCTAssertEqual(WatchKeys.actions(for: reserved), [], reserved.debugDescription)
        }
        XCTAssertEqual(WatchKeys.actions(for: "1\u{1B}[Aq"), [.bandStep(0, 0.5), .previousPreset, .quit])
        XCTAssertEqual(WatchKeys.actions(for: "]\u{1B}"), [.focusNext, .unfocus], "a trailing lone ESC is the Esc key")
    }

    func testSelectionCyclesBothWaysAndEscClears() throws {
        let r = try run([nil, "]", "]", "[", "[", "\t", "\u{1B}", "х", "ъ"])
        XCTAssertEqual(r.frames.map(focusName), [nil, nil, "kick", "bass", "kick", "air", "kick", nil, "air", "kick"])
        XCTAssertTrue(r.frames[2].contains("focus: kick (50 Hz–5 kHz)"), r.frames[2])
        XCTAssertTrue(r.sent.isEmpty, "focus alone never solos")
    }

    func testEditOutsideTheFocusIsRefusedWithANote() throws {
        // `[` three times: air, cymbals, voice.
        let r = try run(["[", "[", "[", "1", "6", "\u{1B}", "1"])
        XCTAssertEqual(focusName(r.frames[3]), "voice")
        XCTAssertEqual(r.edits, [.bandStep(5, 0.5), .bandStep(0, 0.5)], "32 Hz is refused while voice is focused, allowed after Esc")
        XCTAssertTrue(r.frames[4].contains("outside voice — Esc to unfocus"), r.frames[4])
        XCTAssertTrue(r.frames[5].contains("outside voice"), "the note outlasts the next key")
    }

    func testListenSendsTheSpanAndFocusChangeResends() throws {
        let r = try run(["[", "[", "[", "l", "]", "l", "l", "\u{1B}"])
        XCTAssertEqual(r.sent, [Self.voiceSolo, Self.cymbalsSolo, Self.soloOff, Self.cymbalsSolo, Self.soloOff])
    }

    func testListenWithoutFocusSendsNothingAndSays() throws {
        let r = try run(["l", nil])
        XCTAssertEqual(r.sent, [])
        XCTAssertTrue(r.frames[1].contains(Watch.listenNeedsFocus), r.frames[1])
    }

    func testQuitClearsTheSolo() throws {
        let r = try run(["]", "l", "q"])
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.sent, [#"{"solo":{"low":50,"high":100}}"#, Self.soloOff], "kick's thump, its character range")
        let quiet = try run(["]", "q"])
        XCTAssertEqual(quiet.sent, [], "nothing to clear when listen never started")
    }

    func testListenToARangeTheRateCannotPlaySaysSo() throws {
        let call = try run(["[", "l", nil], rate: 16000)
        XCTAssertEqual(call.sent, [#"{"solo":{"low":10000,"high":20000}}"#], "still sent, so the daemon drops the previous solo")
        XCTAssertTrue(call.frames[2].contains(Watch.cannotListen(instrument("air"))), call.frames[2])
        let music = try run(["[", "l", nil])
        XCTAssertFalse(music.frames[2].contains("can't listen"), music.frames[2])
    }

    func testFailedSendLeavesListenOffAndSays() throws {
        let r = try run(["]", "l", "q"], failSend: true)
        XCTAssertTrue(r.frames[2].contains("listen: the daemon did not take the request"), r.frames[2])
    }

    func testSoloRequestIsTheDaemonsJSON() throws {
        XCTAssertEqual(Watch.soloRequest(instrument("voice").characterRange), Self.voiceSolo)
        XCTAssertEqual(Watch.soloRequest(HzRange(name: "x", low: 85.5, high: 900)), #"{"solo":{"low":85.5,"high":900}}"#)
        let decoded = try JSONDecoder().decode([String: SoloRange?].self, from: Data(Self.voiceSolo.utf8))
        XCTAssertEqual(decoded["solo"], SoloRange(low: 2000, high: 5000))
    }

    func testSoloFlagFollowsTheFrameInBrightYellow() {
        XCTAssertFalse(MeterScreens.lines(frame(), cols: 100, rows: 30)[0].contains("SOLO"))
        XCTAssertTrue(MeterScreens.lines(frame(solo: SoloRange(low: 85, high: 9000)), cols: 100, rows: 30)[0].contains(" SOLO "))
        let styled = MeterScreens.screen(MeterScreens.scene(frame(solo: SoloRange(low: 85, high: 9000)), cols: 100, rows: 30, depth: .ansi))
            .markedLines()[0]
        XCTAssertTrue(styled.contains("[1;7;93] SOLO "), "a chip of bright yellow, reversed: \(styled)")
    }

    func testFocusDimsBandsOutsideAndBrightensInside() {
        let scene = MeterScreens.scene(frame(), cols: 100, rows: 30, focus: instrument("cymbals"), depth: .ansi)
        let g = StudioView(scene: scene, compact: false).geometry
        let screen = MeterScreens.screen(scene)
        for band in 0..<10 {
            let cell = screen[g.centre(band), g.liveY]
            if band >= 8 {
                XCTAssertTrue(cell.style.attributes.contains(.bold), "band \(band) is focused")
            } else {
                XCTAssertTrue(cell.style.attributes.contains(.dim), "band \(band) is outside")
            }
            let label = screen[g.centre(band), g.liveY + 1].style
            XCTAssertEqual(label.attributes.contains(.dim), band < 8, "label \(band)")
        }
    }

    func testBracketMarksEachRangeOfTheFocus() throws {
        let scene = MeterScreens.scene(frame(), cols: 100, rows: 30, focus: instrument("voice"))
        let g = StudioView(scene: scene, compact: false).geometry
        let bracket = MeterScreens.screen(scene).lines()[try XCTUnwrap(g.bracketY)]
        XCTAssertEqual(bracket.filter { $0 == "┌" }.count, 5, bracket)
        XCTAssertEqual(bracket.filter { $0 == "┐" }.count, 5, bracket)
        XCTAssertTrue(bracket.contains("─ F1 ─"), "a name shows where its span has room: \(bracket)")
        XCTAssertFalse(bracket.contains("fundamental"), "and is left out where it has not")
        let start = Array(bracket).firstIndex(of: "┌")!
        XCTAssertEqual(start, Int(Strip.x(85, centres: g.centres).rounded()))
    }

    func testFocusedStripShowsOnlyThatInstrumentHighlighted() throws {
        let r = try run(["z", "[", "[", "[", nil], zones: false)
        XCTAssertTrue(r.frames[1].contains(" cym ") && r.frames[1].contains(" kck "), "strip on: every instrument")
        let focused = r.frames[4]
        XCTAssertFalse(focused.contains(" kck "), focused)
        XCTAssertTrue(focused.contains(" vox "), focused)
    }

    func testArrowsCyclePresetsAndWrap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-arrows-\(UUID().uuidString)")
        let ctx = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [] },
            defaultOutput: { ("SPK", "Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-27" })
        _ = try ctx.store.loadOrCreate(builtInUID: nil, builtInName: nil)
        func preset() throws -> String? { try ctx.store.load().profile(forDeviceUID: "SPK").profile.preset }
        let session = CLI.WatchSession(ctx)
        try session.apply(.cyclePreset)
        XCTAssertEqual(try preset(), "favourite", "↓ starts at the first preset")
        try session.apply(.previousPreset)
        XCTAssertEqual(try preset(), "flat", "↑ from the first preset wraps to the last")
        try session.apply(.cyclePreset)
        XCTAssertEqual(try preset(), "favourite", "↓ from the last preset wraps to the first")
        try session.apply(.previousPreset)
        try session.apply(.previousPreset)
        XCTAssertEqual(try preset(), "favourite")
    }

    func testArrowsInTheRunLoopAndNotInThePrompt() throws {
        let r = try run(["\u{1B}[B", "\u{1B}OA", "\u{1B}[C", "s", "\u{1B}[A", "\u{1B}[B", "a", "\n"])
        XCTAssertEqual(r.edits, [.cyclePreset, .previousPreset, .savePreset("a")])
        XCTAssertTrue(r.frames[6].contains("save as: ▏"), "arrows type nothing into the prompt: \(r.frames[6])")
    }

    private func render(cols: Int, rows: Int) -> [String] {
        MeterScreens.lines(frame(solo: SoloRange(low: 85, high: 9000)), cols: cols, rows: rows, strip: true, focus: instrument("voice"),
                           preset: ("favourite", true))
    }

    func testRenderingWithFocusStripAndSolo() {
        for (cols, rows) in [(100, 30), (60, 20)] {
            let lines = render(cols: cols, rows: rows)
            print("---- \(cols)×\(rows)\n" + lines.joined(separator: "\n") + "\n----")
            XCTAssertEqual(lines.count, rows)
            XCTAssertTrue(lines[0].contains("SOLO"), lines[0])
            XCTAssertTrue(lines[3].contains("┌"), "under the status bar and the tabs: \(lines[3])")
            XCTAssertTrue(lines.contains { $0.contains(" vox ") && $0.contains("━") }, lines.joined(separator: "\n"))
        }
        XCTAssertTrue(render(cols: 100, rows: 30)[0].contains("focus: voice (85 Hz–9 kHz)"))
    }

    func testSizeSweepNeverTrapsOrOverflows() {
        let voice = instrument("voice")
        for cols in stride(from: 1, through: 200, by: 3) {
            for rows in 1...60 {
                for focus in [nil, voice] {
                    let strip = (cols + rows) % 2 == 0
                    var scene = MeterScreens.scene(frame(solo: SoloRange(low: 85, high: 9000)), cols: cols, rows: rows, strip: strip,
                                                   focus: focus, modal: rows % 3 == 0 ? .help(scroll: 0) : nil,
                                                   note: "outside voice — Esc to unfocus", look: cols % 2 == 0 ? .studio : .console)
                    scene.peaks = Array(repeating: -3, count: 10)
                    scene.view = TUIView.allCases[(cols / 3 + rows) % TUIView.allCases.count]
                    scene.selected = rows % Instruments.all.count
                    scene.events.entries = Array(repeating: EventEntry(time: "12:00:00", kind: "device", text: "BE-RCA · 44.1 kHz", tone: .accent),
                                                 count: rows % 4)
                    scene.goMenu = rows % 5 == 0
                    if rows % 7 == 0 { scene.palette = CommandPalette(field: TextField("preset use f")) }
                    if rows % 4 == 1 { scene.child = ChildOutput(command: "zones", lines: ["a", "\u{1B}[1mb\u{1B}[0m"], shown: true) }
                    XCTAssertEqual(MeterScreens.screen(scene).lines().count, rows)
                }
            }
        }
    }

    func testClientSendsOverTheSocket() throws {
        let dir = URL(fileURLWithPath: "/tmp/eq-focus-\(getpid())-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "focus-test")
        let lock = NSLock()
        var solos: [SoloRange?] = []
        let server = MeterServer(socketURL: dir.appendingPathComponent("m.sock"), queue: queue, tick: 0.01,
                                 source: { MeterFrameTests.sample }, onClientsChanged: { _ in },
                                 onSolo: { range in lock.lock(); solos.append(range); lock.unlock(); return true })
        try server.start()
        defer { queue.sync { server.stop() } }
        let client = MeterClient(socketURL: dir.appendingPathComponent("m.sock"))
        try client.connect()
        try client.send(Self.voiceSolo)
        try client.send(Self.soloOff + "\n")
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, (lock.withLock { solos.count }) < 2 { usleep(5_000) }
        XCTAssertEqual(lock.withLock { solos }, [SoloRange(low: 2000, high: 5000), nil])
        client.close()
        XCTAssertThrowsError(try client.send(Self.soloOff), "a closed client refuses instead of writing to a stale fd")
    }
}
