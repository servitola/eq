/// Turns a screen into the bytes that bring the terminal from the last screen written to it:
/// only changed cells; a cursor move per row, and within a row a jump (`CUF`) over unchanged
/// cells only where it is shorter than writing them again; SGR only for what changes from the
/// pen the terminal already holds, each transition encoded once and cached; the whole frame
/// inside synchronized-update brackets (DECSET 2026), which a terminal that knows them shows at
/// once and one that does not ignores.
public struct Renderer {
    public static let beginSync = "\u{1B}[?2026h"
    public static let endSync = "\u{1B}[?2026l"
    public static let clear = "\u{1B}[H\u{1B}[2J"

    public var synchronized = true
    private var front: Screen?
    private var transitions: [Transition: [UInt8]] = [:]

    private struct Transition: Hashable {
        var from: Style
        var to: Style
    }

    public init() {}

    /// The terminal's screen is no longer what was last written (a resume, a focus-in on a
    /// terminal that dropped it): the next frame is drawn whole.
    public mutating func invalidate() { front = nil }

    public mutating func render(_ back: Screen) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(8192)
        let previous = front.flatMap { $0.width == back.width && $0.height == back.height ? $0 : nil }
        if synchronized { out += Self.beginSync.utf8 }
        if previous == nil { out += Self.clear.utf8 }
        var pen = Style.plain
        let empty = out.count
        for y in 0..<back.height {
            var cursor: Int?
            var x = 0
            while let start = nextChange(back, previous, y: y, from: x) {
                var end = start
                while end < back.width, differs(back, previous, x: end, y: y) { end += 1 }
                if let at = cursor {
                    let jump = Self.jump(start - at)
                    let rewrite = cost(back, y: y, from: at, to: start, pen: pen, limit: jump.count)
                    if rewrite <= jump.count { write(back, y: y, from: at, to: start, pen: &pen, into: &out) } else { out += jump }
                } else {
                    out += "\u{1B}[\(y + 1);\(start + 1)H".utf8
                }
                end = write(back, y: y, from: start, to: end, pen: &pen, into: &out)
                cursor = end
                x = end
            }
        }
        if pen != .plain { out += transition(from: pen, to: .plain) }
        front = back
        // Nothing changed: no bytes at all, not even the brackets.
        if previous != nil, out.count == empty { return [] }
        if synchronized { out += Self.endSync.utf8 }
        return out
    }

    private static func jump(_ columns: Int) -> [UInt8] {
        Array((columns == 1 ? "\u{1B}[C" : "\u{1B}[\(columns)C").utf8)
    }

    /// Writes the cells from `x` to `end`; a wide glyph whose lead is inside is written whole,
    /// so the returned column, where the cursor now is, may be one past `end`.
    @discardableResult
    private mutating func write(_ back: Screen, y: Int, from x: Int, to end: Int, pen: inout Style, into out: inout [UInt8]) -> Int {
        var column = x
        while column < end {
            let cell = back[column, y]
            if cell.isContinuation {
                column += 1
                continue
            }
            if cell.style != pen {
                out += transition(from: pen, to: cell.style)
                pen = cell.style
            }
            out += cell.text.utf8
            column += Int(cell.width)
        }
        return column
    }

    /// The bytes writing the cells from `x` to `end` again would take, stopping once past `limit`.
    private mutating func cost(_ back: Screen, y: Int, from x: Int, to end: Int, pen: Style, limit: Int) -> Int {
        var bytes = 0
        var pen = pen
        var column = x
        while column < end, bytes <= limit {
            let cell = back[column, y]
            if cell.isContinuation { return .max }
            if cell.style != pen {
                bytes += transition(from: pen, to: cell.style).count
                pen = cell.style
            }
            bytes += cell.text.utf8.count
            column += Int(cell.width)
        }
        return bytes
    }

    /// The first column from `x` whose cell differs; a changed continuation starts at its lead.
    private func nextChange(_ back: Screen, _ front: Screen?, y: Int, from x: Int) -> Int? {
        var i = x
        while i < back.width {
            if differs(back, front, x: i, y: y) {
                return back[i, y].isContinuation && i > 0 ? i - 1 : i
            }
            i += 1
        }
        return nil
    }

    private func differs(_ back: Screen, _ front: Screen?, x: Int, y: Int) -> Bool {
        guard let front else { return back[x, y] != .blank }
        return back[x, y] != front[x, y]
    }

    /// Only what changes; a reset (`0`) only when an attribute has to go off.
    private mutating func transition(from pen: Style, to style: Style) -> [UInt8] {
        let key = Transition(from: pen, to: style)
        if let cached = transitions[key] { return cached }
        var codes: [Int]
        if !pen.attributes.subtracting(style.attributes).isEmpty {
            codes = [0] + style.codes
        } else {
            let fresh = Style(fg: style.fg == pen.fg ? .none : style.fg, bg: style.bg == pen.bg ? .none : style.bg,
                              style.attributes.subtracting(pen.attributes))
            codes = fresh.codes
            if style.fg == .none, pen.fg != .none { codes += [39] }
            if style.bg == .none, pen.bg != .none { codes += [49] }
        }
        var text = "\u{1B}["
        for (i, code) in codes.enumerated() { text += (i == 0 ? "" : ";") + String(code) }
        let bytes = Array((text + "m").utf8)
        if transitions.count > 4096 { transitions = [:] }
        transitions[key] = bytes
        return bytes
    }
}
