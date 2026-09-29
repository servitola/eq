import EQTerm
import Foundation

/// The key list and the instrument table, drawn over the meter, which fades behind them.
struct Overlay {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    static let fade = 0.68

    /// Where the box goes: under the status bar, over everything down to the message row.
    static func area(_ size: Size) -> Rect {
        Rect(x: 0, y: 1, width: size.cols, height: max(size.rows - 3, 0))
    }

    /// Rows of content and how many show at once, for scrolling to stop where the last one shows.
    static func metrics(_ modal: WatchModal, size: Size) -> (rows: Int, visible: Int) {
        let box = self.box(modal, size: size)
        switch modal {
        case .help: return (HelpLayout(width: box.width).rows.count, max(box.height - 3, 1))
        case .instruments: return (InstrumentRows.count + 1, max(box.height - 2, 1))
        }
    }

    static func box(_ modal: WatchModal, size: Size) -> Rect {
        let area = self.area(size)
        switch modal {
        case .help:
            let width = min(area.width - (area.width >= 46 ? 6 : 0), 112)
            return Rect(x: area.x + (area.width - width) / 2, y: area.y, width: width, height: area.height)
        case .instruments:
            let width = min(area.width - (area.width >= 64 ? 2 : 0), InstrumentRows.widthWanted)
            let height = min(InstrumentRows.count + 1 + 2, area.height)
            return Rect(x: area.x + (area.width - width) / 2, y: area.y + max((area.height - height) / 2, 0), width: width, height: height)
        }
    }

    func draw(_ modal: WatchModal, into screen: inout Screen) {
        let size = scene.size
        var faded = scene
        faded.fade = Self.fade
        faded.modal = nil
        faded.draw(into: &screen)
        let bottom = Rect(x: 0, y: max(size.rows - 2, 0), width: size.cols, height: min(2, size.rows))
        screen.fill(bottom, with: t.blank)
        ShellRows(scene: scene).draw(messageY: size.rows >= 10 ? size.rows - 2 : nil, keybarY: size.rows - 1, x: 1, widen: false,
                                     into: &screen)
        let box = Self.box(modal, size: size)
        guard box.height >= 3, box.width >= 16 else { return }
        let (rows, visible) = Self.metrics(modal, size: size)
        let start = min(max(modal.scroll, 0), max(rows - visible, 0))
        let position = rows > visible ? " \(start + 1)–\(start + visible) of \(rows) " : nil
        switch modal {
        case .help:
            Boxes.draw(box, into: &screen, t, border: p.borderHi, title: "keys", titleInk: p.title, fill: p.surface)
            help(box, start: start, visible: visible, into: &screen)
        case .instruments:
            let ranges = Instruments.all.reduce(0) { $0 + $1.ranges.count }
            Boxes.draw(box, into: &screen, t, border: p.borderHi, title: "instruments",
                       right: "\(Instruments.all.count) instruments · \(ranges) ranges", titleInk: p.title, fill: p.surface)
            InstrumentRows(scene: scene, box: box).draw(start: start, visible: visible, into: &screen)
        }
        if let position, box.width >= position.count + 4 {
            screen.ink(position, x: box.x + (box.width - position.count) / 2, y: box.bottom - 1, t.style(p.text3, p.surface))
        }
    }

    private func help(_ box: Rect, start: Int, visible: Int, into screen: inout Screen) {
        let layout = HelpLayout(width: box.width)
        for (i, row) in layout.rows.dropFirst(start).prefix(visible).enumerated() {
            let y = box.y + 2 + i
            for (column, item) in row.enumerated() {
                guard let item else { continue }
                let x = box.x + 3 + column * (layout.columnWidth + 2)
                switch item {
                case .title(let title):
                    let used = screen.ink(title, x: x, y: y, t.style(p.accent, p.surface, .bold))
                    let rule = max(layout.columnWidth - used - 1, 0)
                    screen.ink(String(repeating: "─", count: rule), x: x + used + 1, y: y, t.style(p.border, p.surface))
                case .key(let key, let text):
                    screen.ink(" " + key + " ", x: x, y: y, t.style(p.keyFg, p.keyBg, .bold))
                    screen.ink(text, x: x + layout.keyWidth + 3, y: y, t.style(p.text2, p.surface))
                case .more(let text):
                    screen.ink(text, x: x + layout.keyWidth + 3, y: y, t.style(p.text2, p.surface))
                case .note(let text):
                    screen.ink(text, x: x, y: y, t.style(p.text3, p.surface))
                }
            }
        }
    }
}

/// The key list in groups, as one column or two side by side; a long description wraps under
/// itself.
struct HelpLayout {
    enum Item: Equatable {
        case title(String), key(String, String), more(String), note(String)
    }

    let columnWidth: Int
    let keyWidth: Int
    let rows: [[Item?]]

    init(width: Int) {
        let entries = KeyHelp.lines()
        keyWidth = entries.filter { !$0.text.isEmpty }.map { TerminalText.width($0.key) }.max() ?? 0
        let inner = width - 6
        let two = inner >= 2 * 44
        columnWidth = two ? (inner - 2) / 2 : max(inner, 0)
        let textWidth = max(columnWidth - keyWidth - 3, 8)
        var groups: [[Item]] = []
        for entry in entries where !(entry.key.isEmpty && entry.text.isEmpty) {
            if entry.text.isEmpty {
                groups.append([.title(entry.key)])
            } else if entry.key.isEmpty {
                groups[groups.count - 1] += Self.wrap(entry.text, width: max(columnWidth, 8)).map(Item.note)
            } else {
                let lines = Self.wrap(entry.text, width: textWidth)
                groups[groups.count - 1] += [.key(entry.key, lines[0])] + lines.dropFirst().map(Item.more)
            }
        }
        func stacked(_ groups: ArraySlice<[Item]>) -> [Item?] {
            groups.enumerated().flatMap { i, group in (i > 0 ? [nil] : []) + group.map(Optional.some) }
        }
        guard two, groups.count > 1 else {
            rows = stacked(groups[...]).map { [$0] }
            return
        }
        let split = (1..<groups.count).min { a, b in
            max(stacked(groups[..<a]).count, stacked(groups[a...]).count) < max(stacked(groups[..<b]).count, stacked(groups[b...]).count)
        } ?? 1
        let left = stacked(groups[..<split]), right = stacked(groups[split...])
        rows = (0..<max(left.count, right.count)).map { i in [i < left.count ? left[i] : nil, i < right.count ? right[i] : nil] }
    }

    /// Words onto lines of at most `width` columns; a word longer than that is cut.
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            let candidate = line.isEmpty ? String(word) : line + " " + word
            if TerminalText.width(candidate) <= width || line.isEmpty {
                line = TerminalText.width(candidate) <= width ? candidate : TerminalText.truncated(candidate, columns: width)
            } else {
                lines.append(line)
                line = TerminalText.width(String(word)) <= width ? String(word) : TerminalText.truncated(String(word), columns: width)
            }
        }
        return lines + [line]
    }
}

/// `eq zones` and `eq boost` as one table: a hue dot, the knob as a centre-zero gauge, `◆` on the
/// character range, each range in Hz, where it sits on a 20 Hz–20 kHz map, and the bands it touches.
struct InstrumentRows {
    let scene: MeterScene
    let box: Rect

    private let t: Theme
    private let p: Palette

    init(scene: MeterScene, box: Rect) {
        self.scene = scene
        self.box = box
        t = scene.theme
        p = t.p
    }

    static var count: Int { Instruments.all.reduce(0) { $0 + $1.ranges.count } }
    static let widthWanted = 118
    static let mapWidth = 30

    private struct Columns {
        var name, knob, value, range, hz: Int
        var map: Int?
        var bands: Int?
    }

    private var columns: Columns {
        let x = box.x
        var c = Columns(name: x + 6, knob: x + 15, value: x + 27, range: x + 35, hz: x + 49)
        let room = box.right - 2
        if room - (c.hz + 13 + Self.mapWidth + 2) >= 14 {
            c.map = c.hz + 13
            c.bands = c.hz + 13 + Self.mapWidth + 2
        } else if room - (c.hz + 13) >= 12 {
            c.bands = c.hz + 13
        }
        return c
    }

    static func hz(_ f: Double) -> String {
        f >= 1000 ? String(format: "%gk", f / 1000) : String(Int(f))
    }

    func draw(start: Int, visible: Int, into screen: inout Screen) {
        let c = columns
        let right = box.right - 1
        var rows: [(Instrument, Int, HzRange)?] = [nil]
        for instrument in Instruments.all {
            for (k, range) in instrument.ranges.enumerated() { rows.append((instrument, k, range)) }
        }
        let l0 = log2(20.0), l1 = log2(20000.0)
        func mapX(_ f: Double) -> Int { Int(((log2(f) - l0) / (l1 - l0) * Double(Self.mapWidth - 1)).rounded()) }
        for (i, row) in rows.dropFirst(start).prefix(visible).enumerated() {
            let y = box.y + 1 + i
            func put(_ text: String, _ x: Int, _ style: Style) {
                guard x < right else { return }
                screen.ink(text, x: x, y: y, style, limit: right - x)
            }
            guard let (instrument, k, range) = row else {
                for (key, text) in [(c.name, "instrument"), (c.value, " knob"), (c.range, "range"), (c.hz, "Hz")] {
                    put(text, key, t.style(p.text3, p.surface))
                }
                if let bands = c.bands { put("bands", bands, t.style(p.text3, p.surface)) }
                if let map = c.map {
                    for (f, label) in [(32.0, "32"), (250, "250"), (2000, "2k"), (16000, "16k")] {
                        put(label, map + mapX(f) - label.count / 2, t.style(p.text3, p.surface))
                    }
                }
                continue
            }
            let selected = instrument == scene.focus
            let bg = selected ? p.sel : p.surface
            if selected { screen.fill(Rect(x: box.x + 1, y: y, width: box.width - 2, height: 1), with: Cell(" ", style: t.style(nil, bg))) }
            let value = scene.header.knobs?[instrument.name] ?? 0
            if k == 0 {
                if selected { put("▸", box.x + 2, t.style(p.accent, bg, .bold)) }
                put("●", c.name - 2, t.style(t.hue(instrument), bg))
                put(instrument.name, c.name, t.style(selected ? p.title : p.text, bg, selected ? .bold : []))
                Gauges.bipolar(x: c.knob, y: y, width: 11, value: value, span: 12, t, into: &screen)
                put(Table.gain(value).leftPadded(to: 5), c.value, t.style(t.gain(value), bg))
            }
            let character = range.name == instrument.character
            put(character ? "◆" : " ", c.range - 2, t.style(t.hue(instrument), bg))
            put(range.name, c.range, t.style(character ? p.text : p.text2, bg, character ? .bold : []))
            put(Self.hz(range.low) + "–" + Self.hz(range.high), c.hz, t.style(p.text2, bg))
            if let map = c.map {
                put(String(repeating: "┈", count: Self.mapWidth), map, t.style(p.grid, bg))
                for f in [32.0, 250, 2000, 16000] { put("┊", map + mapX(f), t.style(p.border, bg)) }
                let a = mapX(range.low), b = mapX(range.high)
                let hue = character || selected ? t.hue(instrument) : t.hue(instrument).mixed(toward: p.bg, 0.45)
                put(String(repeating: "━", count: b - a + 1), map + a, t.style(hue, bg))
            }
            if let bandsX = c.bands {
                let bands = Instruments.bands(touchedBy: range)
                let text = bands.count <= 4 ? bands.map { Table.shortLabels[$0] }.joined(separator: " ")
                    : "\(Table.shortLabels[bands[0]]) … \(Table.shortLabels[bands[bands.count - 1]])  (\(bands.count))"
                put(text, bandsX, t.style(selected ? p.text2 : p.text3, bg))
            }
        }
    }
}
