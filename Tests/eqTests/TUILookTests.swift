import EQTerm
import XCTest
@testable import eq

/// Golden screens of each look, as text and as `[codes]…[/]`-marked runs: `EQ_UPDATE_GOLDEN=1`
/// rewrites the files under Fixtures/tui, `EQ_WRITE_SCREENSHOTS=1` writes the same screens as
/// `.ans` into docs/design/tui/actual, next to the mocks they are compared with.
final class TUILookTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tui")
    static let actual = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/design/tui/actual")

    /// The mocks' state: `mocks.py` `base_state`.
    static func scene(cols: Int, rows: Int, look: Look = .studio, depth: ColorDepth = .truecolor, palette: PaletteName? = nil,
                      zones: Bool = false, focus: String? = nil, modal: WatchModal? = nil, flash: Int? = nil,
                      message: MeterScene.Message? = nil, solo: Bool = false, view: TUIView = .meter, spectrum: Bool = true) -> MeterScene {
        let frame = MeterFrame(t: 0, device: "BE-RCA", rate: 44100,
                               in: [-7.0, -6.0, -9.5, -14.0, -19.0, -14.5, -22.0, -26.0, -31.0, -39.0],
                               out: [-9.0, -7.5, -11.0, -15.0, -19.0, -17.0, -22.0, -26.0, -29.0, -37.0], peak: -6, limiting: false,
                               gains: Config.screenshotCurve, preamp: -4.8, enabled: true,
                               solo: solo ? SoloRange(low: 85, high: 9000) : nil, comp: -2.1, spectrum: spectrum ? Self.spectrum : nil)
        var scene = MeterScene(frame: frame, size: Size(cols: cols, rows: rows))
        scene.settings.look = look
        scene.settings.depth = depth
        scene.settings.palette = palette
        scene.strip = zones
        scene.focus = focus.flatMap(Instruments.named)
        scene.modal = modal
        scene.flash = flash.map { ($0, Watch.flashFrames + MeterScene.flashBlendFrames) }
        scene.message = message
        scene.listening = solo
        scene.peaks = [-4.2, -3.1, -7.0, -11.5, -15.0, -13.2, -18.0, -21.5, -25.0, -31.0]
        scene.spectrumPeaks = scene.spectrum.map { $0.enumerated().map { j, level in min(level + [2.5, 4, 1.5, 6, 3][j % 5], 0) } }
        scene.outputPeak = -4.5
        scene.header = Watch.Header(preset: ("favourite", true), preference: Preference(bass: 1, treble: -0.5), knobs: ["voice": 3],
                                    dynamics: Dynamics(comp: .night, color: .init(kind: .tape, amount: 0.3)))
        scene.view = view
        scene.selected = scene.focus.flatMap { Instruments.all.firstIndex(of: $0) } ?? 0
        scene.events.entries = events
        return scene
    }

    /// The mix's third octaves: a kick at 50–63 Hz, a dip in the low mids, presence at 2.5–3 kHz,
    /// rolling off above 12 kHz.
    static let spectrum: [Double] = [-31, -22, -14.5, -11, -8.5, -9.5, -13, -15.5, -17, -18.5, -20, -21.5, -23, -22, -21, -22.5, -24.5, -23,
                                     -24, -25.5, -24, -21.5, -22.5, -25, -27.5, -29, -31, -33.5, -37, -42, -51]

    /// A morning's events as `eq events` would print them.
    static let events: [EventEntry] = [
        ("08:59:58", #"{"event":"daemon","state":"running","version":"2026.09.29.3","error":null}"#),
        ("09:00:01", #"{"event":"device","device":"BE-RCA","uid":"be","transport":"USB","rate":44100}"#),
        ("09:00:01", #"{"event":"profile","device":"BE-RCA","preset":"favourite","source":"device"}"#),
        ("09:12:40", #"{"event":"app","app":"com.spotify.client","name":"Spotify","preset":"flat"}"#),
        ("09:12:44", #"{"event":"solo","solo":{"low":85,"high":9000}}"#),
        ("09:13:02", #"{"event":"solo","solo":null}"#),
        ("09:20:15", #"{"event":"enabled","enabled":false}"#),
        ("09:20:18", #"{"event":"enabled","enabled":true}"#),
        ("09:31:07", #"{"event":"rate","device":"BE-RCA","rate":48000}"#),
        ("09:40:00", #"{"event":"mode","mode":"driver","target":"BE-RCA","reason":null}"#),
        ("09:52:30", #"{"event":"route","app":"com.google.Chrome","name":"Chrome","target":"air","targetName":"AirPods","reason":"first"}"#),
    ].map { time, line in
        var entry = EventEntry.decode(line)!
        entry.time = time
        return entry
    }

    static func screen(_ scene: MeterScene) -> Screen {
        var screen = Screen(scene.size)
        scene.draw(into: &screen)
        return screen
    }

    /// Each row as a terminal gets it: SGR only where the style changes, a reset at its end.
    static func ansi(_ screen: Screen) -> String {
        screen.lines().indices.map { y -> String in
            var line = ""
            var pen = Style.plain
            let last = (0..<screen.width).last { x in let c = screen[x, y]; return c.text != " " || c.style != .plain } ?? -1
            for x in 0...max(last, 0) where last >= 0 {
                let cell = screen[x, y]
                if cell.isContinuation { continue }
                if cell.style != pen {
                    line += "\u{1B}[0" + cell.style.codes.map { ";\($0)" }.joined() + "m"
                    pen = cell.style
                }
                line += cell.text
            }
            return pen == .plain ? line : line + "\u{1B}[0m"
        }.joined(separator: "\n") + "\n"
    }

    private static func trimmed(_ lines: [String]) -> String {
        lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n") + "\n"
    }

    private func assertGolden(_ text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = Self.fixtures.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["EQ_UPDATE_GOLDEN"] != nil {
            try FileManager.default.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        XCTAssertEqual(text, try String(contentsOf: url, encoding: .utf8), "\(name):\n\(text)", file: file, line: line)
    }

    static let saved = MeterScene.Message(text: "saved: band 1 kHz -3.0 dB", kind: .ok)
    static let listening = MeterScene.Message(text: "listening to voice alone: 85 Hz–9 kHz — l again or Esc to stop", kind: .warn)

    /// The screens the spec asks for, per look: the meter at 80×24 and 120×40, zones, a focus with
    /// its solo, the instrument table and the key list.
    static let cases: [(name: String, scene: MeterScene)] = Look.allCases.flatMap { look -> [(String, MeterScene)] in
        [("\(look)-meter-80x24", scene(cols: 80, rows: 24, look: look)),
         ("\(look)-meter-120x40", scene(cols: 120, rows: 40, look: look)),
         ("\(look)-meter-120x40-bands", scene(cols: 120, rows: 40, look: look, spectrum: false)),
         ("\(look)-meter-140x40", scene(cols: 140, rows: 40, look: look)),
         ("\(look)-zones-120x36", scene(cols: 120, rows: 36, look: look, zones: true, flash: 5, message: saved)),
         ("\(look)-focus-120x36", scene(cols: 120, rows: 36, look: look, zones: true, focus: "voice", flash: 5, message: listening,
                                        solo: true)),
         ("\(look)-tune-120x36", tune(scene(cols: 120, rows: 36, look: look, flash: 5, view: .tune), .band(5))),
         ("\(look)-tune-80x24", tune(scene(cols: 80, rows: 24, look: look, view: .tune), .comp)),
         ("\(look)-instruments-120x36", scene(cols: 120, rows: 36, look: look, focus: "voice", view: .instruments)),
         ("\(look)-instruments-80x24", scene(cols: 80, rows: 24, look: look, view: .instruments)),
         ("\(look)-events-120x36", scene(cols: 120, rows: 36, look: look, view: .events)),
         ("\(look)-help-120x36", scene(cols: 120, rows: 36, look: look, modal: .help(scroll: 0))),
         ("\(look)-go-120x36", { var s = scene(cols: 120, rows: 36, look: look); s.goMenu = true; return s }()),
         ("\(look)-palette-120x36", { var s = scene(cols: 120, rows: 36, look: look); s.palette = palette; return s }()),
         ("\(look)-output-120x36", { var s = scene(cols: 120, rows: 36, look: look, view: .events); s.child = output; return s }()),
         ("\(look)-presets-120x36", lists(scene(cols: 120, rows: 36, look: look, view: .presets)) { $0.lists.preset = 3 }),
         ("\(look)-presets-80x24", lists(scene(cols: 80, rows: 24, look: look, view: .presets)) { $0.lists.preset = 2; $0.lists.diff = true }),
         ("\(look)-devices-120x36", lists(scene(cols: 120, rows: 36, look: look, view: .devices)) { $0.lists.device = 2 }),
         ("\(look)-devices-80x24", lists(scene(cols: 80, rows: 24, look: look, view: .devices)) {
             $0.lists.device = 1
             $0.library.driver = Library.Driver(name: "BE-RCA · EQ", target: DeviceChoice(uid: "be", name: "BE-RCA"))
         }),
         ("\(look)-filters-120x36", lists(scene(cols: 120, rows: 36, look: look, view: .filters)) {
             $0.lists.filter = 1
             $0.lists.field = .gain
             $0.message = MeterScene.Message(text: FilterField.gain.hint(adding: false))
         }),
         ("\(look)-filters-80x24", lists(scene(cols: 80, rows: 24, look: look, view: .filters)) {
             $0.form = FilterForm(filter: Filter(type: .peak, frequency: 250, gain: -2.5, q: 1.41, origin: .hand), field: .frequency)
             $0.message = MeterScene.Message(text: FilterField.frequency.hint(adding: true))
         }),
         ("\(look)-apps-120x36", pages(scene(cols: 120, rows: 36, look: look, view: .apps)) { $0.lists.app = 1 }),
         ("\(look)-apps-80x24", pages(scene(cols: 80, rows: 24, look: look, view: .apps)) {
             $0.library.driver = Library.Driver(name: "BE-RCA · EQ", target: DeviceChoice(uid: "be", name: "BE-RCA"))
             $0.picker = Picker(stage: .app, field: TextField("s"), chosen: 1)
         }),
         ("\(look)-system-120x36", pages(scene(cols: 120, rows: 36, look: look, view: .system)) { $0.lists.check = 16 }),
         ("\(look)-system-80x24", pages(scene(cols: 80, rows: 24, look: look, view: .system)) {
             $0.system = tapSystem
             $0.doctor.report = DoctorReport(ok: true, checks: tapChecks)
             $0.lists.check = 11
         }),
         ("\(look)-history-120x36", pages(scene(cols: 120, rows: 36, look: look, view: .history)) { $0.lists.version = 4 }),
         ("\(look)-history-80x24", pages(scene(cols: 80, rows: 24, look: look, view: .history)) { $0.lists.version = 2 })]
    }

    /// The Apps, System and History views' data: rules with one heard now, a route, driver mode
    /// with its doctor, and seven versions with the live one two steps back.
    static func pages(_ scene: MeterScene, _ edit: (inout MeterScene) -> Void) -> MeterScene {
        var scene = lists(scene) { _ in }
        scene.library.apps = [AppRule(app: "com.spotify.client", preset: "night"), AppRule(app: "com.apple.Music", preset: "late jazz"),
                              AppRule(app: "com.google.Chrome", preset: "podcast"), AppRule(app: "com.example.Gone", preset: "vinyl")]
        scene.library.followsApps = true
        scene.library.heard = AppMatch(app: "com.spotify.client", name: "Spotify", preset: "night")
        scene.library.routes = [RouteRule(app: "com.google.Chrome", outputs: ["AirPods", "BE-RCA"])]
        scene.library.followsRoutes = true
        scene.library.routed = [Status.Route(app: "com.google.Chrome", name: "Chrome", target: .init(uid: "air", name: "AirPods", transport: "bluetooth"),
                                             reason: .first, playing: true)]
        scene.running = [PlayingApp(id: "com.spotify.client", name: "Spotify"), PlayingApp(id: "com.google.Chrome", name: "Chrome"),
                         PlayingApp(id: "com.apple.Safari", name: "Safari")]
        scene.system = driverSystem
        scene.doctor.report = DoctorReport(ok: true, checks: driverChecks)
        scene.versions = versions
        scene.back = true
        edit(&scene)
        return scene
    }

    private static func check(_ name: String, _ detail: String, ok: Bool = true, warning: Bool = false) -> DoctorCheck {
        DoctorCheck(name: name, ok: ok, detail: detail, warning: warning)
    }

    static let driverSystem: SystemInfo = {
        var status = Status(state: .running, device: .init(uid: "be", name: "BE-RCA", transport: "usb"), sampleRate: 44100, profile: .device,
                            framesProcessed: 0, callbacks: 0, writes: 812, enabled: true, error: nil, pid: 4312, version: "2026.09.30",
                            updatedAt: Date(timeIntervalSince1970: 0), apps: AppsStatus(listening: true, overlay: AppMatch(app: "com.spotify.client", name: "Spotify", preset: "night")))
        status.mode = .driver
        status.driver = Status.DriverStatus(deviceName: "BE-RCA · EQ", target: .init(uid: "be", name: "BE-RCA", transport: "usb"), isDefault: true,
                                            ioRunning: true, eqActive: true, underruns: 0, overruns: 2, clockPpm: 1.8, latencyMs: 12, hidden: false)
        status.compReductionDB = -2.1
        return SystemInfo(status: status, mode: .driver, version: "2026.09.30", loaded: true)
    }()

    static let tapSystem: SystemInfo = {
        var status = driverSystem.status!
        status.mode = .tap
        status.driver = nil
        status.apps = nil
        status.compReductionDB = nil
        status.latencyMs = 23.4
        status.deviceLatencyMs = 12
        status.addedLatencyMs = 11.4
        status.underruns = 3
        status.overruns = 1
        status.version = "2026.09.29.5"
        return SystemInfo(status: status, mode: .tap, version: "2026.09.30", loaded: true)
    }()

    static let driverChecks = [
        check("macOS", "26.0.0"), check("config", "ok"), check("hooks", "none"), check("apps", "listening, 4 rules; heard now: Spotify → night"),
        check("output", "BE-RCA · EQ, 2 ch"), check("daemon", "running, pid 4312, v2026.09.30"), check("permission", "not needed (driver mode)"),
        check("launch agent", "bundled (login item \"EQ\")"), check("binary", "/Applications/EQ.app/Contents/MacOS/eq"),
        check("audio", "skipped (driver mode: see driver IO)"), check("engine", "running"), check("tap", "skipped (driver mode)"),
        check("latency", "the EQ device reports 12 ms, which players compensate for"), check("ring", "skipped (driver mode: see driver slips)"),
        check("filters", "stable at 44100 Hz"), check("driver", "installed, protocol 3, 2026.09.30"),
        check("driver update", "EQ.app carries 2026.09.30.1, coreaudiod runs 2026.09.30 — eq mode driver updates it", ok: false, warning: true),
        check("driver target", "BE-RCA (be)"), check("driver IO", "running"),
        check("driver slips", "0 underruns, 2 overruns in 1 s (0, 2 since load) — the EQ device and its target slipped, audio had gaps", ok: false, warning: true),
        check("driver clock", "+1.8 ppm"), check("driver EQ", "playing the curve eq sent (serial 1790745000)"),
        check("driver writer", "writes accepted (identifier com.servitola.eq)"), check("default output", "the EQ device"),
    ]

    static let tapChecks = [
        check("macOS", "26.0.0"), check("config", "ok"), check("hooks", "none"), check("output", "BE-RCA, 2 ch"),
        check("daemon", "running, pid 4312, v2026.09.29.5"), check("permission", "granted"), check("launch agent", "bundled (login item \"EQ\")"),
        check("binary", "/Applications/EQ.app/Contents/MacOS/eq"),
        check("audio", "callbacks 1204 → 1290 (daemon v2026.09.29.5, this eq v2026.09.30 — restart it: launchctl kickstart -k gui/$UID/com.servitola.eq)",
              ok: false, warning: true),
        check("engine", "running"), check("tap", "audio arriving"),
        check("ring", "3 underruns, 1 overrun — the tap and the output slipped, audio had gaps; the daemon rebuilds the engine if it keeps happening",
              ok: false, warning: true),
        check("latency", "eq adds 11 ms"), check("filters", "stable at 44100 Hz"),
    ]

    /// Seven saved versions of the playing curve, newest first, the live one two `eq undo`s back.
    static let versions: HistoryList = {
        func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute, second: 12))!
        }
        func version(_ index: Int, _ date: Date, _ edit: (inout Profile) -> Void) -> HistoryList.Version {
            var profile = playing
            edit(&profile)
            return HistoryList.Version(index: index, date: date, profile: profile, enabled: index != 5,
                                       mark: profile.preset.map { HistoryList.PresetMark(name: $0, modified: profile.bands != Config.screenshotCurve) },
                                       unreadable: false)
        }
        let list = [
            version(0, date(30, 9, 41)) { $0.bands[5] = -1; $0.bands[8] = 4 },
            version(1, date(30, 9, 40)) { $0.bands[5] = -1 },
            version(2, date(30, 9, 12)) { _ in },
            version(3, date(29, 22, 3)) { $0.preamp = -3; $0.instruments = nil },
            version(4, date(29, 21, 58)) { $0.bands = [2, 2, 1, 0, 0, 0, 0, 1, 2, 2]; $0.preamp = -2; $0.preset = "flat"; $0.dynamics = nil },
            version(5, date(29, 21, 57)) { $0.bands = Array(repeating: 0, count: 10); $0.preamp = 0; $0.preset = "flat"; $0.dynamics = nil },
            HistoryList.Version(index: 6, date: date(28, 18, 20), profile: nil, enabled: nil, mark: nil, unreadable: true),
        ]
        return HistoryList(position: 2, versions: list, device: "BE-RCA", loaded: true)
    }()

    /// The curve playing on BE-RCA, as `eq` shows it: the mocks' layers and an AutoEq import with one filter added by hand.
    static let playing: Profile = {
        var profile = Profile(name: "BE-RCA", preamp: -4.8, bands: Config.screenshotCurve, preset: "favourite",
                              preference: Preference(bass: 1, treble: -0.5), instruments: ["voice": 3],
                              dynamics: Dynamics(comp: .night, color: .init(kind: .tape, amount: 0.3)))
        profile.filters = [Filter(type: .lowShelf, frequency: 105, gain: 4, q: 0.7, origin: .import),
                           Filter(type: .peak, frequency: 2100, gain: -3.2, q: 1.8, origin: .import),
                           Filter(type: .highShelf, frequency: 10000, gain: 2, q: 0.7, origin: .import),
                           Filter(type: .peak, frequency: 3000, gain: -2, q: 1.41, origin: .hand)]
        profile.imported = "AutoEq · HD 600"
        return profile
    }()

    static let library: Library = {
        var library = Library(loaded: true)
        library.presets = [
            "favourite": Profile(name: nil, preamp: 0, bands: Config.screenshotCurve),
            "flat": .flat,
            "night": Profile(name: nil, preamp: -2, bands: [3, 2, 1, 0, 0, -1, -2, -2, -3, -4], dynamics: Dynamics(comp: .night)),
            "late jazz": Profile(name: nil, preamp: -3, bands: [2, 3, 1, 0, -1, 0, 1, 2, 1, 0], preference: Preference(bass: 2, treble: -1),
                                 instruments: ["bass": 2, "piano": 1.5]),
            "podcast": Profile(name: nil, preamp: 0, bands: [-6, -4, -2, 0, 1, 2, 3, 2, 0, -2], instruments: ["voice": 3],
                               dynamics: Dynamics(comp: .gentle)),
        ]
        library.devices = [
            "be": playing,
            "air": Profile(name: "AirPods", preamp: -2, bands: [3, 2, 1, 0, 0, -1, -2, -2, -3, -4], preset: "night", dynamics: Dynamics(comp: .night)),
            "dac": Profile(name: "Old DAC", preamp: 0, bands: [0, 0, 0, 1, 1, 0, 0, -1, -1, 0]),
        ]
        library.fallback = Profile(name: nil, preamp: 0, bands: Config.screenshotCurve)
        library.rows = [
            DeviceRow(uid: "be", name: "BE-RCA", transport: "usb", connected: true, profile: "own"),
            DeviceRow(uid: "mbp", name: "MacBook Pro Speakers", transport: "builtin", connected: true, profile: "default"),
            DeviceRow(uid: "air", name: "AirPods", transport: "bluetooth", connected: true, profile: "own"),
            DeviceRow(uid: "tv", name: "LG TV", transport: "hdmi", connected: true, profile: "default"),
            DeviceRow(uid: "dac", name: "Old DAC", transport: nil, connected: false, profile: "own"),
        ]
        library.current = DeviceChoice(uid: "be", name: "BE-RCA")
        library.output = "be"
        library.apps = [AppRule(app: "com.spotify.client", preset: "night")]
        return library
    }()

    /// A list view over the library above, with the playing curve in the header.
    static func lists(_ scene: MeterScene, _ edit: (inout MeterScene) -> Void) -> MeterScene {
        var scene = scene
        scene.library = library
        scene.header.profile = playing
        edit(&scene)
        return scene
    }

    /// The Tune view with `control` selected and its hint in the message row, as the model says it.
    static func tune(_ scene: MeterScene, _ control: TuneControl) -> MeterScene {
        var scene = scene
        scene.tune.select(control)
        scene.message = scene.message ?? MeterScene.Message(text: TuneView.hint(control, app: nil))
        return scene
    }

    static let palette = CommandPalette(field: TextField("pre"), chosen: 0, history: [])
    /// `eq zones` as a child prints it into the pane, with the colours `Paint` gives a pipe under CLICOLOR_FORCE.
    static let output = ChildOutput(command: "zones", lines: Instruments.all.flatMap { instrument in
        instrument.ranges.enumerated().map { k, range in
            let name = k == 0 ? "\u{1B}[1m" + instrument.name.padding(toLength: 8, withPad: " ", startingAt: 0) + "\u{1B}[0m" : "        "
            return name + InstrumentTable.rangeText(range).padding(toLength: 26, withPad: " ", startingAt: 0)
                + "\u{1B}[2m" + InstrumentTable.bandsText(range) + "\u{1B}[0m"
        }
    }, status: 0, shown: true)

    func testGoldenScreensPerLook() throws {
        for c in Self.cases {
            let screen = Self.screen(c.scene)
            XCTAssertEqual(screen.lines().count, c.scene.size.rows)
            try assertGolden(Self.trimmed(screen.lines()), c.name + ".txt")
            try assertGolden(Self.trimmed(screen.markedLines()), c.name + ".styled.txt")
        }
    }

    /// Without colour the look stays: reverse video carries the bars, chips and flags.
    func testMonochromeAndSixteenColourGoldens() throws {
        for look in Look.allCases {
            for depth in [ColorDepth.none, .ansi, .indexed] {
                let s = Self.scene(cols: 120, rows: 40, look: look, depth: depth, zones: true, focus: "voice", flash: 5, solo: true)
                try assertGolden(Self.trimmed(Self.screen(s).markedLines()), "\(look)-meter-120x40-\(depth.rawValue).styled.txt")
            }
        }
    }

    /// The screens as `.ans` files, and `preview.html` showing each at every depth with the
    /// mocks' own viewer, so the two can be put side by side.
    func testWriteScreenshots() throws {
        guard ProcessInfo.processInfo.environment["EQ_WRITE_SCREENSHOTS"] != nil else { throw XCTSkip("EQ_WRITE_SCREENSHOTS=1 writes them") }
        try FileManager.default.createDirectory(at: Self.actual, withIntermediateDirectories: true)
        var all = Self.cases
        all.append(("studio-paper-meter-120x40", Self.scene(cols: 120, rows: 40, palette: .paper)))
        all.append(("studio-meter-50x16", Self.scene(cols: 50, rows: 16)))
        var shown: [[String: Any]] = []
        for c in all {
            var variants: [String: String] = [:]
            for (key, depth) in [("tc", ColorDepth.truecolor), ("16", .ansi), ("mono", .none)] {
                var scene = c.scene
                scene.settings.depth = depth
                variants[key] = Self.ansi(Self.screen(scene))
            }
            try variants["tc"]!.write(to: Self.actual.appendingPathComponent(c.name + ".ans"), atomically: true, encoding: .utf8)
            let look = c.scene.settings.look
            shown.append(["stem": c.name, "look": look.rawValue, "palette": c.scene.settings.paletteName.rawValue, "view": c.scene.view.rawValue,
                          "w": c.scene.size.cols, "h": c.scene.size.rows, "variants": variants])
        }
        for look in Look.allCases {
            for (name, depth) in [("256", ColorDepth.indexed), ("16", .ansi), ("mono", .none)] {
                try Self.ansi(Self.screen(Self.scene(cols: 120, rows: 40, look: look, depth: depth)))
                    .write(to: Self.actual.appendingPathComponent("\(look)-meter-120x40-\(name).ans"), atomically: true, encoding: .utf8)
            }
        }
        let template = try String(contentsOf: Self.actual.deletingLastPathComponent().appendingPathComponent("preview.template.html"),
                                  encoding: .utf8)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: shown, options: [.sortedKeys]), as: UTF8.self)
        let page = template.replacingOccurrences(of: "/*MOCKS*/[]", with: json)
            .replacingOccurrences(of: #"stem: "studio-meter-120x36""#, with: #"stem: "studio-meter-120x40""#)
            .replacingOccurrences(of: #"["studio", "console", "classic"]"#, with: #"["studio", "console"]"#)
            .replacingOccurrences(of: "cat docs/design/tui/${mock.stem}.ans", with: "cat docs/design/tui/actual/${mock.stem}.ans")
            .replacingOccurrences(of: "<title>eq TUI looks</title>", with: "<title>eq TUI looks, as built</title>")
            .replacingOccurrences(of: #""paper-meter-120x36": "light palette 120×36" };"#,
                                  with: #""paper-meter-120x36": "light palette 120×36", "meter-120x40": "meter 120×40", "#
                                      + #""instruments-80x24": "instruments 80×24", "events-120x36": "events 120×36", "go-120x36": "g menu 120×36", "#
                                      + #""palette-120x36": "palette 120×36", "output-120x36": "command output 120×36", "tune-80x24": "tune 80×24", "#
                                      + #""meter-140x40": "meter 140×40", "meter-120x40-bands": "meter without a spectrum 120×40" };"#)
            .replacingOccurrences(of: "Mock screens from <code>docs/design/tui/mocks.py</code>",
                                  with: "Screens from the real renderer (<code>EQ_WRITE_SCREENSHOTS=1 swift test --filter TUILookTests</code>)")
        try page.write(to: Self.actual.appendingPathComponent("preview.html"), atomically: true, encoding: .utf8)
    }
}
