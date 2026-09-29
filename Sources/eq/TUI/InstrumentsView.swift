import EQTerm
import Foundation

/// `eq zones` and `eq boost` as one view: per instrument a hue dot, the knob as a centre-zero
/// gauge, a live mini-meter of its bands, `◆` on the character range, each range in Hz, where it
/// sits on a 20 Hz–20 kHz map and the bands it touches; under the table a row of the ten bands now.
struct InstrumentsView {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette
    private var console: Bool { scene.settings.look == .console }

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    static var rowCount: Int { Instruments.all.reduce(0) { $0 + $1.ranges.count } }
    static let mapWidth = 30
    static let meterWidth = 8
    static let nowHeight = 4

    struct Layout {
        var table: Rect
        var now: Rect?
    }

    static func layout(_ size: Size) -> Layout {
        let top = 1 + (size.rows >= TabRow.minRows ? 1 : 0)
        let bottom = size.rows - 2
        let available = max(bottom - top, 0)
        let full = rowCount + 3
        let width = max(size.cols - 2, 0)
        if available >= full + nowHeight {
            return Layout(table: Rect(x: 1, y: top, width: width, height: full),
                          now: Rect(x: 1, y: bottom - nowHeight, width: width, height: nowHeight))
        }
        if available >= 8 + nowHeight {
            return Layout(table: Rect(x: 1, y: top, width: width, height: available - nowHeight),
                          now: Rect(x: 1, y: bottom - nowHeight, width: width, height: nowHeight))
        }
        return Layout(table: Rect(x: 1, y: top, width: width, height: available), now: nil)
    }

    func draw(into screen: inout Screen) {
        let size = scene.size
        if console { screen.fill(screen.area, with: Cell(" ", style: t.style(nil, p.surface))) }
        if console { StatusBar(scene: scene).console(into: &screen, width: size.cols) } else { StatusBar(scene: scene).studio(into: &screen, width: size.cols) }
        if scene.tabRows > 0 { TabRow.draw(scene, into: &screen) }
        let l = Self.layout(size)
        if l.table.height >= 3, l.table.width >= 20 {
            let ranges = Self.rowCount
            Boxes.draw(l.table, into: &screen, t, border: p.border, title: console ? "INSTRUMENTS" : "instruments",
                       right: "\(Instruments.all.count) instruments · \(ranges) ranges")
            table(l.table, into: &screen)
        }
        if let now = l.now { self.now(now, into: &screen) }
        ShellRows(scene: scene).draw(messageY: size.rows >= 10 ? size.rows - 2 : nil, keybarY: size.rows - 1, x: 1, widen: false,
                                     into: &screen)
    }

    private struct Columns {
        var name, knob, value, level, range, hz: Int
        var map: Int?
        var bands: Int?
    }

    private func columns(_ box: Rect) -> Columns {
        let x = box.x
        var c = Columns(name: x + 6, knob: x + 15, value: x + 27, level: x + 34, range: x + 45, hz: x + 59)
        let room = box.right - 2
        if room - (c.hz + 10 + Self.mapWidth + 2) >= 14 {
            c.map = c.hz + 10
            c.bands = c.hz + 10 + Self.mapWidth + 2
        } else if room - (c.hz + 10) >= 12 {
            c.bands = c.hz + 10
        }
        return c
    }

    static func hz(_ f: Double) -> String {
        f >= 1000 ? String(format: "%gk", f / 1000) : String(Int(f))
    }

    /// The first row shown, so that the selected instrument's rows are all in sight.
    static func offset(selected: Int, visible: Int) -> Int {
        var first = 0
        for instrument in Instruments.all.prefix(selected) { first += instrument.ranges.count }
        let last = first + Instruments.all[min(selected, Instruments.all.count - 1)].ranges.count - 1
        return last < visible ? 0 : min(first, last - visible + 1)
    }

    private func table(_ box: Rect, into screen: inout Screen) {
        let c = columns(box)
        let right = box.right - 1
        let visible = max(box.height - 3, 0)
        var rows: [(index: Int, instrument: Instrument, k: Int, range: HzRange)] = []
        for (index, instrument) in Instruments.all.enumerated() {
            for (k, range) in instrument.ranges.enumerated() { rows.append((index, instrument, k, range)) }
        }
        let l0 = log2(20.0), l1 = log2(20000.0)
        func mapX(_ f: Double) -> Int { Int(((log2(f) - l0) / (l1 - l0) * Double(Self.mapWidth - 1)).rounded()) }
        func put(_ text: String, _ x: Int, _ y: Int, _ style: Style) {
            guard x < right else { return }
            screen.ink(text, x: x, y: y, style, limit: right - x)
        }
        let hy = box.y + 1
        let label: (String) -> String = { console ? $0.uppercased() : $0 }
        for (x, text) in [(c.name, "instrument"), (c.value, " knob"), (c.level, "level"), (c.range, "range"), (c.hz, "Hz")] {
            put(label(text), x, hy, t.style(p.text3))
        }
        if let bands = c.bands { put(label("bands"), bands, hy, t.style(p.text3)) }
        if let map = c.map {
            for (f, text) in [(32.0, "32"), (250, "250"), (2000, "2k"), (16000, "16k")] {
                put(text, map + mapX(f) - text.count / 2, hy, t.style(p.text3))
            }
        }
        let start = Self.offset(selected: scene.selected, visible: visible)
        for (i, row) in rows.dropFirst(start).prefix(visible).enumerated() {
            let y = hy + 1 + i
            let instrument = row.instrument
            let selected = row.index == scene.selected
            let bg: Swatch? = selected ? p.sel : nil
            if selected { screen.fill(Rect(x: box.x + 1, y: y, width: box.width - 2, height: 1), with: Cell(" ", style: t.style(nil, p.sel))) }
            let value = scene.header.knobs?[instrument.name] ?? 0
            if row.k == 0 {
                if selected { put("▸", box.x + 2, y, t.style(p.accent, bg, .bold)) }
                put(instrument == scene.focus ? "◉" : "●", c.name - 2, y, t.style(t.hue(instrument), bg))
                put(instrument.name, c.name, y, t.style(selected ? p.title : p.text, bg, selected ? .bold : []))
                Gauges.bipolar(x: c.knob, y: y, width: 11, value: value, span: 12, t, into: &screen)
                put(MeterScene.gainText(value).leftPadded(to: 5), c.value, y, t.style(t.gain(value), bg))
                level(instrument, x: c.level, y: y, into: &screen)
            }
            let character = row.range.name == instrument.character
            put(character ? "◆" : " ", c.range - 2, y, t.style(t.hue(instrument), bg))
            put(row.range.name, c.range, y, t.style(character ? p.text : p.text2, bg, character ? .bold : []))
            put(Self.hz(row.range.low) + "–" + Self.hz(row.range.high), c.hz, y, t.style(p.text2, bg))
            if let map = c.map {
                put(String(repeating: "┈", count: Self.mapWidth), map, y, t.style(p.grid, bg))
                for f in [32.0, 250, 2000, 16000] { put("┊", map + mapX(f), y, t.style(p.border, bg)) }
                let a = mapX(row.range.low), b = mapX(row.range.high)
                let hue = character || selected ? t.hue(instrument) : t.hue(instrument).mixed(toward: p.bg, 0.45)
                put(String(repeating: "━", count: b - a + 1), map + a, y, t.style(hue, bg))
            }
            if let bandsX = c.bands {
                let bands = Instruments.bands(touchedBy: row.range)
                let text = bands.count <= 4 ? bands.map { Table.shortLabels[$0] }.joined(separator: " ")
                    : "\(Table.shortLabels[bands[0]]) … \(Table.shortLabels[bands[bands.count - 1]])  (\(bands.count))"
                put(text, bandsX, y, t.style(selected ? p.text2 : p.text3, bg))
            }
        }
    }

    /// The loudest of the instrument's bands, as eight cells: painted by height in studio, LED
    /// segments in console.
    private func level(_ instrument: Instrument, x: Int, y: Int, into screen: inout Screen) {
        let loudest = instrument.bands.map { scene.outLevels[$0] }.max() ?? Watch.floorDB
        let n = Self.meterWidth
        let lit = Int(((loudest - Watch.floorDB) / -Watch.floorDB * Double(n)).rounded())
        for i in 0..<n {
            let db = Watch.floorDB + (Double(i) + 0.5) / Double(n) * -Watch.floorDB
            if console {
                screen.ink("▆", x: x + i, y: y, t.style(t.led(db, lit: i < lit)))
            } else if i < lit {
                screen.set(x + i, y, Cell(" ", style: t.style(nil, t.level(db), solid: true)))
            } else {
                screen.ink("·", x: x + i, y: y, t.style(p.grid))
            }
        }
    }

    /// The ten bands as they sound now, one row of eighth blocks, labels under.
    private func now(_ box: Rect, into screen: inout Screen) {
        Boxes.draw(box, into: &screen, t, border: p.border, title: console ? "NOW" : "now")
        let bands = scene.bands
        let cell = max((box.width - 4) / bands, 1)
        let barWidth = min(5, max(cell - 2, 1))
        for i in 0..<bands {
            let centre = box.x + 2 + i * cell + cell / 2
            let db = scene.outLevels[i]
            let h = (db - Watch.floorDB) / -Watch.floorDB * 8
            let glyph = console ? "▆" : Watch.partials[min(max(Int(h) - 1, 0), 7)]
            let ink = console ? t.led(db, lit: db > Watch.floorDB + 0.5) : t.level(db)
            screen.ink(String(repeating: glyph, count: barWidth), x: centre - barWidth / 2, y: box.y + 1, t.style(ink))
            let label = (cell >= 6 ? Config.bandLabels : Table.shortLabels)[i]
            screen.ink(label, x: centre - TerminalText.width(label) / 2, y: box.y + 2, t.style(p.text3), limit: cell)
        }
    }
}
