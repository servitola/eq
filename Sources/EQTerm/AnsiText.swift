/// Text that carries SGR escapes (`ESC [ … m`), as eq's `Paint` writes it and a child `eq`
/// prints it, drawn as cells. Any other escape sequence is skipped whole.
public enum AnsiText {
    private static let ascii: [String] = (0..<128).map { String(UnicodeScalar(UInt8($0))) }

    /// Draws one line of `text` at (`x`, `y`), in at most `limit` columns; returns the columns drawn.
    @discardableResult
    public static func draw(_ text: String, into screen: inout Screen, x: Int, y: Int, limit: Int? = nil,
                            base: Style = .plain) -> Int {
        guard y >= 0, y < screen.height else { return 0 }
        let end = min(x + (limit ?? screen.width), screen.width)
        var style = base
        var column = x
        let bytes = text.utf8
        var i = bytes.startIndex
        // Printable ASCII goes cell by cell straight from the bytes; anything else by grapheme cluster.
        func put(_ cell: Cell) -> Bool {
            let w = Int(cell.width)
            if column + w > end {
                while column < end { screen.set(column, y, Cell(" ", style: style)); column += 1 }
                return false
            }
            if column >= 0 { screen.set(column, y, cell) }
            column += w
            return true
        }
        // The last printable ASCII character drawn, if nothing came after it yet: a combining mark
        // or variation selector that follows belongs to its grapheme cluster.
        var lastASCII: (index: String.Index, column: Int)?
        while i < bytes.endIndex {
            let byte = bytes[i]
            defer { if byte >= 0x80 || byte == 0x1B { lastASCII = nil } }
            if byte == 0x1B {
                i = bytes.index(after: i)
                guard i < bytes.endIndex else { break }
                guard bytes[i] == UInt8(ascii: "[") else {
                    i = bytes.index(after: i)
                    continue
                }
                i = bytes.index(after: i)
                var parameters: [Int] = []
                var value = 0
                while i < bytes.endIndex, !(0x40...0x7E).contains(bytes[i]) {
                    let b = bytes[i]
                    if b == UInt8(ascii: ";") {
                        parameters.append(value)
                        value = 0
                    } else if (0x30...0x39).contains(b) {
                        value = value * 10 + Int(b - 0x30)
                    }
                    i = bytes.index(after: i)
                }
                guard i < bytes.endIndex else { break }
                if bytes[i] == UInt8(ascii: "m") {
                    parameters.append(value)
                    style = parameters.first == 0 ? base.applying(Array(parameters.dropFirst())) : style.applying(parameters)
                }
                i = bytes.index(after: i)
                continue
            }
            if byte < 0x80 {
                i = bytes.index(after: i)
                if byte < 0x20 || byte == 0x7F {
                    lastASCII = nil
                    continue
                }
                lastASCII = (bytes.index(before: i), column)
                guard put(Cell(ascii[Int(byte)], style: style)) else { return column - x }
                continue
            }
            var start = i
            if let last = lastASCII {
                start = last.index
                column = last.column
            }
            var run = i
            while run < bytes.endIndex, bytes[run] >= 0x80 { run = bytes.index(after: run) }
            for c in text[start..<run] {
                let w = TerminalText.width(of: c)
                if w == 0 { continue }
                guard put(Cell(String(c), width: UInt8(w), style: style)) else { return column - x }
            }
            i = run
        }
        return column - x
    }
}
