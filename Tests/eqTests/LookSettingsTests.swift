import EQTerm
import XCTest
@testable import eq

final class LookSettingsTests: XCTestCase {
    private let truecolor = ["TERM": "xterm-256color", "COLORTERM": "truecolor"]

    func testDefaultsAreStudioInkAndTheTerminalsGround() {
        let s = LookSettings.resolve(flags: TUIOptions(), saved: nil, env: truecolor)
        XCTAssertEqual(s.look, .studio)
        XCTAssertEqual(s.paletteName, .ink)
        XCTAssertEqual(s.depth, .truecolor)
        XCTAssertEqual(s.meterStyle, .bars)
        XCTAssertTrue(s.showsCurve && s.scale && s.peaks)
        XCTAssertFalse(s.paintsGround, "a translucent terminal stays translucent")
        let console = LookSettings.resolve(flags: TUIOptions(look: "console"), saved: nil, env: truecolor)
        XCTAssertEqual([console.paletteName.rawValue, console.meterStyle.rawValue], ["brass", "leds"])
        XCTAssertFalse(console.showsCurve, "the curve is the studio's")
    }

    func testFlagBeatsSavedBeatsDefaultAndNoColorBeatsAll() {
        let saved = TUIOptions(look: "console", palette: "paper", colors: "256", meter: "bars", curve: true, scale: false, peaks: false,
                               background: "theme")
        let s = LookSettings.resolve(flags: TUIOptions(), saved: saved, env: truecolor)
        XCTAssertEqual(s, LookSettings(look: .console, palette: .paper, depth: .indexed, meter: .bars, curve: true, scale: false,
                                       peaks: false, paintsGround: true))
        let flagged = LookSettings.resolve(flags: TUIOptions(look: "studio", palette: "auto", colors: "16", peaks: true), saved: saved,
                                           env: truecolor)
        XCTAssertEqual(flagged.look, .studio)
        XCTAssertNil(flagged.palette, "--palette auto takes back a saved palette for this run")
        XCTAssertEqual(flagged.depth, .ansi)
        XCTAssertTrue(flagged.peaks)
        var noColor = truecolor
        noColor["NO_COLOR"] = "1"
        XCTAssertEqual(LookSettings.resolve(flags: TUIOptions(colors: "24bit"), saved: saved, env: noColor).depth, .none)
        XCTAssertEqual(LookSettings.resolve(flags: TUIOptions(), saved: saved, env: ["TERM": "dumb"]).look, .console,
                       "the look stays when the colour goes")
        let unknown = LookSettings.resolve(flags: TUIOptions(), saved: TUIOptions(look: "classic", colors: "9000"), env: truecolor)
        XCTAssertEqual([unknown.look.rawValue, unknown.depth.rawValue], ["studio", "24bit"], "a value eq does not know is left out")
    }

    func testParsingTheFlags() throws {
        let parsed = try LookSettings.parseFlags(["--zones", "--look", "console", "--palette=paper", "--colors", "none", "--meter=leds",
                                                  "--no-curve", "--scale", "--no-peaks", "--background", "theme"])
        XCTAssertEqual(parsed.rest, ["--zones"])
        XCTAssertEqual(parsed.options, TUIOptions(look: "console", palette: "paper", colors: "none", meter: "leds", curve: false,
                                                  scale: true, peaks: false, background: "theme"))
        XCTAssertThrowsError(try LookSettings.parseFlags(["--look", "classic"])) { error in
            XCTAssertTrue("\(error)".contains("expected one of studio, console"), "\(error)")
        }
        XCTAssertThrowsError(try LookSettings.parseFlags(["--colors"]))
    }

    func testWatchAndTUITakeTheFlags() {
        let ctx = CLIContext(store: ConfigStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("eq-look-\(UUID()).json")),
                             statusURL: FileManager.default.temporaryDirectory.appendingPathComponent("status.json"),
                             connectedDevices: { [] }, defaultOutput: { nil }, fetch: { _ in throw URLError(.notConnectedToInternet) },
                             cacheDirectory: FileManager.default.temporaryDirectory, today: { "2026-09-29" })
        var tty = ctx
        tty.terminal = { (true, 120, 40) }
        tty.meterSocketURL = FileManager.default.temporaryDirectory.appendingPathComponent("eq-look-none-\(UUID()).sock")
        for args in [["watch", "--look", "console", "--no-curve"], ["tui", "meter", "--zones", "--colors=16"]] {
            let result = CLI.run(args, context: tty)
            XCTAssertTrue(result.output.contains("daemon is not running"), "\(args): \(result.output)")
        }
        let bad = CLI.run(["watch", "--look", "classic"], context: tty)
        XCTAssertEqual(bad.exitCode, 2)
        XCTAssertTrue(bad.output.contains("--look classic: expected one of studio, console"), bad.output)
    }

    /// Every token either has its hand-picked stand-in at sixteen colours or is one the spec
    /// declares not painted there.
    func testEveryTokenHasASixteenColourValueOrIsDeclaredUnpainted() {
        let unpainted: Set<String> = ["bg", "surface", "status", "text", "text2", "keyBg", "onChip", "lcdBg", "borderHi", "cap"]
        for name in PaletteName.allCases {
            let palette = Palette.named(name)
            for child in Mirror(reflecting: palette).children {
                guard let label = child.label, let swatch = child.value as? Swatch else { continue }
                let has = swatch.ansi != nil || swatch.ansiBackground != nil || !swatch.attributes.isEmpty
                XCTAssertTrue(has || unpainted.contains(label), "\(name).\(label) has no 16-colour value")
            }
            XCTAssertEqual(palette.hues.count, Instruments.all.count)
            XCTAssertEqual(palette.boostFill.index, 22)
            XCTAssertEqual(palette.cutFill.index, 53)
        }
        let theme = Theme(palette: .ink, depth: .ansi)
        XCTAssertEqual([-30.0, -12, -3].map { theme.level($0).ansiBackground }, [2, 3, 1], "three zones at sixteen colours")
    }

    func testYAndItsTwinSwitchTheLookAndPaletteAndSaveThem() {
        var model = MeterModel(size: Size(cols: 120, rows: 40))
        _ = model.update(.frame(MeterFrameTests.sample))
        XCTAssertEqual(model.update(.input(.key(KeyPress(.char("y"))))), [.redraw, .edit(.setLook("console"))])
        XCTAssertEqual(model.look.look, .console)
        XCTAssertEqual(model.look.paletteName, .brass, "an automatic palette follows the look")
        XCTAssertEqual(model.update(.input(.key(KeyPress(.char("Н"))))), [.redraw, .edit(.setPalette("ink"))])
        XCTAssertEqual(model.update(.input(.key(KeyPress(.char("н"))))), [.redraw, .edit(.setLook("studio"))])
        XCTAssertEqual(model.look.paletteName, .ink, "a chosen palette stays")
        XCTAssertTrue(model.lines()!.joined().contains("look: studio · palette ink"))
    }

    func testTheSessionSavesLookAndPaletteBesideTheMouse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-look-\(UUID().uuidString)")
        let ctx = CLIContext(store: ConfigStore(url: dir.appendingPathComponent("eq.json")), statusURL: dir.appendingPathComponent("status.json"),
                             connectedDevices: { [] }, defaultOutput: { ("SPK", "Speakers") },
                             fetch: { _ in throw URLError(.notConnectedToInternet) }, cacheDirectory: dir, today: { "2026-09-29" })
        _ = try ctx.store.loadOrCreate(builtInUID: nil, builtInName: nil)
        let session = CLI.WatchSession(ctx)
        try session.apply(.mouse)
        try session.apply(.setLook("console"))
        try session.apply(.setPalette("paper"))
        XCTAssertEqual(try ctx.store.load().tui, TUIOptions(mouse: true, look: "console", palette: "paper"))
        try session.apply(.mouse)
        XCTAssertEqual(try ctx.store.load().tui, TUIOptions(look: "console", palette: "paper"), "m off keeps the look")
        XCTAssertTrue(session.header().mouse == false)
        XCTAssertThrowsError(try session.apply(.undo), "the screen's settings are not a curve change")
    }
}
