/// How many colours the terminal shows: 24-bit, the 256 of xterm, its own sixteen, or none.
public enum ColorDepth: String, CaseIterable {
    case truecolor = "24bit"
    case indexed = "256"
    case ansi = "16"
    case none

    /// `NO_COLOR` and `TERM=dumb` first, then `COLORTERM`, then `TERM`. tmux exports
    /// `COLORTERM=truecolor` to every pane and converts 24-bit colours itself when its own
    /// terminal cannot show them, so no `tmux info` is asked.
    public static func detect(_ env: [String: String]) -> ColorDepth {
        if let noColor = env["NO_COLOR"], !noColor.isEmpty { return .none }
        let term = env["TERM"] ?? ""
        if term == "dumb" { return .none }
        if ["truecolor", "24bit"].contains(env["COLORTERM"]?.lowercased() ?? "") { return .truecolor }
        if term.hasSuffix("-direct") { return .truecolor }
        if term.contains("256color") { return .indexed }
        return .ansi
    }

    /// The cell style for a foreground and a background swatch. At sixteen colours each swatch
    /// gives its hand-picked code, or only its bold or dim; with no colour only attributes are
    /// left, and a cell whose meaning is its background (`solid`: a bar, a chip, a flag) turns to
    /// reverse video wherever that background cannot be painted.
    public func style(_ fg: Swatch?, _ bg: Swatch? = nil, _ attributes: Style.Attributes = [], solid: Bool = false) -> Style {
        var style: Style
        switch self {
        case .truecolor:
            style = Style(fg: fg.map { .rgb($0.r, $0.g, $0.b) } ?? .none, bg: bg.map { .rgb($0.r, $0.g, $0.b) } ?? .none, attributes)
        case .indexed:
            style = Style(fg: fg.map { .indexed($0.index) } ?? .none, bg: bg.map { .indexed($0.index) } ?? .none, attributes)
        case .ansi:
            style = Style(fg: fg?.ansi.map(Color.ansi) ?? .none, bg: bg?.ansiBackground.map(Color.ansi) ?? .none,
                          attributes.union(fg?.attributes ?? []))
            if solid, style.bg == .none {
                // Reversed, the background's own colour is what shows: a SOLO chip stays yellow.
                if let ink = bg?.ansi { style.fg = .ansi(ink) }
                style.attributes.insert(.reverse)
            }
        case .none:
            style = Style(attributes.union(fg?.attributes ?? []))
            if solid { style.attributes.insert(.reverse) }
        }
        if style.attributes.contains(.bold) { style.attributes.remove(.dim) }
        return style
    }
}

/// One colour at every depth: 24-bit, its xterm-256 index, and what stands in for it among the
/// terminal's sixteen, chosen by hand rather than converted (lipgloss's `Complete`): a
/// foreground code and/or bold or dim, and a background code where that surface is painted at all.
public struct Swatch: Hashable {
    public var r, g, b: UInt8
    private var pickedIndex: UInt8?
    public var ansi: UInt8?
    public var ansiBackground: UInt8?
    public var attributes: Style.Attributes

    /// `sgr` and `background` are SGR codes as a 16-colour terminal takes them (32, 92; 42, 100).
    public init(_ hex: UInt32, sgr: Int? = nil, _ attributes: Style.Attributes = [], background: Int? = nil, index: UInt8? = nil) {
        self.init(r: UInt8(hex >> 16 & 0xFF), g: UInt8(hex >> 8 & 0xFF), b: UInt8(hex & 0xFF), sgr: sgr, attributes,
                  background: background, index: index)
    }

    public init(r: UInt8, g: UInt8, b: UInt8, sgr: Int? = nil, _ attributes: Style.Attributes = [], background: Int? = nil,
                index: UInt8? = nil) {
        self.r = r
        self.g = g
        self.b = b
        pickedIndex = index
        ansi = sgr.map { UInt8($0 >= 90 ? $0 - 82 : $0 - 30) }
        ansiBackground = background.map { UInt8($0 >= 100 ? $0 - 92 : $0 - 40) }
        self.attributes = attributes
    }

    /// The xterm-256 index: picked by hand, or the nearest by tmux's rule, worked out only when
    /// a 256-colour terminal asks.
    public var index: UInt8 {
        get { pickedIndex ?? Self.nearest256(r, g, b) }
        set { pickedIndex = newValue }
    }

    /// This colour moved `t` of the way toward `other` (0 keeps it); the sixteen-colour stand-ins
    /// stay unless given.
    public func mixed(toward other: Swatch, _ t: Double) -> Swatch {
        func blend(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        var result = Swatch(r: blend(r, other.r), g: blend(g, other.g), b: blend(b, other.b))
        result.ansi = ansi
        result.ansiBackground = ansiBackground
        result.attributes = attributes
        return result
    }

    public func with(sgr: Int?, _ attributes: Style.Attributes, background: Int? = nil) -> Swatch {
        var copy = Swatch(r: r, g: g, b: b, sgr: sgr, attributes, background: background)
        copy.pickedIndex = pickedIndex
        return copy
    }

    private static let cube: [Int] = [0x00, 0x5F, 0x87, 0xAF, 0xD7, 0xFF]

    /// tmux's `colour_find_rgb`: the xterm cube's real levels, or the grey ramp when it is closer.
    public static func nearest256(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt8 {
        func level(_ v: Int) -> Int { v < 48 ? 0 : (v < 114 ? 1 : (v - 35) / 40) }
        let (ri, gi, bi) = (Int(r), Int(g), Int(b))
        let (qr, qg, qb) = (level(ri), level(gi), level(bi))
        let (cr, cg, cb) = (cube[qr], cube[qg], cube[qb])
        let inCube = UInt8(16 + 36 * qr + 6 * qg + qb)
        if (cr, cg, cb) == (ri, gi, bi) { return inCube }
        let average = (ri + gi + bi) / 3
        let greyIndex = average > 238 ? 23 : max(average - 3, 0) / 10
        let grey = 8 + 10 * greyIndex
        func distance(_ x: Int, _ y: Int, _ z: Int) -> Int { (x - ri) * (x - ri) + (y - gi) * (y - gi) + (z - bi) * (z - bi) }
        return distance(grey, grey, grey) < distance(cr, cg, cb) ? UInt8(232 + greyIndex) : inCube
    }
}
