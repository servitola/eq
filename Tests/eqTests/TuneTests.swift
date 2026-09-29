import EQTerm
import XCTest
@testable import eq

/// The Tune view: its keys on both layouts, the mouse, typed values, and its edits going through
/// the watch session into a scratch config.
final class TuneTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private static let frame = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: Array(repeating: -30, count: 10),
                                          out: Array(repeating: -20, count: 10), peak: -6, limiting: false,
                                          gains: Array(repeating: 0, count: 10), preamp: -1.5, enabled: true)

    private func key(_ text: String) -> [MeterMsg] { InputParser.events(in: text).map(MeterMsg.input) }

    private func model(size: Size = Size(cols: 120, rows: 36), look: Look = .studio) -> MeterModel {
        var settings = LookSettings()
        settings.look = look
        var m = MeterModel(size: size, reconnects: true, look: settings, view: .tune)
        _ = m.update(.frame(Self.frame))
        return m
    }

    @discardableResult
    private func send(_ model: inout MeterModel, _ msgs: [MeterMsg]) -> [MeterCmd] { msgs.flatMap { model.update($0) } }

    private static let up = "\u{1B}[A", down = "\u{1B}[B", right = "\u{1B}[C", left = "\u{1B}[D"

    func testGoTuneKeepsTheMeterConnection() {
        var m = MeterModel(size: Size(cols: 120, rows: 36), reconnects: true)
        _ = m.update(.frame(Self.frame))
        XCTAssertEqual(send(&m, key("gt")), [], "Tune draws levels")
        XCTAssertEqual(m.view, .tune)
        XCTAssertEqual(send(&m, key("\u{1B}")), [])
        XCTAssertEqual(m.view, .meter)
        XCTAssertEqual(KeyTable.action(for: .char("е"), in: .go), .go(.tune), "t's twin")
    }

    /// Spec M4's acceptance: every band lowered and raised from a Russian layout, no Shift.
    func testEveryBandGoesUpAndDownWithoutShiftOnEitherLayout() {
        var m = model()
        for band in 0..<10 {
            XCTAssertEqual(send(&m, key(Self.up)), [.edit(.adjust(.band(band), 0.5))], "band \(band) up")
            XCTAssertEqual(send(&m, key(Self.down)), [.edit(.adjust(.band(band), -0.5))], "band \(band) down")
            XCTAssertEqual(send(&m, key("о")), [.edit(.adjust(.band(band), -0.5))], "j's twin lowers it too")
            XCTAssertEqual(send(&m, key("л")), [.edit(.adjust(.band(band), 0.5))], "and k's raises it")
            send(&m, key(Self.right))
        }
        XCTAssertEqual(m.tune.selected, .preamp, "after the bands, the chain")
        send(&m, key(String(repeating: Self.right, count: 20)))
        XCTAssertEqual(m.tune.selected, .amount, "the last one holds")
        send(&m, key(String(repeating: Self.left, count: 30)))
        XCTAssertEqual(m.tune.selected, .band(0))
    }

    func testShiftPageAndAltStepCoarseAndFine() {
        var m = model()
        send(&m, key(Self.right))
        XCTAssertEqual(send(&m, key("\u{1B}[1;2A")), [.edit(.adjust(.band(1), 3))])
        XCTAssertEqual(send(&m, key("\u{1B}[6~")), [.edit(.adjust(.band(1), -3))])
        XCTAssertEqual(send(&m, key("\u{1B}[1;3B")), [.edit(.adjust(.band(1), -0.1))])
        XCTAssertEqual(send(&m, key("\u{1B}[1;5A")), [.edit(.adjust(.band(1), 0.5))], "Ctrl is a plain arrow")
        XCTAssertEqual(KeyTable.action(for: .shiftUp, in: .meter), .previousPreset, "on the meter a Shift arrow is its arrow, as before")
    }

    func testEachControlStepsInItsOwnUnits() {
        XCTAssertEqual(TuneControl.tilt.delta(0.5), 0.1)
        XCTAssertEqual(TuneControl.tilt.delta(-3), -0.5)
        XCTAssertEqual(TuneControl.amount.delta(0.1), 0.05)
        XCTAssertEqual(TuneControl.comp.delta(-0.5), -1)
        XCTAssertEqual(TuneControl.preamp.delta(3), 3)
    }

    func testZeroBackspaceAndDeleteReset() {
        var m = model()
        for reset in ["0", "\u{7F}", "\u{08}", "\u{1B}[3~"] {
            XCTAssertEqual(send(&m, key(reset)), [.edit(.assign(.band(0), 0))], reset.debugDescription)
        }
        XCTAssertEqual(send(&m, key("1")), [.edit(.bandStep(0, 0.5))], "the other digits keep their meter meaning")
        XCTAssertEqual(send(&m, key("^")), [.edit(.bandStep(5, -0.5))])
        XCTAssertEqual(send(&m, key(":")), [.edit(.bandStep(5, -0.5))], "and Russian ⇧6 lowers 1 kHz here too")
    }

    func testEnterTakesATypedValue() {
        var m = model()
        send(&m, key(String(repeating: Self.right, count: 5)))
        XCTAssertEqual(send(&m, key("\r")), [])
        XCTAssertEqual(m.scene()?.keyContext, .entry)
        XCTAssertTrue(m.lines()![34].hasPrefix(" 1 kHz dB: "), m.lines()![34])
        XCTAssertEqual(send(&m, key("-3,5q\u{7F}\r")), [.edit(.assign(.band(5), -3.5))], "q types into the field, a comma is a point")
        send(&m, key("\rloud\r"))
        XCTAssertTrue(m.message?.text.contains("not a value for 1 kHz") == true, "\(String(describing: m.message))")
        send(&m, key("\t\t"))
        XCTAssertEqual(m.tune.selected, .comp)
        XCTAssertEqual(send(&m, key("\rnight\r")), [.edit(.assign(.comp, 2))])
        XCTAssertEqual(send(&m, key("\r\u{1B}")), [], "Esc cancels the field")
        XCTAssertNil(m.entry)
        XCTAssertEqual(m.view, .tune, "and stays")
    }

    func testTabWalksTheGroupsAndEachKeepsItsSelection() {
        var m = model()
        send(&m, key(Self.right + Self.right))
        send(&m, key("\t"))
        XCTAssertEqual(m.tune.selected, .preamp)
        send(&m, key(Self.right))
        send(&m, key("\t"))
        XCTAssertEqual(m.tune.selected, .comp)
        send(&m, key("\t"))
        XCTAssertEqual(m.tune.selected, .band(2), "back to the band it left")
        send(&m, key("\u{1B}[Z"))
        XCTAssertEqual(m.tune.selected, .comp, "⇧Tab goes the other way")
        send(&m, key("\u{1B}[Z"))
        XCTAssertEqual(m.tune.selected, .bass)
    }

    func testAClickSelectsAndTheWheelSteps() throws {
        for look in Look.allCases {
            var m = model(look: look)
            let l = try XCTUnwrap(TuneView.layout(m.size))
            send(&m, [.input(.mouse(Mouse(.press, button: .left, x: l.centre(7), y: l.top + 2)))])
            XCTAssertEqual(m.tune.selected, .band(7), "\(look)")
            XCTAssertEqual(send(&m, [.input(.mouse(Mouse(.wheelDown, x: l.centre(3) + 1, y: l.top)))]), [.edit(.adjust(.band(3), -0.5))])
            XCTAssertEqual(m.tune.selected, .band(3))
            let comp = try XCTUnwrap(TuneView.places(l, console: look == .console).first { $0.control == .comp }).rect
            XCTAssertEqual(send(&m, [.input(.mouse(Mouse(.wheelUp, x: comp.x + 2, y: comp.y)))]), [.edit(.adjust(.comp, 1))], "\(look)")
            XCTAssertEqual(send(&m, [.input(.mouse(Mouse(.wheelUp, x: 0, y: 0)))]), [.edit(.adjust(.comp, 1))],
                           "the wheel elsewhere steps the selection")
            let tab = TabRow.layout(width: 120, current: .tune).first { $0.view == .events }!.columns
            send(&m, [.input(.mouse(Mouse(.press, button: .left, x: tab.lowerBound + 1, y: 1)))])
            XCTAssertEqual(m.view, .events, "the tabs still switch")
        }
    }

    func testTheHintSaysWhatIsSelected() {
        var m = model()
        XCTAssertTrue(m.message?.text.hasPrefix("32 Hz selected — ↑↓ 0.5 dB") == true)
        send(&m, key("\t\t"))
        XCTAssertTrue(m.message?.text.hasPrefix("comp — ↑↓ off · gentle · night") == true)
        _ = m.update(.edited(.adjust(.amount, 0.1), failure: "colour is off — pick tape or tube first"))
        XCTAssertEqual(m.message, MeterScene.Message(text: "colour is off — pick tape or tube first", kind: .error), "a refusal wins")
    }

    func testAnEditedBandFlashes() {
        var m = model()
        _ = m.update(.edited(.adjust(.band(4), 0.5), failure: nil))
        XCTAssertEqual(m.flash?.value, 4)
    }

    func testEveryLayoutFitsAndTheListTakesOverWhenSmall() {
        for (cols, rows) in [(120, 36), (80, 24), (61, 16), (200, 60), (110, 20)] {
            let l = TuneView.layout(Size(cols: cols, rows: rows))
            XCTAssertNotNil(l, "\(cols)×\(rows)")
            guard let l else { continue }
            XCTAssertLessThan(l.meterY, l.bands.bottom - 1, "\(cols)×\(rows)")
            XCTAssertLessThanOrEqual(l.chain.bottom, rows - 2, "\(cols)×\(rows)")
            XCTAssertLessThanOrEqual(l.chain.right, cols, "\(cols)×\(rows)")
            XCTAssertLessThanOrEqual(l.x0 + l.cell * 10, l.bands.right - 1, "\(cols)×\(rows)")
            for place in TuneView.places(l, console: true) + TuneView.places(l, console: false) {
                XCTAssertTrue(l.chain.inset(by: 1).intersection(place.rect) == place.rect, "\(cols)×\(rows) \(place.control)")
            }
        }
        XCTAssertNil(TuneView.layout(Size(cols: 60, rows: 24)))
        var m = model(size: Size(cols: 50, rows: 16))
        send(&m, key(Self.down + Self.down))
        let lines = m.lines()!
        XCTAssertTrue(lines.contains { $0.contains("▸ 32 Hz") }, lines.joined(separator: "\n"))
    }

    // MARK: The session

    private func context() throws -> CLIContext {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-tune-\(UUID().uuidString)")
        let ctx = CLIContext(store: ConfigStore(url: dir.appendingPathComponent("eq.json")), statusURL: dir.appendingPathComponent("status.json"),
                             connectedDevices: { [] }, defaultOutput: { ("SPK", "Speakers") }, fetch: { _ in throw URLError(.notConnectedToInternet) },
                             cacheDirectory: dir.appendingPathComponent("cache"), today: { "2026-09-29" })
        _ = try ctx.store.loadOrCreate(builtInUID: nil, builtInName: nil)
        return ctx
    }

    private func profile(_ ctx: CLIContext) throws -> Profile { try ctx.store.load().profile(forDeviceUID: "SPK").profile }

    func testEditsSaveAtOnceAsOneUndoStepAndUWalksBack() throws {
        let ctx = try context()
        let start = try ctx.store.load()
        let first = try profile(ctx).bands[9]
        let session = CLI.WatchSession(ctx)
        try session.apply(.adjust(.band(9), -0.5))
        try session.apply(.adjust(.band(9), -3))
        try session.apply(.assign(.preamp, -6.25))
        try session.apply(.adjust(.tilt, 0.1))
        try session.apply(.adjust(.comp, 1))
        try session.apply(.adjust(.colour, 1))
        try session.apply(.adjust(.amount, 0.3))
        let p = try profile(ctx)
        XCTAssertEqual(p.bands[9], first - 3.5)
        XCTAssertEqual(p.preamp, -6.25)
        XCTAssertEqual(p.preference?.tilt, 0.1)
        XCTAssertEqual(p.dynamics?.comp, .gentle)
        XCTAssertEqual(p.dynamics?.color, .init(kind: .tape, amount: 0.6))
        XCTAssertEqual(session.header().profile?.bands[9], first - 3.5, "the header carries the whole curve")
        XCTAssertEqual(ctx.store.backups().map(\.index), [1], "only the session's first save backs up")
        try session.apply(.undo)
        XCTAssertEqual(try profile(ctx).dynamics?.color?.amount, 0.3)
        for _ in 0..<6 { try session.apply(.undo) }
        XCTAssertEqual(try ctx.store.load().devices, start.devices, "u walks back to how the session started")
        XCTAssertEqual(try profile(ctx).bands[9], first)
    }

    func testRangesHoldAndResetsTurnThingsOff() throws {
        let ctx = try context()
        let session = CLI.WatchSession(ctx)
        for _ in 0..<6 { try session.apply(.adjust(.band(0), 3)) }
        XCTAssertEqual(try profile(ctx).bands[0], 12, "held at the top")
        XCTAssertThrowsError(try session.apply(.assign(.band(0), 15))) { XCTAssertTrue("\($0)".contains("outside -12.0…+12.0 dB"), "\($0)") }
        XCTAssertThrowsError(try session.apply(.adjust(.amount, 0.1))) { XCTAssertTrue("\($0)".contains("colour is off")) }
        try session.apply(.adjust(.comp, 1))
        try session.apply(.adjust(.comp, 1))
        try session.apply(.adjust(.comp, 1))
        XCTAssertEqual(try profile(ctx).dynamics?.comp, .night, "the last mode holds")
        try session.apply(.assign(.colour, 2))
        try session.apply(.adjust(.amount, -3))
        XCTAssertEqual(try profile(ctx).dynamics?.color, .init(kind: .tube, amount: 0.05), "an amount never steps to nothing")
        try session.apply(.assign(.comp, 0))
        try session.apply(.assign(.amount, 0))
        XCTAssertNil(try profile(ctx).dynamics, "0 turns both off")
        try session.apply(.adjust(.tilt, -3))
        try session.apply(.adjust(.tilt, -3))
        try session.apply(.adjust(.tilt, -3))
        XCTAssertEqual(try profile(ctx).preference?.tilt, -1.2)
        try session.apply(.assign(.tilt, 0))
        XCTAssertNil(try profile(ctx).preference)
    }

    func testTypedWordsAndNumbers() {
        XCTAssertEqual(TuneControl.comp.parse("Night"), 2)
        XCTAssertEqual(TuneControl.comp.parse("off"), 0)
        XCTAssertEqual(TuneControl.colour.parse("tube"), 2)
        XCTAssertEqual(TuneControl.band(0).parse("+2,5 dB"), 2.5)
        XCTAssertNil(TuneControl.band(0).parse("loud"))
    }

    /// The chain's headroom: a boost over 0 dBFS with the preamp says so on screen.
    func testClippingIsShown() {
        var m = model()
        var header = Watch.Header()
        header.profile = Profile(name: nil, preamp: 0, bands: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        _ = m.update(.header(header))
        XCTAssertTrue(m.lines()![2].contains("! clips +6.0 dB"), m.lines()![2])
        header.profile?.preamp = -7
        _ = m.update(.header(header))
        XCTAssertFalse(m.lines()![2].contains("clips"))
        XCTAssertTrue(m.lines().map { $0.joined() }?.contains("1.0 dB spare") == true)
    }
}
