import Darwin
import EQTerm
import XCTest
@testable import eq

/// The shell around the views: tabs, `g`, the command palette and its child processes, the
/// Events and Instruments views, and the meter connection held only where levels show.
final class TUIShellTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private static let frame = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: Array(repeating: -30, count: 10),
                                          out: Array(repeating: -20, count: 10), peak: -6, limiting: false,
                                          gains: Array(repeating: 0, count: 10), preamp: -1.5, enabled: true)

    private func key(_ text: String) -> [MeterMsg] {
        InputParser.events(in: text).map(MeterMsg.input)
    }

    private func model(view: TUIView = .meter, size: Size = Size(cols: 120, rows: 36)) -> MeterModel {
        var m = MeterModel(size: size, reconnects: true, view: view)
        _ = m.update(.frame(Self.frame))
        return m
    }

    @discardableResult
    private func send(_ model: inout MeterModel, _ msgs: [MeterMsg]) -> [MeterCmd] {
        msgs.flatMap { model.update($0) }
    }

    // MARK: Views and the meter connection

    func testTheMeterConnectionFollowsTheView() {
        var m = model()
        XCTAssertEqual(send(&m, key("ge")), [.disconnect], "the Events view draws no levels")
        XCTAssertFalse(m.meterOpen)
        XCTAssertEqual(send(&m, key("gi")), [.connect], "the Instruments view does")
        _ = m.update(.connected)
        XCTAssertEqual(send(&m, key("\u{1B}")), [.disconnect], "Esc went back to Events")
        XCTAssertEqual(m.view, .events)
        XCTAssertEqual(send(&m, key("\u{1B}")), [.connect])
        XCTAssertEqual(m.view, .meter, "and back again: the stack")
    }

    func testASoloKeepsTheMeterConnectionOnTheEventsView() {
        var m = model()
        send(&m, key("]l"))
        XCTAssertTrue(m.listening)
        XCTAssertEqual(send(&m, key("ge")), [], "the solo lives on the meter connection")
        XCTAssertTrue(m.meterOpen)
    }

    func testAViewWithoutLevelsTakesOneFrameThenLetsGo() {
        var m = MeterModel(size: Size(cols: 120, rows: 36), reconnects: true, view: .events)
        XCTAssertNotNil(m.lines(), "a status bar before any frame")
        XCTAssertEqual(m.update(.frame(Self.frame)), [.disconnect], "the frame gave the status bar its preamp and gains")
        XCTAssertFalse(m.lines()![0].contains("peak"), "peak and LIMIT come only with frames: \(m.lines()![0])")
        var profile = EventEntry(time: "10:00:00", kind: "profile", text: "", tone: .boost)
        profile.effect = .profile
        XCTAssertEqual(m.update(.event(profile)), [.refreshHeader, .connect], "a new curve: one more frame for it")
        _ = m.update(.connected)
        XCTAssertEqual(m.update(.frame(Self.frame)), [.disconnect])
    }

    func testARetryOffTheMeterViewStops() {
        var m = model()
        _ = m.update(.meterClosed)
        send(&m, key("ge"))
        XCTAssertEqual(m.update(.retry), [], "nobody is looking at levels")
        XCTAssertNil(m.retry)
    }

    func testStillLevelsBuildNoScreen() {
        var m = model()
        for _ in 0..<MeterModel.peakHoldFrames + 60 { _ = m.update(.frame(Self.frame)) }
        var next = Self.frame
        next.t = 99
        _ = m.update(.frame(next))
        XCTAssertFalse(m.needsRedraw, "the same levels, peaks settled, nothing counting down")
        next.out[3] = -10
        _ = m.update(.frame(next))
        XCTAssertTrue(m.needsRedraw)
        _ = m.update(.input(.key(KeyPress(.char("z")))))
        XCTAssertTrue(m.needsRedraw, "a key always draws")
    }

    func testAClickOnATabGoesThere() {
        var m = model()
        let events = TabRow.layout(width: 120, current: .meter).first { $0.view == .events }!.columns
        XCTAssertEqual(send(&m, [.input(.mouse(Mouse(.press, button: .left, x: events.lowerBound + 2, y: 1)))]), [.disconnect])
        XCTAssertEqual(m.view, .events)
        send(&m, [.input(.mouse(Mouse(.press, button: .left, x: 3, y: 5)))])
        XCTAssertEqual(m.view, .events, "only the tab row switches")
        XCTAssertEqual(TabRow.layout(width: 50, current: .events).map(\.view), [.events], "narrow: the current one only")
    }

    func testTheTabRowAndItsHint() {
        let lines = model().lines()!
        XCTAssertTrue(lines[1].hasPrefix("  Meter   Tune   Instruments   Presets   Devices   Filters   Events "), lines[1])
        XCTAssertTrue(lines[1].hasSuffix("g go  ; cmd "), lines[1])
        let short = model(size: Size(cols: 80, rows: 13)).lines()!
        XCTAssertFalse(short[1].contains("Instruments"), "below 14 rows the meter keeps the row")
    }

    // MARK: Instruments view

    func testInstrumentsViewEditsTheSelectedKnobAndFocusesOnEnter() {
        var m = model(view: .instruments)
        XCTAssertEqual(send(&m, key("jj\u{1B}[C")), [.edit(.boost("snare", 0.5))], "no focus needed: the row is the instrument")
        XCTAssertEqual(send(&m, key("б")), [.edit(.boost("snare", -0.5))], "the Russian , on the same key")
        XCTAssertEqual(send(&m, key("\r")), [])
        XCTAssertEqual(m.view, .meter)
        XCTAssertEqual(m.focused?.name, "snare")
    }

    func testListenFromTheInstrumentsViewFocusesAndSolos() {
        var m = model(view: .instruments)
        let cmds = send(&m, key("kkkkkkkkl"))
        XCTAssertEqual(cmds, [.send(Watch.soloRequest(Instruments.all[0].characterRange))])
        XCTAssertEqual(m.focused?.name, "kick")
        XCTAssertEqual(send(&m, key("l")), [.send(Watch.soloRequest(nil))], "l again stops it")
    }

    func testTheSelectedInstrumentStaysInSight() {
        XCTAssertEqual(InstrumentsView.offset(selected: 0, visible: 5), 0)
        let voice = Instruments.all.firstIndex { $0.name == "voice" }!
        let first = Instruments.all.prefix(voice).reduce(0) { $0 + $1.ranges.count }
        let offset = InstrumentsView.offset(selected: voice, visible: 8)
        XCTAssertLessThanOrEqual(offset, first)
        XCTAssertGreaterThanOrEqual(offset + 8, first + 5, "all five voice ranges show")
    }

    // MARK: Events view

    func testEventsDecodeWithTheirColourAndWhatTheyChange() {
        let device = EventEntry.decode(#"{"t":1,"event":"device","device":"AirPods","uid":"a","transport":"Bluetooth","rate":48000}"#)
        XCTAssertEqual(device?.text, "AirPods · Bluetooth · 48 kHz")
        XCTAssertEqual(device?.effect, .device("AirPods", rate: 48000))
        XCTAssertEqual(EventEntry.decode(#"{"t":1,"event":"enabled","enabled":false}"#)?.tone, .warn)
        XCTAssertEqual(EventEntry.decode(#"{"t":1,"event":"solo","solo":null}"#)?.effect, .solo(nil))
        XCTAssertEqual(EventEntry.decode(#"{"t":1,"event":"daemon","state":"failed","version":"1","error":"no device"}"#)?.tone, .danger)
        XCTAssertNil(EventEntry.decode(#"{"t":1,"device":"BE-RCA","rate":44100}"#), "an old daemon's meter frame")
        XCTAssertNil(EventEntry.decode("not json"))
    }

    func testTheStatusBarFollowsEventsOffTheMeter() {
        var m = model()
        send(&m, key("ge"))
        _ = m.update(.event(EventEntry.decode(#"{"t":1,"event":"device","device":"AirPods","uid":"a","transport":"Bluetooth","rate":48000}"#)!))
        _ = m.update(.event(EventEntry.decode(#"{"t":2,"event":"enabled","enabled":false}"#)!))
        let top = m.lines()![0]
        XCTAssertTrue(top.contains("AirPods") && top.contains("48.0 kHz") && top.contains("BYPASS"), top)
        XCTAssertTrue(m.lines()!.contains { $0.contains("device   AirPods · Bluetooth · 48 kHz") })
    }

    func testTheLogPausesFiltersAndScrolls() {
        var m = model(view: .events)
        let line = { (n: Int) in EventEntry(time: "10:00:\(n)", kind: n % 2 == 0 ? "rate" : "solo", text: "event \(n)", tone: .plain) }
        for n in 0..<60 { _ = m.update(.event(line(n))) }
        send(&m, key(" "))
        for n in 60..<63 { _ = m.update(.event(line(n))) }
        var shown = m.lines()!.joined(separator: "\n")
        XCTAssertTrue(shown.contains("paused · 3 new"), shown)
        XCTAssertFalse(shown.contains("event 62"))
        send(&m, key(" /sol"))
        XCTAssertEqual(m.events.filter, "sol")
        send(&m, key("\r"))
        shown = m.lines()!.joined(separator: "\n")
        XCTAssertTrue(shown.contains("event 61") && !shown.contains("event 62"), "live again, rate lines filtered out")
        send(&m, key("\u{1B}[5~"))
        XCTAssertGreaterThan(m.events.scroll, 0, "PgUp goes back in time")
        send(&m, key("\u{1B}[F"))
        XCTAssertEqual(m.events.scroll, 0, "End: the newest")
        send(&m, key("\u{1B}"))
        XCTAssertEqual(m.events.filter, "", "Esc clears the filter first")
        XCTAssertEqual(m.view, .events)
    }

    // MARK: Command palette

    func testFuzzyMatchingPrefersStartsOfWords() {
        XCTAssertNotNil(CommandPalette.fuzzy("pu", "preset use <name>"))
        XCTAssertNil(CommandPalette.fuzzy("zx", "zones"))
        let best = CommandPalette(field: TextField("zon")).suggestions(values: [:]).items.first
        XCTAssertEqual(best?.text, "zones")
        XCTAssertEqual(best?.action, .zones, "the screen's action, from the key table")
        XCTAssertEqual(CommandPalette.words(#"import "HD 600" --source opra"#), ["import", "HD 600", "--source", "opra"])
    }

    func testEveryCommandFormIsOffered() {
        let texts = CommandPalette.commands.map(\.text)
        for form in ["status", "preset use <name>", "device copy --to DEVICE", "filter add <type> <freq> <gain> <q>", "import --clear",
                     "boost <instrument> <gain>", "comp night"] {
            XCTAssertTrue(texts.contains(form), form)
        }
        XCTAssertFalse(CommandPalette.commands.first { $0.text == "preset use <name>" }!.runnable)
        XCTAssertTrue(CommandPalette.commands.first { $0.text == "boost <instrument> <gain>" }!.runnable, "alone it lists the knobs")
        XCTAssertTrue(CommandPalette.commands.first { $0.text == "import --clear" }!.runnable)
        XCTAssertEqual(CommandPalette.stem("device copy --to DEVICE"), "device copy --to ")
    }

    func testOperandsCompleteFromTheirKind() {
        XCTAssertEqual(CommandPalette.operand(after: ["preset", "use"])?.kind, .presets)
        XCTAssertEqual(CommandPalette.operand(after: ["device", "copy", "--to"])?.kind, .devices)
        XCTAssertEqual(CommandPalette.operand(after: ["set"])?.kind, .bands)
        XCTAssertEqual(CommandPalette.operand(after: ["set", "64hz"])?.kind, Completions.Kind.none)
        XCTAssertEqual(CommandPalette.operand(after: ["boost"])?.kind, .instruments)
        XCTAssertNil(CommandPalette.operand(after: ["status"]))
        let bands = CommandPalette(field: TextField("set 1k")).suggestions(values: [:])
        XCTAssertEqual(bands.items.first?.text, "set 1khz", "bands need no fetching")
        let save = CommandPalette(field: TextField("preset save nig")).suggestions(values: [.presets: ["nightly"]])
        XCTAssertFalse(save.prefersFirst, "a new name is the point of save")
    }

    func testThePaletteRunsAPresetAndTheStatusBarFollows() {
        var m = model()
        XCTAssertEqual(send(&m, key(";")), [])
        XCTAssertEqual(m.scene()?.keyContext, .palette)
        XCTAssertEqual(send(&m, key("preset use ")), [.complete(.presets)], "values are fetched once, when first needed")
        XCTAssertEqual(send(&m, [.completions(.presets, ["favourite", "flat"])] + key("fav")), [])
        XCTAssertTrue(m.lines()!.contains { $0.contains("▸ preset use favourite") }, m.lines()!.joined(separator: "\n"))
        let cmds = send(&m, key("\r"))
        XCTAssertEqual(cmds, [.saveHistory(["eq preset use favourite"]), .run(["preset", "use", "favourite"], columns: OutputPane.columns(m.size))])
        XCTAssertNil(m.palette)
        XCTAssertTrue(m.lines()![34].contains("running eq preset use favourite"), m.lines()![34])
        XCTAssertEqual(send(&m, [.childOutput("\u{1B}[1mfavourite\u{1B}[0m on BE-RCA"), .childClosed]), [.reap])
        XCTAssertEqual(m.update(.childExit(0)), [.refreshHeader])
        XCTAssertNil(m.child, "one line: said in the message row, no pane")
        XCTAssertTrue(m.lines()![34].contains("✓ favourite on BE-RCA"), m.lines()![34])
        _ = m.update(.header(Watch.Header(preset: ("favourite", false))))
        XCTAssertTrue(m.lines()![0].contains("◆ favourite"), m.lines()![0])
        XCTAssertEqual(m.history, ["eq preset use favourite"])
        send(&m, key(";"))
        XCTAssertEqual(m.palette?.suggestions(values: [:]).items.first?.text, "eq preset use favourite", "the last run comes first")
        send(&m, key("\u{1B};zones\r"))
        XCTAssertEqual(m.history, ["zones", "eq preset use favourite"], "a screen action is kept by its name")
        XCTAssertTrue(m.strip)
        send(&m, key(";\r"))
        XCTAssertFalse(m.strip, "run again from the history, it is the action again, not eq zones")
        XCTAssertNil(m.child)
    }

    func testATemplateFillsTheLineInsteadOfRunning() {
        var m = model()
        send(&m, key(";device cop"))
        XCTAssertEqual(send(&m, key("\r")), [.complete(.devices)])
        XCTAssertEqual(m.palette?.field.text, "device copy --to ")
    }

    func testLongOutputOpensThePaneAndEscStopsARunningCommand() {
        var m = model()
        send(&m, key(";eq zones\r"))
        XCTAssertEqual(m.child?.command, "zones")
        send(&m, [.childOutput("kick"), .childOutput("bass")])
        XCTAssertEqual(m.child?.shown, true)
        XCTAssertEqual(m.scene()?.keyContext, .pane)
        XCTAssertTrue(m.lines()!.contains { $0.contains("╭─ eq zones ") && $0.contains("running · 2 lines") })
        XCTAssertEqual(send(&m, key("\u{03}")), [.stop], "Ctrl-C stops the command, not the TUI")
        XCTAssertEqual(send(&m, key("q")), [.stop], "q closes the pane, which stops it")
        XCTAssertNil(m.child)
        XCTAssertEqual(m.update(.childExit(143)), [], "a closed pane has nothing left to say")
    }

    func testStreamingCommandsPointAtTheirView() {
        var m = model()
        XCTAssertEqual(send(&m, key(";events\r")), [])
        XCTAssertNil(m.child)
        XCTAssertTrue(m.lines()![34].contains("eq events streams: it is the Events view here — g e"), m.lines()![34])
    }

    func testEqInFrontMeansTheCommandNotTheScreensAction() {
        XCTAssertEqual(CommandPalette(field: TextField("zones")).suggestions(values: [:]).items.first?.action, .zones)
        let command = CommandPalette(field: TextField("eq zones")).suggestions(values: [:]).items.first
        XCTAssertEqual(command?.text, "zones")
        XCTAssertNil(command?.action)
    }

    func testThePalettesOwnKeysNeverReachTheView() {
        var m = model()
        XCTAssertEqual(send(&m, key(";q1z")), [])
        XCTAssertFalse(m.strip)
        XCTAssertEqual(m.palette?.field.text, "q1z")
        XCTAssertEqual(send(&m, key("\u{03}")), [], "Ctrl-C closes the palette")
        XCTAssertNil(m.palette)
    }

    // MARK: The child, for real

    private static var binary: URL { Bundle(for: TUIShellTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("eq") }

    /// A scratch config, status and cache: the child never sees ~/.config/eq.
    private func scratch() throws -> (dir: URL, environment: [String: String]) {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.binary.path), "no built eq beside the tests")
        let dir = URL(fileURLWithPath: "/tmp/eq-shell-\(getpid())-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ConfigStore(url: dir.appendingPathComponent("eq.json"))
        _ = try store.loadOrCreate(builtInUID: nil, builtInName: nil)
        try Status(state: .running, device: .init(uid: "BE", name: "BE-RCA", transport: "usb"), sampleRate: 44100, profile: .device,
                   framesProcessed: 1, callbacks: 1, writes: 1, enabled: true, error: nil, pid: getpid(), version: Build.version,
                   updatedAt: Date(), apps: nil)
            .write(to: dir.appendingPathComponent("status.json"))
        var environment = ["PATH": "/usr/bin:/bin", "HOME": dir.path, "TERM": "xterm-256color", "CLICOLOR_FORCE": "1",
                           "EQ_CONFIG": dir.appendingPathComponent("eq.json").path, "EQ_STATUS": dir.appendingPathComponent("status.json").path,
                           "EQ_CACHE": dir.appendingPathComponent("cache").path]
        environment["LANG"] = "en_US.UTF-8"
        return (dir, environment)
    }

    func testAChildPaintsItsPipeAndLaysOutForThePane() throws {
        let (dir, environment) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = ChildRunner(executable: Self.binary.path, environment: environment)
        let fd = try XCTUnwrap(runner.start(["zones"], columns: 50))
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 200) >= 0 else { break }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { output += chunk.prefix(n) } else if n == 0 { break }
        }
        var code: Int32?
        while code == nil, Date() < deadline { code = runner.reap(); if code == nil { usleep(10_000) } }
        XCTAssertEqual(code, 0)
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains("\u{1B}[1mkick"), "CLICOLOR_FORCE paints a pipe: \(text.debugDescription)")
    }

    func testPresetUseFromThePaletteReachesTheStatusBar() throws {
        let (dir, environment) = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = CLIContext(store: ConfigStore(url: dir.appendingPathComponent("eq.json")), statusURL: dir.appendingPathComponent("status.json"),
                             connectedDevices: { [] }, defaultOutput: { nil }, fetch: { _ in throw URLError(.notConnectedToInternet) },
                             cacheDirectory: dir.appendingPathComponent("cache"), today: { "2026-09-29" })
        let session = CLI.WatchSession(ctx)
        XCTAssertNil(session.header().preset)
        let effects = MeterEffects(edit: session.apply, header: session.header, send: { _ in }, mouse: { _ in }, connect: { nil },
                                   complete: { Completions.names($0, ctx) },
                                   children: ChildRunner(executable: Self.binary.path, environment: environment))
        var pipes: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&pipes), 0)
        defer { close(pipes[0]); close(pipes[1]) }
        var model = MeterModel(size: Size(cols: 120, rows: 36), header: session.header(), reconnects: true)
        _ = model.update(.frame(Self.frame))
        let runtime = Runtime(model, size: model.size, translate: MeterEffects.translate, perform: { cmd, runtime in
            let msgs = effects.perform(cmd, runtime)
            if msgs.contains(where: { if case .childExit = $0 { return true } else { return false } }) { runtime.quit(0) }
            return msgs
        }, output: { _ in })
        runtime.inputFD = pipes[0]
        let typed = ";preset use favourite\r"
        _ = write(pipes[1], typed, typed.utf8.count)
        let started = Date()
        XCTAssertEqual(runtime.run(), 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(runtime.program.header.preset?.name, "favourite", "read again once the child ended")
        XCTAssertTrue(runtime.program.lines()![0].contains("◆ favourite"), runtime.program.lines()![0])
        XCTAssertEqual(try ctx.store.load().profile(forDeviceUID: "BE").profile.preset, "favourite", "the scratch config, not ~/.config")
    }
}
