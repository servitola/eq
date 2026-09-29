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
                      message: MeterScene.Message? = nil, solo: Bool = false, view: TUIView = .meter) -> MeterScene {
        let frame = MeterFrame(t: 0, device: "BE-RCA", rate: 44100,
                               in: [-7.0, -6.0, -9.5, -14.0, -19.0, -14.5, -22.0, -26.0, -31.0, -39.0],
                               out: [-9.0, -7.5, -11.0, -15.0, -19.0, -17.0, -22.0, -26.0, -29.0, -37.0], peak: -6, limiting: false,
                               gains: Config.screenshotCurve, preamp: -4.8, enabled: true,
                               solo: solo ? SoloRange(low: 85, high: 9000) : nil, comp: -2.1)
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
        scene.outputPeak = -4.5
        scene.header = Watch.Header(preset: ("favourite", true), preference: Preference(bass: 1, treble: -0.5), knobs: ["voice": 3],
                                    dynamics: Dynamics(comp: .night, color: .init(kind: .tape, amount: 0.3)))
        scene.view = view
        scene.selected = scene.focus.flatMap { Instruments.all.firstIndex(of: $0) } ?? 0
        scene.events.entries = events
        return scene
    }

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
         ("\(look)-zones-120x36", scene(cols: 120, rows: 36, look: look, zones: true, flash: 5, message: saved)),
         ("\(look)-focus-120x36", scene(cols: 120, rows: 36, look: look, zones: true, focus: "voice", flash: 5, message: listening,
                                        solo: true)),
         ("\(look)-instruments-120x36", scene(cols: 120, rows: 36, look: look, focus: "voice", view: .instruments)),
         ("\(look)-instruments-80x24", scene(cols: 80, rows: 24, look: look, view: .instruments)),
         ("\(look)-events-120x36", scene(cols: 120, rows: 36, look: look, view: .events)),
         ("\(look)-help-120x36", scene(cols: 120, rows: 36, look: look, modal: .help(scroll: 0))),
         ("\(look)-go-120x36", { var s = scene(cols: 120, rows: 36, look: look); s.goMenu = true; return s }()),
         ("\(look)-palette-120x36", { var s = scene(cols: 120, rows: 36, look: look); s.palette = palette; return s }()),
         ("\(look)-output-120x36", { var s = scene(cols: 120, rows: 36, look: look, view: .events); s.child = output; return s }())]
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
                                      + #""palette-120x36": "palette 120×36", "output-120x36": "command output 120×36" };"#)
            .replacingOccurrences(of: "Mock screens from <code>docs/design/tui/mocks.py</code>",
                                  with: "Screens from the real renderer (<code>EQ_WRITE_SCREENSHOTS=1 swift test --filter TUILookTests</code>)")
        try page.write(to: Self.actual.appendingPathComponent("preview.html"), atomically: true, encoding: .utf8)
    }
}
