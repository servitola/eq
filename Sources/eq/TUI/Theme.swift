import EQTerm

/// The two ways the TUI draws the same views: a dense graphic panel, or a mixing desk.
enum Look: String, CaseIterable {
    case studio, console

    var palette: PaletteName { self == .studio ? .ink : .brass }
    var meter: MeterStyle { self == .studio ? .bars : .leds }
}

enum PaletteName: String, CaseIterable {
    case ink, paper, brass
}

enum MeterStyle: String, CaseIterable {
    case bars, leds
}

/// Named colours, each with its 256 and 16-colour stand-in (spec "Visual design", Tokens).
struct Palette {
    var name: PaletteName
    var bg, surface, status, chip, chipHi, sel, border, borderHi, grid: Swatch
    var text, text2, text3, title, accent, boost, cut, curve, ghost: Swatch
    var warn, danger, ok, solo, keyBg, keyFg, onChip: Swatch
    var tapeBg, tapeFg, lcdBg, lcdFg, windowBg, windowFg, needle, cap, capSel, track, lampOff, groove: Swatch
    /// One per instrument, in `Instruments.all` order, warm to cool from low to high.
    var hues: [Swatch]
    /// dBFS → colour, interpolated in RGB.
    var meter: [(db: Double, hex: UInt32)]

    /// The boost and cut areas under the curve: the colour at 16 % over the ground. The cube would
    /// turn them grey, so their 256 indices are picked by hand.
    var boostFill: Swatch { tint(boost, index: 22) }
    var cutFill: Swatch { tint(cut, index: 53) }

    private func tint(_ c: Swatch, index: UInt8) -> Swatch {
        var s = c.mixed(toward: bg, 0.84).with(sgr: nil, [])
        s.index = index
        return s
    }

    /// The LED ladder's three zones at the EBU −18 dBFS alignment level and −6 dBFS, lit and unlit.
    static let ledLit: [Swatch] = [Swatch(0x3DDC74, sgr: 32, background: 42), Swatch(0xF5D547, sgr: 33, background: 43),
                                   Swatch(0xFF4B3E, sgr: 31, background: 41)]
    static let ledUnlit: [Swatch] = [Swatch(0x12301D, sgr: 32, .dim), Swatch(0x352F10, sgr: 33, .dim), Swatch(0x3A1512, sgr: 31, .dim)]

    static func named(_ name: PaletteName) -> Palette {
        switch name {
        case .ink: return ink
        case .paper: return paper
        case .brass: return brass
        }
    }

    private static let darkHues: [Swatch] = [0xFF7A59, 0xFFAE57, 0xFFD966, 0xB5E36B, 0x4FD6C4, 0x6CB6FF, 0xB99CFF, 0xF590D6].map { Swatch($0) }
    private static let darkMeter: [(db: Double, hex: UInt32)] = [(-60, 0x1B5E57), (-36, 0x1F8F6B), (-18, 0x4CC873), (-10, 0xD9C84E),
                                                                  (-6, 0xF2A33A), (-3, 0xF2663A), (0, 0xFF3F63)]
    private static let console = (tapeBg: Swatch(0xE6DABD, background: 47), tapeFg: Swatch(0x2A251C, sgr: 30),
                                  lcdBg: Swatch(0x0B0A07), lcdFg: Swatch(0xFFB547, sgr: 33),
                                  windowBg: Swatch(0x0B2C63, background: 44), windowFg: Swatch(0x8FD3FF, sgr: 96),
                                  needle: Swatch(0xFBF8EF, sgr: 97))

    static let ink = Palette(
        name: .ink,
        bg: Swatch(0x24262B), surface: Swatch(0x1D2026), status: Swatch(0x1B1E25),
        chip: Swatch(0x2F3544, background: 100), chipHi: Swatch(0x39425A, .bold, background: 100),
        sel: Swatch(0x2F3D63, background: 104), border: Swatch(0x4A5368, .dim), borderHi: Swatch(0x7282A6),
        grid: Swatch(0x3D4454, .dim),
        text: Swatch(0xDDE2EA), text2: Swatch(0xA2ABBC), text3: Swatch(0x7C859A, .dim), title: Swatch(0xEEF1F6, .bold),
        accent: Swatch(0x8AA8FF, sgr: 36), boost: Swatch(0x63D99E, sgr: 32), cut: Swatch(0xF27FBC, sgr: 35),
        curve: Swatch(0xF3E9CF, .bold), ghost: Swatch(0x3A4356, .dim),
        warn: Swatch(0xF2C14E, sgr: 33), danger: Swatch(0xFF4D5E, sgr: 31), ok: Swatch(0x63D99E, sgr: 32),
        solo: Swatch(0xFFD166, sgr: 93), keyBg: Swatch(0x343C4D), keyFg: Swatch(0xEEF1F6, .bold), onChip: Swatch(0x10131A),
        tapeBg: console.tapeBg, tapeFg: console.tapeFg, lcdBg: console.lcdBg, lcdFg: console.lcdFg,
        windowBg: console.windowBg, windowFg: console.windowFg, needle: console.needle,
        cap: Swatch(0xD8D1C2), capSel: Swatch(0x8AA8FF, sgr: 36), track: Swatch(0x3D4454, .dim), lampOff: Swatch(0x3A2F36, .dim),
        groove: Swatch(0x16181D, .dim),
        hues: darkHues, meter: darkMeter)

    static let paper = Palette(
        name: .paper,
        bg: Swatch(0xF6F3EC), surface: Swatch(0xFBF9F4), status: Swatch(0xECE7DC),
        chip: Swatch(0xE2DCCF, background: 47), chipHi: Swatch(0xD6CFBF, .bold, background: 47),
        sel: Swatch(0xDFE6FB, background: 47), border: Swatch(0xCBC3B3, .dim), borderHi: Swatch(0x9A917F),
        grid: Swatch(0xE2DCCF, .dim),
        text: Swatch(0x20242D), text2: Swatch(0x4A5264), text3: Swatch(0x8B909D, .dim), title: Swatch(0x15181F, .bold),
        accent: Swatch(0x3552CC, sgr: 34), boost: Swatch(0x1D9457, sgr: 32), cut: Swatch(0xBD2F79, sgr: 35),
        curve: Swatch(0x262A33, .bold), ghost: Swatch(0xDCD6C9, .dim),
        warn: Swatch(0xB7860B, sgr: 33), danger: Swatch(0xCF1F3A, sgr: 31), ok: Swatch(0x1D9457, sgr: 32),
        solo: Swatch(0xA86D00, sgr: 33), keyBg: Swatch(0xE2DCCF), keyFg: Swatch(0x15181F, .bold), onChip: Swatch(0xFBF9F4),
        tapeBg: console.tapeBg, tapeFg: console.tapeFg, lcdBg: Swatch(0x20242D), lcdFg: console.lcdFg,
        windowBg: console.windowBg, windowFg: console.windowFg, needle: console.needle,
        cap: Swatch(0x4A5264), capSel: Swatch(0x3552CC, sgr: 34), track: Swatch(0xCBC3B3, .dim), lampOff: Swatch(0xE2D6D0, .dim),
        groove: Swatch(0xE2DCCF, .dim),
        hues: [0xD4502F, 0xC97A12, 0xA88A00, 0x5D8F16, 0x0F8F80, 0x2F6FD0, 0x7453D6, 0xC0469D].map { Swatch($0) },
        meter: [(-60, 0x9CC9BB), (-36, 0x4FAE84), (-18, 0x2C9A55), (-10, 0xC29A14), (-6, 0xE07B1F), (-3, 0xE0501F), (0, 0xD61F45)])

    static let brass = Palette(
        name: .brass,
        bg: Swatch(0x12110F), surface: Swatch(0x1C1A17), status: Swatch(0x23201C),
        chip: Swatch(0x2E2A24, background: 100), chipHi: Swatch(0x3A352D, .bold, background: 100),
        sel: Swatch(0x3A3226, background: 100), border: Swatch(0x3A352D, .dim), borderHi: Swatch(0x6B6254),
        grid: Swatch(0x2A2621, .dim),
        text: Swatch(0xECE3CF), text2: Swatch(0xB9AE97), text3: Swatch(0x7E7564, .dim), title: Swatch(0xF4ECD8, .bold),
        accent: Swatch(0xF0A24A, sgr: 33), boost: Swatch(0x86E0A6, sgr: 32), cut: Swatch(0xF58CC3, sgr: 35),
        curve: Swatch(0xF4ECD8, .bold), ghost: Swatch(0x2D2A25, .dim),
        warn: Swatch(0xF5C647, sgr: 33), danger: Swatch(0xFF4B3E, sgr: 31), ok: Swatch(0x3DDC74, sgr: 32),
        solo: Swatch(0xFFCF4A, sgr: 93), keyBg: Swatch(0x34302A), keyFg: Swatch(0xF4ECD8, .bold), onChip: Swatch(0x16140F),
        tapeBg: console.tapeBg, tapeFg: console.tapeFg, lcdBg: console.lcdBg, lcdFg: console.lcdFg,
        windowBg: console.windowBg, windowFg: console.windowFg, needle: console.needle,
        cap: Swatch(0xD8D1C2), capSel: Swatch(0xF0A24A, sgr: 33), track: Swatch(0x3B362E, .dim), lampOff: Swatch(0x3A2320, .dim),
        groove: Swatch(0x0C0B09, .dim),
        hues: darkHues, meter: darkMeter)
}

/// A palette at one colour depth, and whether the palette's ground is painted under everything.
struct Theme {
    var palette: Palette
    var depth: ColorDepth
    /// `tui.background theme`; the default leaves a translucent terminal translucent.
    var paintsGround = false
    /// How far everything is pushed toward the ground: the screen behind an overlay.
    var fade = 0.0

    var p: Palette { palette }

    func style(_ fg: Swatch?, _ bg: Swatch? = nil, _ attributes: Style.Attributes = [], solid: Bool = false) -> Style {
        guard fade > 0 else { return depth.style(fg, bg, attributes, solid: solid) }
        let f = (fg ?? palette.text).mixed(toward: palette.bg, fade).with(sgr: nil, .dim)
        let b = bg.map { $0.mixed(toward: palette.bg, fade).with(sgr: nil, []) }
        return depth.style(f, b, attributes.subtracting(.bold), solid: solid)
    }

    var blank: Cell { Cell(" ", style: style(nil)) }

    func hue(_ instrument: Instrument) -> Swatch {
        let index = Instruments.all.firstIndex(of: instrument) ?? 0
        return palette.hues[index % palette.hues.count]
    }

    func gain(_ value: Double) -> Swatch {
        value > 0 ? palette.boost : (value < 0 ? palette.cut : palette.text3)
    }

    /// The meter colour at `db`: the stops interpolated in RGB; three zones at sixteen colours.
    func level(_ db: Double) -> Swatch {
        let stops = palette.meter
        let d = min(max(db.isFinite ? db : -60, stops[0].db), stops[stops.count - 1].db)
        var rgb = Swatch(stops[stops.count - 1].hex)
        for (a, b) in zip(stops, stops.dropFirst()) where d <= b.db {
            let t = b.db > a.db ? (d - a.db) / (b.db - a.db) : 0
            rgb = Swatch(a.hex).mixed(toward: Swatch(b.hex), t)
            break
        }
        let zone = Self.zone(d)
        return rgb.with(sgr: [32, 33, 31][zone], [], background: [42, 43, 41][zone])
    }

    /// 0 below the −18 dBFS alignment level, 1 up to −6 dBFS, 2 above.
    static func zone(_ db: Double) -> Int { db < -18 ? 0 : (db < -6 ? 1 : 2) }

    func led(_ db: Double, lit: Bool) -> Swatch {
        (lit ? Palette.ledLit : Palette.ledUnlit)[Self.zone(db)]
    }

    /// A band outside the focus: 72 % of the way to the ground, dim where there are sixteen colours.
    func faded(_ c: Swatch, _ t: Double = 0.72) -> Swatch {
        c.mixed(toward: palette.bg, t).with(sgr: nil, .dim)
    }
}
