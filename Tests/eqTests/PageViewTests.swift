import EQTerm
import XCTest
@testable import eq

/// The Apps, System and History views as a program: keys and clicks in, the edits, reads and
/// children they ask for out; and what they read, from a scratch context.
final class PageViewTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private static let frame = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: Array(repeating: -30, count: 10),
                                          out: Array(repeating: -20, count: 10), peak: -6, limiting: false,
                                          gains: Array(repeating: 0, count: 10), preamp: -1.5, enabled: true)

    private func key(_ text: String) -> [MeterMsg] { InputParser.events(in: text).map(MeterMsg.input) }

    /// A view with the goldens' data, as if every read had come back.
    private func model(_ view: TUIView, size: Size = Size(cols: 120, rows: 36)) -> MeterModel {
        let data = TUILookTests.pages(TUILookTests.scene(cols: size.cols, rows: size.rows, view: view)) { _ in }
        var m = MeterModel(size: size, reconnects: true, view: view)
        _ = m.update(.frame(Self.frame))
        _ = m.update(.library(data.library))
        _ = m.update(.running(data.running))
        _ = m.update(.system(data.system))
        _ = m.update(.history(data.versions))
        _ = m.update(.header(Watch.Header(preset: ("favourite", true), profile: TUILookTests.playing)))
        m.doctor = data.doctor
        return m
    }

    @discardableResult
    private func send(_ model: inout MeterModel, _ msgs: [MeterMsg]) -> [MeterCmd] { msgs.flatMap { model.update($0) } }

    private static let up = "\u{1B}[A", down = "\u{1B}[B", right = "\u{1B}[C", left = "\u{1B}[D"
    private static let doctor = MeterCmd.job(.doctor, ["doctor", "--json"])

    // MARK: Going there

    func testGoLettersReadWhatEachViewShows() {
        var m = MeterModel(size: Size(cols: 120, rows: 36), reconnects: true)
        _ = m.update(.frame(Self.frame))
        XCTAssertEqual(send(&m, key("ga")), [.disconnect, .refreshLibrary, .refreshApps], "rules, presets, and the apps with audio open")
        XCTAssertEqual(send(&m, key("пы")), [.refreshSystem, Self.doctor], "g s from a Russian layout; the doctor runs once")
        XCTAssertEqual(m.view, .system)
        XCTAssertEqual(send(&m, key("пр")), [.refreshHistory], "g h: р is h's key")
        XCTAssertEqual(m.view, .history)
        XCTAssertEqual(send(&m, key("\u{1B}")), [.refreshSystem], "back on System: the doctor is still running, not started again")
        for name in ["go apps", "go system", "go history"] {
            XCTAssertTrue(KeyTable.named.contains { $0.name == name }, name)
        }
        var opened = MeterModel(size: Size(cols: 120, rows: 36), view: .system)
        XCTAssertEqual(opened.update(.start).suffix(2), [.refreshSystem, Self.doctor])
    }

    func testEscBackShowsOnlyWithSomewhereToGo() {
        var m = MeterModel(size: Size(cols: 120, rows: 36), reconnects: true, view: .presets)
        _ = m.update(.library(TUILookTests.library))
        XCTAssertFalse(m.lines()!.last!.contains("Esc"), "eq tui presets: nothing to go back to")
        send(&m, key("gd"))
        XCTAssertTrue(m.lines()!.last!.contains(" Esc  back"), m.lines()!.last!)
        send(&m, key("ge"))
        send(&m, key("\u{1B}"))
        send(&m, key("\u{1B}"))
        XCTAssertEqual(m.view, .presets)
        XCTAssertFalse(m.lines()!.last!.contains("Esc"))
    }

    // MARK: Apps

    func testAddingARuleFromTheAppsPlayingThenAPreset() {
        var m = model(.apps)
        XCTAssertEqual(send(&m, key("a")), [.refreshApps])
        XCTAssertEqual(m.scene()?.keyContext, .picker)
        send(&m, key("chr"))
        XCTAssertEqual(m.lines()![34], " app: chr▏" + String(repeating: " ", count: 110))
        XCTAssertEqual(send(&m, key("\r")), [])
        XCTAssertEqual(m.picker?.stage, .preset(app: "com.google.Chrome", name: "Chrome"))
        XCTAssertTrue(m.lines()!.contains { $0.contains("a preset for Chrome") })
        XCTAssertEqual(send(&m, key("ni" + Self.down + "\r")), [.edit(.setAppRule("com.google.Chrome", "night"))], "↓ past the last stays on it")
        XCTAssertNil(m.picker)
        send(&m, key("a"))
        XCTAssertEqual(send(&m, key("com.example.Player\r\r")), [.edit(.setAppRule("com.example.Player", "favourite"))],
                       "an app not playing is taken as typed, for eq app set to resolve")
        send(&m, key("a\u{1B}"))
        XCTAssertNil(m.picker, "Esc cancels")
        XCTAssertEqual(m.view, .apps)
    }

    func testEnterGivesARuleAnotherPresetAndDRemovesItAfterAYes() {
        var m = model(.apps)
        send(&m, key("j\r"))
        XCTAssertEqual(m.picker?.stage, .preset(app: "com.apple.Music", name: "com.apple.Music"))
        XCTAssertEqual(m.picker?.chosen, m.library.presetNames.firstIndex(of: "late jazz"), "the rule's own preset chosen first")
        XCTAssertEqual(send(&m, key(Self.up + "\r")), [.edit(.setAppRule("com.apple.Music", "flat"))])
        send(&m, key("kd"))
        XCTAssertEqual(m.confirm?.question, "remove the rule Spotify → night? Spotify plays now: the device's curve comes back. y removes")
        XCTAssertEqual(send(&m, key("y")), [.edit(.removeAppRule("com.spotify.client"))])
        XCTAssertEqual(send(&m, key("o")), [.edit(.followApps(false))])
        _ = m.update(.edited(.followApps(false), failure: nil))
        XCTAssertEqual(m.message?.text, "apps off: the device's curve plays whatever plays")
        _ = m.update(.edited(.setAppRule("com.google.Chrome", "night"), failure: nil))
        XCTAssertEqual(m.message?.text, "Chrome → night")
    }

    func testTheAppHeardNowFollowsTheEvents() {
        var m = model(.apps)
        XCTAssertTrue(m.lines()![4].contains("◉ Spotify") && m.lines()![4].contains("heard now"), m.lines()![4])
        send(&m, [.event(EventEntry.decode(#"{"event":"app","app":"com.google.Chrome","name":"Chrome","preset":"podcast"}"#)!)])
        XCTAssertEqual(m.library.heard, AppMatch(app: "com.google.Chrome", name: "Chrome", preset: "podcast"))
        XCTAssertTrue(m.lines()![6].contains("◉ Chrome") && m.lines()![6].contains("heard now"), m.lines()![6])
        XCTAssertFalse(m.lines()![4].contains("heard now"))
        send(&m, [.event(EventEntry.decode(#"{"event":"app","app":"com.google.Chrome","name":"Chrome"}"#)!)])
        XCTAssertNil(m.library.heard)
        XCTAssertNil(m.last?.app, "the status bar leaves the app too")
    }

    func testRoutesAreShownReadOnlyWithWhyNoneRuns() {
        var m = model(.apps)
        var library = m.library
        library.driver = Library.Driver(name: "BE-RCA · EQ", target: DeviceChoice(uid: "be", name: "BE-RCA"))
        send(&m, [.library(library)])
        let text = m.lines()!.joined(separator: "\n")
        XCTAssertTrue(text.contains("routes · read-only") && text.contains("AirPods › BE-RCA"), text)
        XCTAssertTrue(text.contains("! " + RoutePolicy.driverNote), text)
        library.routes = []
        send(&m, [.library(library)])
        XCTAssertFalse(m.lines()!.joined().contains("routes"), "no routes in eq.json: no section")
    }

    // MARK: System

    func testTheDoctorsReportComesFromItsChild() throws {
        var m = MeterModel(size: Size(cols: 120, rows: 36), reconnects: true, view: .system)
        _ = m.update(.start)
        _ = m.update(.system(TUILookTests.driverSystem))
        XCTAssertTrue(m.lines()!.joined().contains("running eq doctor …"))
        let json = CLI.encode(DoctorReport(ok: false, checks: TUILookTests.driverChecks))
        send(&m, json.split(separator: "\n").map { .jobOutput(.doctor, String($0)) })
        XCTAssertEqual(send(&m, [.jobClosed(.doctor)]), [.reapJob(.doctor)])
        send(&m, [.jobExit(.doctor, 1)])
        XCTAssertEqual(m.doctor.report?.checks, TUILookTests.driverChecks)
        XCTAssertFalse(m.doctor.running)
        let lines = m.lines()!
        XCTAssertTrue(lines.contains { $0.contains("! driver update") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("writer   ✓ writes accepted") }, "the writer check beside the driver's health")
        XCTAssertEqual(send(&m, key("r")), [.refreshSystem, Self.doctor])
        XCTAssertEqual(send(&m, key("r")), [.refreshSystem], "not twice at once")
        send(&m, [.jobOutput(.doctor, "error: something broke"), .jobExit(.doctor, 1)])
        XCTAssertEqual(m.doctor.failure, "error: something broke")
        XCTAssertEqual(m.doctor.report?.checks.count, TUILookTests.driverChecks.count, "the last report stays")
    }

    func testSwitchingModeAsksADryRunThenTheQuestion() {
        var m = model(.system)
        m.system = TUILookTests.tapSystem
        XCTAssertEqual(send(&m, key("o")), [.job(.modePlan, ["mode", "driver", "--dry-run", "--json"])])
        XCTAssertEqual(send(&m, key("o")), [], "one at a time")
        let plan = #"{"dryRun":true,"driver":{"installed":true},"from":"tap","mode":"driver","output":{"name":"BE-RCA","uid":"be"}}"#
        send(&m, [.jobOutput(.modePlan, plan), .jobExit(.modePlan, 0)])
        XCTAssertEqual(m.confirm?.question, "switch to driver mode? BE-RCA · EQ becomes the system output and plays on BE-RCA. y switches")
        let cmds = send(&m, key("y"))
        XCTAssertEqual(cmds.last, .run(["mode", "driver"], columns: OutputPane.columns(m.size)), "eq mode driver as a child, its output in the pane")
        XCTAssertEqual(m.child?.command, "mode driver")
        send(&m, [.childOutput("mode: tap → driver"), .childOutput("BE-RCA · EQ is the default output")])
        XCTAssertEqual(send(&m, [.childExit(0)]).suffix(2), [.refreshSystem, Self.doctor], "the status and the doctor read again")
        XCTAssertEqual(m.child?.status, 0, "the pane stays up with what it printed")

        m = model(.system)
        m.system = TUILookTests.tapSystem
        send(&m, key("o"))
        let install = #"{"dryRun":true,"install":{"action":"install","elevation":"dialog"},"mode":"driver"}"#
        send(&m, [.jobOutput(.modePlan, install), .jobExit(.modePlan, 0)])
        XCTAssertNil(m.confirm, "an install is never started from here")
        XCTAssertTrue(m.message?.text.contains("administrator password") == true, "\(String(describing: m.message))")
        send(&m, key("o"))
        send(&m, [.jobOutput(.modePlan, #"{"error":{"code":"mode","message":"cannot switch to driver: the EQ driver is not installed"}}"#),
                  .jobExit(.modePlan, 1)])
        XCTAssertEqual(m.message, MeterScene.Message(text: "cannot switch to driver: the EQ driver is not installed", kind: .error))

        m = model(.system)
        XCTAssertEqual(send(&m, key("o")), [.job(.modePlan, ["mode", "tap", "--dry-run", "--json"])], "driver mode offers tap")
        send(&m, [.jobOutput(.modePlan, #"{"mode":"tap","dryRun":true}"#), .jobExit(.modePlan, 0)])
        XCTAssertTrue(m.confirm?.question.hasPrefix("switch to tap mode?") == true)
        XCTAssertEqual(send(&m, key("n")), [])
        XCTAssertNil(m.child)
    }

    func testSearchJumpsAndEscGoesBack() {
        var m = model(.system)
        send(&m, key("/clock"))
        XCTAssertEqual(m.doctor.report?.checks[m.lists.check].name, "driver clock")
        XCTAssertEqual(m.scene()?.keyContext, .search)
        send(&m, key("\u{1B}"))
        XCTAssertEqual(m.lists.check, 0)
        m = model(.presets)
        send(&m, key("/NI\r"))
        XCTAssertEqual(m.selectedPreset, "night", "any case")
        XCTAssertNil(m.search)
        send(&m, key("/qqq\r"))
        XCTAssertEqual(m.selectedPreset, "night", "no match stays")
        m = model(.apps)
        send(&m, key("/podcast\r"))
        XCTAssertEqual(m.selectedRule?.app, "com.google.Chrome", "by preset too")
    }

    // MARK: History

    func testHistoryRestoresAVersionAndStepsLikeUndoAndRedo() {
        var m = model(.history)
        XCTAssertEqual(m.lists.version, 2, "the live version chosen first")
        XCTAssertTrue(m.lines()![6].contains("◉  2"), m.lines()![6])
        XCTAssertEqual(send(&m, key("\r")), [])
        XCTAssertEqual(m.message?.text, "version 2 is the live one")
        XCTAssertEqual(send(&m, key("jj\r")), [.edit(.restoreVersion(4))])
        XCTAssertEqual(send(&m, key(Self.left)), [.edit(.restoreVersion(3))], "← is eq undo: one older than the live one")
        XCTAssertEqual(m.lists.version, 3)
        XCTAssertEqual(send(&m, key(Self.right)), [.edit(.restoreVersion(1))], "→ is eq redo")
        XCTAssertEqual(m.update(.edited(.restoreVersion(1), failure: nil)), [.refreshHeader, .refreshHistory])
        XCTAssertTrue(m.message?.text.hasPrefix("restored version 1 from 09-30 09:40:12") == true, "\(String(describing: m.message))")
        XCTAssertEqual(send(&m, key("\u{1B}[F\r")), [], "version 6 cannot be read")
        XCTAssertEqual(m.message?.kind, .error)
        var list = TUILookTests.versions
        list.position = 0
        send(&m, [.history(list)])
        XCTAssertEqual(send(&m, key(Self.right)), [])
        XCTAssertEqual(m.message?.text, "this is the latest version")
    }

    func testTheListsReadTheirDataFromAScratchContext() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-pages-\(UUID().uuidString)")
        let ctx = CLIContext(store: ConfigStore(url: dir.appendingPathComponent("eq.json")), statusURL: dir.appendingPathComponent("status.json"),
                             connectedDevices: { [("be", "BE-RCA", "usb")] }, defaultOutput: { ("be", "BE-RCA") },
                             fetch: { _ in throw URLError(.notConnectedToInternet) }, cacheDirectory: dir, today: { "2026-09-30" })
        XCTAssertEqual(CLI.historyList(ctx).versions, [], "no file, no history")
        var config = try ctx.store.loadOrCreate(builtInUID: "be", builtInName: "BE-RCA")
        config.mode = .driver
        config.apps = [AppRule(app: "com.spotify.client", preset: "flat")]
        config.setFollowsApps(true)
        config.routes = [RouteRule(app: "com.google.Chrome", outputs: ["AirPods"])]
        try ctx.store.save(config)
        for gain in ["+1", "+2"] { XCTAssertEqual(CLI.run(["set", "64hz", gain], context: ctx).exitCode, 0) }
        XCTAssertEqual(CLI.run(["undo"], context: ctx).exitCode, 0)
        let history = CLI.historyList(ctx)
        XCTAssertEqual(history.position, 1)
        XCTAssertEqual(history.versions.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(history.versions[0].profile?.bands[1], 2)
        XCTAssertEqual(history.live?.profile?.bands[1], 1)
        XCTAssertEqual(history.device, "BE-RCA")
        let info = CLI.systemInfo(ctx)
        XCTAssertNil(info.status, "no daemon")
        XCTAssertEqual(info.mode, .driver)
        let library = CLI.library(ctx)
        XCTAssertTrue(library.followsApps)
        XCTAssertFalse(library.followsRoutes)
        XCTAssertEqual(library.routes.map(\.app), ["com.google.Chrome"])
    }

    func testJobsHaveTheirOwnSources() {
        guard case .jobOutput(.doctor, "{")? = MeterEffects.translate(.line(source: MeterJob.doctor.rawValue, "{")) else { return XCTFail("doctor line") }
        guard case .jobClosed(.modePlan)? = MeterEffects.translate(.closed(source: MeterJob.modePlan.rawValue)) else { return XCTFail("mode closed") }
        guard case .jobClosed(.doctor)? = MeterEffects.translate(.timer(MeterJob.doctor.rawValue)) else { return XCTFail("reap timer") }
        guard case .retry? = MeterEffects.translate(.timer(MeterEffects.retryTimer)) else { return XCTFail("retry timer") }
        XCTAssertNil(MeterEffects.translate(.line(source: 99, "x")))
    }

    // MARK: Keys, the mouse, small screens

    func testAFieldsValueCanBeTyped() {
        var m = MeterModel(size: Size(cols: 120, rows: 36), reconnects: true, view: .filters)
        _ = m.update(.frame(Self.frame))
        _ = m.update(.header(Watch.Header(profile: TUILookTests.playing)))
        send(&m, key("\r" + Self.right + Self.right))
        XCTAssertEqual(m.lists.field, .gain)
        send(&m, key("-"))
        XCTAssertEqual(m.scene()?.keyContext, .entry)
        XCTAssertTrue(m.lines()![34].hasPrefix(" gain: -▏"), m.lines()![34])
        var f = TUILookTests.playing.filters[0]
        f.gain = -4.5
        XCTAssertEqual(send(&m, key("4,5\r")), [.edit(.setFilter(0, f))], "as eq filter set gain=-4,5 reads it")
        send(&m, key("=bogus\r"))
        XCTAssertEqual(m.message?.kind, .error)
        send(&m, key("\u{1B}"))
        send(&m, key("a\t2k\r"))
        XCTAssertEqual(m.form?.filter.frequency, 2000)
        send(&m, key("\u{1B}[Z=lowshelf\r"))
        XCTAssertEqual(m.form?.filter.type, .lowShelf)
        XCTAssertEqual(m.form?.filter.q, CLI.defaultQ(for: .lowShelf), "a typed type takes its default Q as a stepped one does")
    }

    func testTheKeyListFilters() {
        var m = model(.system)
        send(&m, key("?/mode"))
        XCTAssertEqual(m.modal, .help(scroll: 0, filter: "mode"))
        let text = m.lines()!.joined(separator: "\n")
        XCTAssertTrue(text.contains("“mode” · system view") && text.contains("switch to the other mode"), text)
        XCTAssertFalse(text.contains("the command palette"), text)
        send(&m, key("\r"))
        XCTAssertEqual(m.modal?.filter, "mode", "Enter keeps it")
        send(&m, key("/\u{1B}"))
        XCTAssertEqual(m.modal, .help(scroll: 0), "Esc drops it")
        send(&m, key("/qqqqq"))
        XCTAssertTrue(m.lines()!.joined().contains("no key has “qqqqq”"))
    }

    func testAClickSelectsARowOnEachPage() {
        var m = model(.apps)
        send(&m, [.input(.mouse(Mouse(.press, button: .left, x: 10, y: 6)))])
        XCTAssertEqual(m.lists.app, 2)
        send(&m, key("gh"))
        let l = HistoryView.split(m.size)
        send(&m, [.input(.mouse(Mouse(.press, button: .left, x: l.list.x + 5, y: l.list.y + 2 + 5)))])
        XCTAssertEqual(m.lists.version, 5)
        send(&m, key("gs"))
        send(&m, [.input(.mouse(Mouse(.press, button: .left, x: 60, y: 3 + 4)))])
        XCTAssertEqual(m.lists.check, 4)
        XCTAssertEqual(m.doctor.report?.checks[4].name, "output")
    }

    func testEveryPageFitsEverySize() {
        for view in [TUIView.apps, .system, .history] {
            for (cols, rows) in [(20, 8), (40, 12), (59, 16), (60, 14), (80, 24), (99, 30), (200, 60)] {
                for look in Look.allCases {
                    var m = model(view, size: Size(cols: cols, rows: rows))
                    m.look.look = look
                    if view == .apps { send(&m, key("a")) }
                    let lines = m.lines()!
                    XCTAssertEqual(lines.count, rows, "\(view) \(cols)×\(rows)")
                    XCTAssertTrue(lines.allSatisfy { TerminalText.width($0) == cols }, "\(view) \(cols)×\(rows) \(look)")
                }
            }
        }
    }

    func testTheTabsFitNarrowerTerminals() {
        XCTAssertEqual(TabRow.layout(width: 120, current: .meter).count, 10)
        let tight = TabRow.layout(width: 80, current: .history)
        XCTAssertEqual(tight.count, 10)
        XCTAssertEqual(tight.filter(\.padded).map(\.view), [.history])
        let short = TabRow.layout(width: 60, current: .apps)
        XCTAssertEqual(short.map(\.title), ["Met", "Tun", "Ins", "Pre", "Dev", "Fil", "Apps", "Sys", "His", "Eve"])
        XCTAssertLessThanOrEqual(short.last!.columns.upperBound, 60)
    }
}
