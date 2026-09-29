/// A foreground or background: the terminal's own (`none`), one of its sixteen (0–7, then the
/// bright 8–15), one of the 256, or 24-bit.
public enum Color: Hashable {
    case none
    case ansi(UInt8)
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    func codes(background: Bool) -> [Int] {
        switch self {
        case .none: return [background ? 49 : 39]
        case .ansi(let n): return [(n < 8 ? 30 : 82) + Int(n) + (background ? 10 : 0)]
        case .indexed(let n): return [background ? 48 : 38, 5, Int(n)]
        case .rgb(let r, let g, let b): return [background ? 48 : 38, 2, Int(r), Int(g), Int(b)]
        }
    }
}

public struct Style: Hashable {
    public struct Attributes: OptionSet, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let bold = Attributes(rawValue: 1)
        public static let dim = Attributes(rawValue: 2)
        public static let italic = Attributes(rawValue: 4)
        public static let underline = Attributes(rawValue: 8)
        public static let reverse = Attributes(rawValue: 16)

        static let codes: [(Attributes, Int)] = [(.bold, 1), (.dim, 2), (.italic, 3), (.underline, 4), (.reverse, 7)]
    }

    public var fg: Color
    public var bg: Color
    public var attributes: Attributes

    public init(fg: Color = .none, bg: Color = .none, _ attributes: Attributes = []) {
        self.fg = fg
        self.bg = bg
        self.attributes = attributes
    }

    public init(_ attributes: Attributes) { self.init(fg: .none, bg: .none, attributes) }

    public static let plain = Style()
    public static let bold = Style(.bold)
    public static let dim = Style(.dim)
    public static let reverse = Style(.reverse)

    /// The SGR parameters that set this style from a reset.
    public var codes: [Int] {
        var codes = Attributes.codes.filter { attributes.contains($0.0) }.map(\.1)
        if fg != .none { codes += fg.codes(background: false) }
        if bg != .none { codes += bg.codes(background: true) }
        return codes
    }

    /// SGR parameters applied in order on top of this style, `38;5;n` and `38;2;r;g;b` (and
    /// their `48` twins) included; anything else is ignored.
    public func applying(_ parameters: [Int]) -> Style {
        var next = self
        var i = 0
        func extended() -> Color? {
            guard i + 1 < parameters.count else { return nil }
            if parameters[i + 1] == 5, i + 2 < parameters.count {
                defer { i += 2 }
                return .indexed(UInt8(truncatingIfNeeded: parameters[i + 2]))
            }
            if parameters[i + 1] == 2, i + 4 < parameters.count {
                defer { i += 4 }
                return .rgb(UInt8(truncatingIfNeeded: parameters[i + 2]), UInt8(truncatingIfNeeded: parameters[i + 3]),
                            UInt8(truncatingIfNeeded: parameters[i + 4]))
            }
            return nil
        }
        while i < parameters.count {
            let code = parameters[i]
            switch code {
            case 0: next = .plain
            case 22: next.attributes.subtract([.bold, .dim])
            case 23: next.attributes.remove(.italic)
            case 24: next.attributes.remove(.underline)
            case 27: next.attributes.remove(.reverse)
            case 30...37: next.fg = .ansi(UInt8(code - 30))
            case 90...97: next.fg = .ansi(UInt8(code - 82))
            case 40...47: next.bg = .ansi(UInt8(code - 40))
            case 100...107: next.bg = .ansi(UInt8(code - 92))
            case 39: next.fg = .none
            case 49: next.bg = .none
            case 38: if let color = extended() { next.fg = color }
            case 48: if let color = extended() { next.bg = color }
            default:
                if let attribute = Attributes.codes.first(where: { $0.1 == code }) { next.attributes.insert(attribute.0) }
            }
            i += 1
        }
        return next
    }
}

/// One column: a grapheme cluster and how many columns it takes. The right half of a wide
/// glyph is a continuation cell with no text and width 0.
public struct Cell: Equatable {
    public var text: String
    public var width: UInt8
    public var style: Style

    public init(_ text: String, width: UInt8 = 1, style: Style = .plain) {
        self.text = text
        self.width = width
        self.style = style
    }

    public static let blank = Cell(" ")
    static let continuation = Cell("", width: 0)

    public var isContinuation: Bool { width == 0 }
}

public struct Size: Equatable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// A grid of cells a view draws into; only the renderer turns it into bytes.
public struct Screen: Equatable {
    public let width: Int
    public let height: Int
    public private(set) var cells: [Cell]

    public init(width: Int, height: Int) {
        self.width = max(width, 0)
        self.height = max(height, 0)
        cells = Array(repeating: .blank, count: self.width * self.height)
    }

    public init(_ size: Size) { self.init(width: size.cols, height: size.rows) }

    public var size: Size { Size(cols: width, rows: height) }
    public var area: Rect { Rect(x: 0, y: 0, width: width, height: height) }

    public subscript(x: Int, y: Int) -> Cell {
        get { cells[y * width + x] }
    }

    public mutating func clear() {
        for i in cells.indices { cells[i] = .blank }
    }

    /// Writes one glyph; half of a wide glyph it overwrites is blanked, so no stray half is left.
    public mutating func set(_ x: Int, _ y: Int, _ cell: Cell) {
        guard y >= 0, y < height, x >= 0, x + Int(max(cell.width, 1)) <= width else { return }
        let i = y * width + x
        if cells[i].isContinuation, x > 0 { cells[i - 1] = Cell(" ", style: cells[i - 1].style) }
        if cells[i].width == 2, x + 1 < width, cell.width != 2 { cells[i + 1] = Cell(" ", style: cells[i].style) }
        cells[i] = cell
        if cell.width == 2 {
            if x + 2 < width, cells[i + 2].isContinuation { cells[i + 2] = Cell(" ", style: cells[i + 1].style) }
            cells[i + 1] = Cell("", width: 0, style: cell.style)
        }
    }

    /// Draws `text` from `x`, stopping at `limit` columns (the row's end by default); a wide
    /// glyph that would straddle the limit is left out and its column padded. Control
    /// characters take no column and are dropped. Returns the columns drawn.
    @discardableResult
    public mutating func put(_ text: String, x: Int, y: Int, style: Style = .plain, limit: Int? = nil) -> Int {
        guard y >= 0, y < height else { return 0 }
        let end = min(x + (limit ?? width), width)
        var column = x
        for c in text {
            let w = TerminalText.width(of: c)
            if w == 0 { continue }
            if column + w > end {
                while column < end { set(column, y, Cell(" ", style: style)); column += 1 }
                break
            }
            if column >= 0 { set(column, y, Cell(String(c), width: UInt8(w), style: style)) }
            column += w
        }
        return column - x
    }

    public mutating func fill(_ rect: Rect, with cell: Cell = .blank) {
        let r = rect.intersection(area)
        for y in r.y..<(r.y + r.height) {
            for x in r.x..<(r.x + r.width) { set(x, y, cell) }
        }
    }

    /// Re-styles cells in place, keeping their text: a selected row, a highlight.
    public mutating func restyle(_ rect: Rect, _ change: (inout Style) -> Void) {
        let r = rect.intersection(area)
        for y in r.y..<(r.y + r.height) {
            for x in r.x..<(r.x + r.width) { change(&cells[y * width + x].style) }
        }
    }

    /// The text of each row, trailing blanks kept: what a golden file compares.
    public func lines() -> [String] {
        (0..<height).map { y in
            var line = ""
            for x in 0..<width { line += self[x, y].text }
            return line
        }
    }

    /// Rows with each styled run marked `[codes]text[/]`, codes being the SGR parameters of
    /// the run: styling a plain golden file cannot show.
    public func markedLines() -> [String] {
        (0..<height).map { y in
            var line = ""
            var current = Style.plain
            for x in 0..<width {
                let cell = self[x, y]
                if cell.isContinuation { continue }
                if cell.style != current {
                    if current != .plain { line += "[/]" }
                    if cell.style != .plain { line += "[" + cell.style.codes.map(String.init).joined(separator: ";") + "]" }
                    current = cell.style
                }
                line += cell.text
            }
            return current == .plain ? line : line + "[/]"
        }
    }
}
