import EQTerm
import XCTest
@testable import eq

/// The Presets, Devices and Filters views as a program: keys and clicks in, the edits they ask
/// the session for out; Tune's other device; and the library they list, read from a scratch context.
final class ListViewTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private static let frame = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: Array(repeating: -30, count: 10),
                                          out: Array(repeating: -20, count: 10), peak: -6, limiting: false,
                                          gains: Array(repeating: 0, count: 10), preamp: -1.5, enabled: true)

    private func key(_ text: String) -> [MeterMsg] { InputParser.events(in: text).map(MeterMsg.input) }

    private func model(_ view: TUIView, size: Size = Size(cols: 120, rows: 36)) -> MeterModel {
        var m = MeterModel(size: size, reconnects: true, view: view)
        _ = m.update(.frame(Self.frame))
        _ = m.update(.library(TUILookTests.library))
        _ = m.update(.header(Watch.Header(preset: ("favourite", true), profile: TUILookTests.playing)))
        return m
    }

    @discardableResult
    private func send(_ model: inout MeterModel, _ msgs: [MeterMsg]) -> [MeterCmd] { msgs.flatMap { model.update($0) } }

    private static let up = "\u{1B}[A", down = "\u{1B}[B", right = "\u{1B}[C", left = "\u{1B}[D"

    // MARK: Going there

    func testGoLettersAreThePhysicalKeys() {
        var m = MeterModel(size: Size(cols: 120, rows: 36), reconnects: true)
        _ = m.update(.frame(Self.frame))
        XCTAssertEqual(send(&m, key("gp")), [.disconnect, .refreshLibrary], "no levels on a list, and the presets read")
        XCTAssertEqual(m.view, .presets)
        XCTAssertEqual(send(&m, key("пв")), [.refreshLibrary], "g d from a Russian layout")
        XCTAssertEqual(m.view, .devices)
        XCTAssertEqual(send(&m, key("па")), [], "Filters list the header's curve: nothing to read")
        XCTAssertEqual(m.view, .filters)
        XCTAssertEqual(send(&m, key("пз")), [.refreshLibrary])
        XCTAssertEqual(m.view, .presets)
        XCTAssertEqual(TUIView.allCases.map(\.title), ["Meter", "Tune", "Instruments", "Presets", "Devices", "Filters", "Events"])
        for name in ["go presets", "go devices", "go filters", "add filter"] { XCTAssertTrue(KeyTable.named.contains { $0.name == name }, name) }
    }

    func testEqTuiOpensOnAList() {
        var m = MeterModel(size: Size(cols: 120, rows: 36), reconnects: true, view: .devices)
        XCTAssertEqual(m.update(.start), [.connectEvents, .refreshLibrary])
    }

    // MARK: Presets

    func testPresetsApplySaveRenameAndDeleteAfterAYes() {
        var m = model(.presets)
        XCTAssertEqual(m.selectedPreset, "favourite")
        XCTAssertEqual(send(&m, key("jjj\r")), [.edit(.usePreset("night"))])
        send(&m, key("r"))
        XCTAssertEqual(m.scene()?.keyContext, .rename)
        XCTAssertTrue(m.lines()![34].hasPrefix(" rename night to: night"), m.lines()![34])
        XCTAssertEqual(send(&m, key("\u{17}late\r")), [.edit(.renamePreset("night", "late"))], "Ctrl-W clears the old name")
        XCTAssertEqual(m.lists.follow, "late", "selected again once the presets are read")
        send(&m, [.library({ var l = TUILookTests.library; l.presets["late"] = l.presets.removeValue(forKey: "night"); return l }())])
        XCTAssertEqual(m.selectedPreset, "late")
        XCTAssertEqual(send(&m, key("d")), [])
        XCTAssertEqual(m.scene()?.keyContext, .confirm)
        XCTAssertTrue(m.confirm?.question.hasPrefix("delete preset late?") == true, m.confirm?.question ?? "")
        XCTAssertEqual(send(&m, key("q")), [], "any key but y keeps it, q included")
        XCTAssertNil(m.confirm)
        XCTAssertEqual(send(&m, key("вн")), [.edit(.removePreset("late"))], "d then y from a Russian layout")
        XCTAssertEqual(send(&m, key("sclub\r")), [.edit(.savePreset("club"))])
        XCTAssertEqual(m.lists.follow, "club")
    }

    func testDeletingAPresetSaysWhatItLeaves() {
        var m = model(.presets)
        send(&m, key("jjjd"))
        XCTAssertEqual(m.confirm?.question, "delete preset night? AirPods keeps its curve, unmarked. 1 app rule will match nothing. y deletes")
        XCTAssertTrue(m.lines()![34].contains("? delete preset night?"), m.lines()![34])
        XCTAssertTrue(m.lines()![35].hasPrefix(" y  yes   n  no"), m.lines()![35])
    }

    func testDoneEditsSayWhatHappenedAndReadTheLibraryAgain() {
        var m = model(.presets)
        XCTAssertEqual(m.update(.edited(.usePreset("night"), failure: nil)), [.refreshHeader, .refreshLibrary])
        XCTAssertEqual(m.message, MeterScene.Message(text: "night plays on BE-RCA", kind: .ok))
        _ = m.update(.edited(.renamePreset("night", "flat"), failure: "preset \"flat\" already exists"))
        XCTAssertEqual(m.message?.kind, .error)
    }

    func testDiffShowsBothCurvesAndWhatDiffers() {
        var m = model(.presets)
        send(&m, key("jjjv"))
        XCTAssertTrue(m.lists.diff)
        let text = m.lines()!.joined(separator: "\n")
        XCTAssertTrue(text.contains("vs BE-RCA, faint") && text.contains("differs"), text)
        XCTAssertTrue(text.contains("1k        -3.1 →  -1.0"), text)
        XCTAssertTrue(Keybar.line(.presets, state: m.scene()!.keyState, width: 200).contains("v diff on"))
    }

    // MARK: Devices

    func testDevicesUseCopyAndEdit() {
        var m = model(.devices)
        XCTAssertEqual(send(&m, key("j\r")), [.edit(.useDevice("mbp"))])
        XCTAssertEqual(send(&m, key("c")), [.edit(.copyCurve(DeviceChoice(uid: "mbp", name: "MacBook Pro Speakers")))])
        XCTAssertEqual(send(&m, key("kc")), [], "the playing device's curve is the one copied")
        XCTAssertTrue(m.message?.text.contains("is the device playing") == true)
        XCTAssertEqual(send(&m, key("G\r")), [], "G is g: the menu; Enter leaves it")
        send(&m, key("jjjj\r"))
        XCTAssertTrue(m.message?.text.contains("Old DAC is not connected") == true, "\(String(describing: m.message))")
        let airpods = DeviceChoice(uid: "air", name: "AirPods")
        XCTAssertEqual(send(&m, key("kke")), [.connect, .target(airpods), .refreshLibrary])
        _ = m.update(.connected)
        XCTAssertEqual(m.view, .tune)
        XCTAssertEqual(m.editing, airpods)
        for _ in 0...Watch.noteFrames { _ = m.update(.frame(Self.frame)) }
        XCTAssertTrue(m.message?.text.hasPrefix("editing AirPods, not the device playing") == true, "\(String(describing: m.message))")
        XCTAssertTrue(m.lines()![2].contains("response · AirPods"), m.lines()![2])
        XCTAssertEqual(TuneView.profile(m.scene()!), TUILookTests.library.devices["air"], "Tune shows AirPods' own curve")
        XCTAssertEqual(send(&m, key("\u{1B}")), [.target(nil), .disconnect, .refreshLibrary], "leaving Tune edits the playing device again")
        XCTAssertNil(m.editing)
        XCTAssertEqual(m.update(.edited(.useDevice("air"), failure: nil)), [.refreshHeader, .refreshLibrary])
        XCTAssertEqual(m.message?.text, "output → AirPods")
    }

    func testInDriverModeTheEQDeviceIsShownButNeverPicked() {
        var m = model(.devices)
        var library = TUILookTests.library
        library.driver = Library.Driver(name: "BE-RCA · EQ", target: DeviceChoice(uid: "be", name: "BE-RCA"))
        send(&m, [.library(library)])
        let lines = m.lines()!
        XCTAssertTrue(lines[4].contains("EQ BE-RCA · EQ system output → BE-RCA"), lines[4])
        XCTAssertTrue(lines[5].contains("◉ ▪ BE-RCA"), lines[5])
        XCTAssertEqual(send(&m, key("\r")), [], "the first row is a real device, the one already playing")
        XCTAssertEqual(m.message?.text, "BE-RCA already plays")
        XCTAssertEqual(send(&m, key("j\r")), [.edit(.useDevice("mbp"))])
        _ = m.update(.edited(.useDevice("air"), failure: nil))
        XCTAssertEqual(m.message?.text, "the EQ device plays on AirPods now")
    }

    func testTheLibraryLeavesTheEQDeviceOutAndSeesDriverMode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-library-\(UUID().uuidString)")
        let ctx = CLIContext(store: ConfigStore(url: dir.appendingPathComponent("eq.json")), statusURL: dir.appendingPathComponent("status.json"),
                             connectedDevices: { [(DriverControl.deviceUID, "BE-RCA · EQ", "virtual"), ("be", "BE-RCA", "usb"),
                                                  ("mbp", "MacBook Pro Speakers", "builtin")] },
                             defaultOutput: { (DriverControl.deviceUID, "BE-RCA · EQ") },
                             fetch: { _ in throw URLError(.notConnectedToInternet) }, cacheDirectory: dir, today: { "2026-09-30" })
        _ = try ctx.store.loadOrCreate(builtInUID: "mbp", builtInName: "MacBook Pro Speakers")
        var status = Status(state: .running, device: .init(uid: "be", name: "BE-RCA", transport: "usb"), sampleRate: 44100, profile: .default,
                            framesProcessed: 1, callbacks: 1, writes: 1, enabled: true, error: nil, pid: getpid(), version: Build.version,
                            updatedAt: Date(), apps: nil)
        status.mode = .driver
        status.driver = Status.DriverStatus(deviceName: "BE-RCA · EQ", target: .init(uid: "be", name: "BE-RCA", transport: "usb"), isDefault: true,
                                            ioRunning: true, eqActive: true, underruns: 0, overruns: 0, clockPpm: 0, latencyMs: nil, hidden: false)
        try status.write(to: ctx.statusURL)
        let library = CLI.library(ctx)
        XCTAssertEqual(library.rows.map(\.uid), ["be", "mbp"])
        XCTAssertEqual(library.current, DeviceChoice(uid: "be", name: "BE-RCA"))
        XCTAssertEqual(library.driver, Library.Driver(name: "BE-RCA · EQ", target: DeviceChoice(uid: "be", name: "BE-RCA")))
        XCTAssertEqual(library.presetNames, ["favourite", "flat"])
        XCTAssertEqual(library.rows.first?.profile, "default")
    }

    // MARK: Filters

    func testAFiltersFieldsChangeInPlaceAndSaveAtOnce() {
        var m = model(.filters)
        send(&m, key("j"))
        XCTAssertEqual(send(&m, key("\r")), [])
        XCTAssertEqual(m.scene()?.keyContext, .fields)
        XCTAssertEqual(m.lists.field, .type)
        var f = TUILookTests.playing.filters[1]
        f.type = .lowShelf
        XCTAssertEqual(send(&m, key(Self.up)), [.edit(.setFilter(1, f))], "↑ on the type: the next one")
        send(&m, key(Self.right + Self.right))
        f = TUILookTests.playing.filters[1]
        f.gain = -2.7
        XCTAssertEqual(send(&m, key("k")), [.edit(.setFilter(1, f))])
        f.gain = -6.2
        XCTAssertEqual(send(&m, key("\u{1B}[1;2B")), [.edit(.setFilter(1, f))], "⇧↓: 3 dB")
        f.gain = -3.3
        XCTAssertEqual(send(&m, key("\u{1B}[1;3B")), [.edit(.setFilter(1, f))], "Alt↓: 0.1 dB")
        XCTAssertTrue(m.message?.text.hasPrefix("gain — ↑↓ 0.5 dB") == true)
        send(&m, key(Self.left))
        f = TUILookTests.playing.filters[1]
        f.frequency = 2360
        XCTAssertEqual(send(&m, key(Self.up)), [.edit(.setFilter(1, f))], "a sixth of an octave, to three digits")
        send(&m, key("\u{1B}"))
        XCTAssertNil(m.lists.field)
        XCTAssertEqual(m.view, .filters, "Esc leaves the fields, not the view")
        XCTAssertEqual(send(&m, key("j")), [])
        XCTAssertEqual(m.lists.filter, 2, "↓ moves between filters again")
    }

    func testAddingAFilterInline() {
        var m = model(.filters)
        send(&m, key("a"))
        XCTAssertEqual(m.scene()?.keyContext, .form)
        XCTAssertTrue(m.lines()!.contains { $0.contains("peak") && $0.contains("1 kHz   +0.0 dB   1.41   new") }, m.lines()!.joined(separator: "\n"))
        send(&m, key(Self.up))
        XCTAssertEqual(m.form?.filter.type, .lowShelf)
        XCTAssertEqual(m.form?.filter.q, 0.707, "a new type takes its own default Q")
        send(&m, key("\t" + Self.up + Self.up + "\t" + "\u{1B}[1;2B"))
        let added = Filter(type: .lowShelf, frequency: 1260, gain: -3, q: 0.707, origin: .hand)
        XCTAssertEqual(m.form?.filter, added)
        XCTAssertEqual(send(&m, key("\r")), [.edit(.addFilter(added))])
        XCTAssertNil(m.form)
        send(&m, [.header(Watch.Header(profile: { var p = TUILookTests.playing; p.filters.append(added); return p }()))])
        XCTAssertEqual(m.lists.filter, 4, "the new one is selected")
        send(&m, key("a\u{1B}"))
        XCTAssertNil(m.form, "Esc cancels")
        XCTAssertEqual(m.view, .filters)
    }

    func testRemovingAFilterAsksFirst() {
        var m = model(.filters)
        send(&m, key("jjd"))
        XCTAssertEqual(m.confirm?.question, "remove filter 3, highshelf 10 kHz +2.0 dB Q 0.70, imported? y removes")
        XCTAssertEqual(send(&m, key("y")), [.edit(.removeFilter(2))])
        var profile = TUILookTests.playing
        profile.filters = [profile.filters[0], profile.filters[3]]
        send(&m, [.header(Watch.Header(profile: profile)), .input(.key(KeyPress(.char("d"))))])
        XCTAssertEqual(m.confirm?.question, "remove filter 2, peak 3 kHz -2.0 dB Q 1.41? y removes")
        send(&m, key("nkd"))
        XCTAssertTrue(m.confirm?.question.contains("The import label goes with it.") == true, m.confirm?.question ?? "")
    }

    func testNoFiltersNothingToEdit() {
        var m = model(.filters)
        var profile = TUILookTests.playing
        profile.filters = []
        send(&m, [.header(Watch.Header(profile: profile))])
        XCTAssertEqual(send(&m, key("\rd")), [])
        XCTAssertNil(m.lists.field)
        XCTAssertNil(m.confirm)
        XCTAssertTrue(m.lines()!.contains { $0.contains("no filters — a adds one") })
    }

    func testFieldSteps() {
        var f = Filter(type: .bandPass, frequency: 10, gain: 29.8, q: 0.1)
        FilterField.type.step(&f, 0.5)
        XCTAssertEqual(f.type, .peak, "the types wrap round")
        FilterField.frequency.step(&f, -0.5)
        XCTAssertEqual(f.frequency, 10, "held at 10 Hz")
        FilterField.frequency.step(&f, 0.1)
        XCTAssertEqual(f.frequency, 10.3)
        FilterField.gain.step(&f, 3)
        XCTAssertEqual(f.gain, 30)
        FilterField.q.step(&f, -0.1)
        XCTAssertEqual(f.q, 0.1)
        XCTAssertEqual(FilterField.threeDigits(12345), 12300)
        XCTAssertEqual(FilterField.threeDigits(1122.46), 1120)
    }

    // MARK: The mouse and small screens

    func testAClickSelectsARow() {
        var m = model(.presets)
        let l = SplitLayout(m.size)
        send(&m, [.input(.mouse(Mouse(.press, button: .left, x: l.list.x + 5, y: l.list.y + 2 + 3)))])
        XCTAssertEqual(m.selectedPreset, "night")
        send(&m, key("gd"))
        send(&m, [.input(.mouse(Mouse(.press, button: .left, x: l.list.x + 8, y: l.list.y + 2 + 2)))])
        XCTAssertEqual(m.selectedDevice?.name, "AirPods")
        send(&m, key("gf"))
        let table = FiltersView.layout(m.size, rows: 4).table
        send(&m, [.input(.mouse(Mouse(.press, button: .left, x: table.x + 10, y: table.y + 2 + 3)))])
        XCTAssertEqual(m.lists.filter, 3)
        send(&m, [.input(.mouse(Mouse(.press, button: .left, x: table.x + 10, y: table.y + 1)))])
        XCTAssertEqual(m.lists.filter, 3, "the column titles are not a row")
    }

    func testEveryListFitsEverySize() {
        for view in [TUIView.presets, .devices, .filters] {
            for (cols, rows) in [(20, 8), (40, 12), (59, 16), (60, 14), (80, 24), (200, 60)] {
                for look in Look.allCases {
                    var m = model(view, size: Size(cols: cols, rows: rows))
                    m.look.look = look
                    send(&m, key(view == .filters ? "a" : "v"))
                    let lines = m.lines()!
                    XCTAssertEqual(lines.count, rows, "\(view) \(cols)×\(rows)")
                    XCTAssertTrue(lines.allSatisfy { TerminalText.width($0) == cols }, "\(view) \(cols)×\(rows) \(look)")
                }
            }
        }
    }

    // MARK: Tune's other device

    func testTuneSteppsThroughTheDevicesPlayingFirst() {
        var m = model(.tune)
        XCTAssertEqual(send(&m, key("d")), [.refreshLibrary], "the devices are read again first")
        XCTAssertEqual(m.update(.library(TUILookTests.library)), [.target(DeviceChoice(uid: "mbp", name: "MacBook Pro Speakers"))])
        XCTAssertEqual(m.message?.text, "editing MacBook Pro Speakers's curve, which is not playing")
        send(&m, key("D"))
        XCTAssertEqual(m.update(.library(TUILookTests.library)), [.target(nil)], "back to the playing one")
        XCTAssertNil(m.editing)
        send(&m, key("D"))
        XCTAssertEqual(m.update(.library(TUILookTests.library)), [.target(DeviceChoice(uid: "dac", name: "Old DAC"))], "wrapping round")
        XCTAssertEqual(KeyTable.action(for: .char("в"), in: .tune), .otherDevice(1))
    }
}
