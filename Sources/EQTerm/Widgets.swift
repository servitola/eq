/// A run of text in one style.
public struct Span: Equatable {
    public var text: String
    public var style: Style

    public init(_ text: String, _ style: Style = .plain) {
        self.text = text
        self.style = style
    }
}

public extension Screen {
    /// Spans one after another on row `rect.y`; what does not fit is cut with `…`.
    @discardableResult
    mutating func draw(_ spans: [Span], in rect: Rect, ellipsis: Bool = true) -> Int {
        guard !rect.isEmpty else { return 0 }
        let total = spans.reduce(0) { $0 + TerminalText.width($1.text) }
        var x = rect.x
        var room = rect.width
        let cut = ellipsis && total > rect.width
        if cut { room -= 1 }
        for span in spans where room > 0 {
            let used = put(span.text, x: x, y: rect.y, style: span.style, limit: room)
            x += used
            room -= used
        }
        if cut {
            let style = spans.last(where: { !$0.text.isEmpty })?.style ?? .plain
            put("…", x: x, y: rect.y, style: style, limit: 1)
            x += 1
        }
        return x - rect.x
    }
}

/// Vertical bars growing from the bottom of `rect`, one per value in 0…1, with eighth-row tops.
public enum Bars {
    static let partials = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    /// Each bar is `barWidth` wide and starts `pitch` columns after the one before.
    public static func draw(_ values: [Double], styles: [Style], into screen: inout Screen, rect: Rect,
                            barWidth: Int = 1, pitch: Int = 2) {
        for (i, value) in values.enumerated() {
            let x = rect.x + i * pitch
            guard x + barWidth <= rect.right else { break }
            let filled = min(max(value.isFinite ? value : 0, 0), 1) * Double(rect.height)
            let full = Int(filled)
            let fraction = filled - Double(full)
            let style = i < styles.count ? styles[i] : .plain
            for row in 0..<rect.height {
                let fromBottom = rect.height - 1 - row
                let glyph: String
                if fromBottom < full { glyph = "█" } else if fromBottom == full, fraction > 0 {
                    glyph = partials[min(Int(fraction * 8), partials.count - 1)]
                } else { continue }
                for dx in 0..<barWidth { screen.set(x + dx, rect.y + row, Cell(glyph, style: style)) }
            }
        }
    }
}

/// A horizontal bar for a ratio, with a label over its middle.
public enum Gauge {
    public static func draw(_ ratio: Double, label: String? = nil, style: Style = .plain, into screen: inout Screen, rect: Rect) {
        guard !rect.isEmpty else { return }
        let r = min(max(ratio.isFinite ? ratio : 0, 0), 1)
        let filled = Int((r * Double(rect.width)).rounded())
        for x in 0..<rect.width {
            screen.set(rect.x + x, rect.y, Cell(x < filled ? "█" : "░", style: x < filled ? style : .dim))
        }
        let text = label ?? "\(Int((r * 100).rounded()))%"
        let w = min(TerminalText.width(text), rect.width)
        let start = rect.x + (rect.width - w) / 2
        for x in start..<(start + w) { screen.set(x, rect.y, Cell(" ", style: .reverse)) }
        screen.put(text, x: start, y: rect.y, style: .reverse, limit: w)
    }
}

/// Selection and scroll of a list, kept in the model (ratatui's `StatefulWidget` state).
public struct ListState: Equatable {
    public var selected: Int
    public var offset: Int

    public init(selected: Int = 0, offset: Int = 0) {
        self.selected = selected
        self.offset = offset
    }

    /// Moves the selection by `delta`, clamped to `count` items, and scrolls it into a window
    /// of `visible` rows.
    public mutating func move(_ delta: Int, count: Int, visible: Int) {
        guard count > 0 else { selected = 0; offset = 0; return }
        selected = min(max(selected + delta, 0), count - 1)
        scrollIntoView(visible: visible, count: count)
    }

    public mutating func scrollIntoView(visible: Int, count: Int) {
        let rows = max(visible, 1)
        if selected < offset { offset = selected }
        if selected >= offset + rows { offset = selected - rows + 1 }
        offset = min(max(offset, 0), max(count - rows, 0))
    }
}

public enum ListView {
    /// One row per item from `state.offset`; the selected one in reverse video, which reads
    /// the same in monochrome.
    public static func draw(_ items: [[Span]], state: ListState, into screen: inout Screen, rect: Rect) {
        for row in 0..<rect.height {
            let index = state.offset + row
            guard index < items.count else { break }
            let line = rect.row(row)
            screen.draw(items[index], in: line)
            if index == state.selected { screen.restyle(line) { $0.attributes.insert(.reverse) } }
        }
    }
}

public enum TableView {
    public struct Column {
        public var title: String
        public var width: Constraint
        public init(_ title: String, _ width: Constraint) {
            self.title = title
            self.width = width
        }
    }

    /// A bold header row, then the rows as a list; columns share the width by their constraints,
    /// one blank column between them.
    public static func draw(_ columns: [Column], rows: [[Span]], state: ListState, into screen: inout Screen, rect: Rect) {
        guard rect.height > 0, !columns.isEmpty else { return }
        let gaps = columns.count - 1
        let cells = Rect(x: rect.x, y: rect.y, width: rect.width - gaps, height: rect.height)
            .split(.horizontal, columns.map(\.width))
        func place(_ i: Int) -> Rect { Rect(x: cells[i].x + i, y: 0, width: cells[i].width, height: 1) }
        for i in columns.indices {
            var at = place(i)
            at.y = rect.y
            screen.draw([Span(columns[i].title, .bold)], in: at)
        }
        let body = Rect(x: rect.x, y: rect.y + 1, width: rect.width, height: rect.height - 1)
        for row in 0..<body.height {
            let index = state.offset + row
            guard index < rows.count else { break }
            for i in columns.indices where i < rows[index].count {
                var at = place(i)
                at.y = body.y + row
                screen.draw([rows[index][i]], in: at)
            }
            if index == state.selected { screen.restyle(body.row(row)) { $0.attributes.insert(.reverse) } }
        }
    }
}

public enum Tabs {
    /// Titles in a row, two blanks apart; the current one bold, underlined and, so that it still
    /// shows without colour, reversed. Returns each title's columns, for mouse clicks.
    @discardableResult
    public static func draw(_ titles: [String], selected: Int, into screen: inout Screen, rect: Rect) -> [Range<Int>] {
        var x = rect.x
        var hits: [Range<Int>] = []
        for (i, title) in titles.enumerated() {
            let style = i == selected ? Style([.bold, .underline, .reverse]) : .plain
            let used = screen.put(title, x: x, y: rect.y, style: style, limit: max(rect.right - x, 0))
            hits.append(x..<(x + used))
            x += used + 2
            if x >= rect.right { break }
        }
        return hits
    }
}

public enum Keybar {
    public struct Entry: Equatable {
        public var key: String
        public var text: String
        /// Keybar order, and the last to drop has the lowest; 0 is never dropped.
        public var rank: Int
        public init(key: String, text: String, rank: Int) {
            self.key = key
            self.text = text
            self.rank = rank
        }
        public var plain: String { key + " " + text }
    }

    public static let separator = "  "

    /// Entries most useful first; whole entries drop from the right, highest rank first, until
    /// the line fits, then from the left among the pinned ones.
    public static func fit(_ entries: [Entry], width: Int) -> [Entry] {
        var entries = entries.sorted { ($0.rank == 0 ? Int.max : $0.rank) < ($1.rank == 0 ? Int.max : $1.rank) }
        func plain() -> Int { TerminalText.width(entries.map(\.plain).joined(separator: separator)) }
        while plain() > width, let drop = entries.indices.filter({ entries[$0].rank > 0 }).max(by: { entries[$0].rank < entries[$1].rank }) {
            entries.remove(at: drop)
        }
        while plain() > width, entries.count > 1 { entries.removeFirst() }
        return entries
    }

    public static func draw(_ entries: [Entry], into screen: inout Screen, rect: Rect, keyStyle: Style = .bold) {
        let shown = fit(entries, width: rect.width)
        var spans: [Span] = []
        for (i, entry) in shown.enumerated() {
            if i > 0 { spans.append(Span(separator)) }
            spans += [Span(entry.key, keyStyle), Span(" " + entry.text)]
        }
        screen.draw(spans, in: rect, ellipsis: false)
    }
}

public enum Modal {
    /// A box with `title` in its top border, centred in `area`, `lines` inside from `scroll`;
    /// when not all fit, the bottom border says which part shows. Returns the box, or nil when
    /// the area is too small for one.
    @discardableResult
    public static func draw(title: String, lines: [[Span]], scroll: Int = 0, into screen: inout Screen, area: Rect,
                            border: Style = .dim) -> Rect? {
        guard area.height >= 3 else { return nil }
        let height = min(lines.count + 2, area.height)
        let visible = height - 2
        let start = min(max(scroll, 0), max(lines.count - visible, 0))
        let position = lines.count > visible ? " \(start + 1)–\(start + visible) of \(lines.count) " : ""
        let contentWidth = lines.map { $0.reduce(0) { $0 + TerminalText.width($1.text) } }.max() ?? 0
        let boxWidth = min(area.width, max(contentWidth + 4, TerminalText.width(position) + 2))
        guard boxWidth >= TerminalText.width(title) + 6 else { return nil }
        let box = area.centered(width: boxWidth, height: height)
        screen.fill(box)
        let dashes = String(repeating: "─", count: max(box.width - TerminalText.width(title) - 4, 0))
        screen.draw([Span("┌ ", border), Span(title), Span(" " + dashes + "┐", border)], in: box.row(0), ellipsis: false)
        for i in 0..<visible where start + i < lines.count {
            let y = box.y + 1 + i
            screen.put("│", x: box.x, y: y, style: border)
            screen.draw(lines[start + i], in: Rect(x: box.x + 2, y: y, width: box.width - 4, height: 1))
            screen.put("│", x: box.right - 1, y: y, style: border)
        }
        let rest = max(box.width - 2 - TerminalText.width(position), 0)
        screen.put("└" + String(repeating: "─", count: rest / 2) + position + String(repeating: "─", count: rest - rest / 2) + "┘",
                   x: box.x, y: box.bottom - 1, style: border)
        return box
    }
}

/// A one-line text input: typing, paste, Backspace, Ctrl-W (word), Ctrl-U (all), ← → Home End.
public struct TextField: Equatable {
    public var text: String
    /// In characters, 0…text.count.
    public var cursor: Int

    public init(_ text: String = "") {
        self.text = text
        cursor = text.count
    }

    public enum Outcome: Equatable {
        case editing, submit(String), cancel, ignored
    }

    public mutating func handle(_ event: InputEvent) -> Outcome {
        switch event {
        case .paste(let pasted):
            insert(pasted.filter { !$0.isNewline && $0.asciiValue.map { $0 >= 0x20 && $0 != 0x7F } ?? true })
            return .editing
        case .key(let key):
            return handle(key)
        default:
            return .ignored
        }
    }

    public mutating func handle(_ key: KeyPress) -> Outcome {
        guard key.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        switch key.code {
        case .esc: return .cancel
        case .char("\n"), .char("\r"): return .submit(text)
        case .char("\u{7F}"), .char("\u{08}"):
            guard cursor > 0 else { return .editing }
            remove(cursor - 1..<cursor)
        case .char("\u{17}"):
            let chars = Array(text)
            var start = cursor
            while start > 0, chars[start - 1] == " " { start -= 1 }
            while start > 0, chars[start - 1] != " " { start -= 1 }
            remove(start..<cursor)
        case .char("\u{15}"):
            remove(0..<cursor)
        case .left: cursor = max(cursor - 1, 0)
        case .right: cursor = min(cursor + 1, text.count)
        case .home: cursor = 0
        case .end: cursor = text.count
        case .delete:
            guard cursor < text.count else { return .editing }
            remove(cursor..<cursor + 1)
        case .char(let c):
            guard !c.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return .ignored }
            insert(String(c))
        default:
            return .ignored
        }
        return .editing
    }

    private mutating func insert(_ s: String) {
        let at = text.index(text.startIndex, offsetBy: cursor)
        text.insert(contentsOf: s, at: at)
        cursor += s.count
    }

    private mutating func remove(_ range: Range<Int>) {
        let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: range.upperBound)
        text.removeSubrange(lower..<upper)
        cursor = range.lowerBound
    }

    /// The text with `cursorGlyph` at the cursor, keeping the cursor in sight when it is longer
    /// than `width`: the end of a long name is where the typing happens.
    public func display(width: Int, cursorGlyph: String = "▏") -> String {
        let chars = Array(text)
        let shown = String(chars[..<cursor]) + cursorGlyph + String(chars[cursor...])
        guard TerminalText.width(shown) > width else { return shown }
        let head = String(chars[..<cursor]) + cursorGlyph
        var tail = ""
        for c in head.reversed() {
            guard TerminalText.width(tail) + TerminalText.width(of: c) <= width else { break }
            tail = String(c) + tail
        }
        return tail
    }
}
