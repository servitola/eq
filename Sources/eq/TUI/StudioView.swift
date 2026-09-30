import EQTerm
import Foundation

/// The dense, graphic look: a boxed meter with a dBFS gutter and a gain axis, bars coloured by
/// height, peak ticks, the response curve in braille over boost and cut tints, gain chips, and a
/// column of gauges at 110 columns and wider. Below 60 columns or 12 rows, the compact rows.
struct StudioView {
    let scene: MeterScene
    let compact: Bool

    private let t: Theme
    private let p: Palette

    init(scene: MeterScene, compact: Bool) {
        self.scene = scene
        self.compact = compact
        t = scene.theme
        p = t.p
    }

    var geometry: MeterGeometry {
        let zones = scene.strip ? (scene.focus == nil ? Instruments.all.count : 1) : 0
        let tabs = scene.tabRows
        let size = Size(cols: scene.size.cols, rows: scene.size.rows - tabs)
        let g: MeterGeometry = compact ? .compact(size, zones: zones, focus: scene.focus != nil)
            : .studio(size, zones: zones, focus: scene.focus != nil, tabs: tabs, spectrum: scene.spectrum != nil)
        return g.lowered(by: tabs)
    }

    func draw(into screen: inout Screen) {
        let g = geometry
        StatusBar(scene: scene).studio(into: &screen, width: scene.size.cols)
        if scene.tabRows > 0 { TabRow.draw(scene, into: &screen) }
        if let box = g.box {
            let scale = scene.settings.scale
            Boxes.draw(box, into: &screen, t, border: scene.focus != nil ? p.borderHi : p.border, title: scale ? nil : "meter")
            if scale { titles(box, into: &screen) }
        }
        meter(g, into: &screen)
        if g.boxed, scene.settings.scale { scales(g, into: &screen) }
        numbers(g, into: &screen)
        if let y = g.bracketY, let focus = scene.focus {
            Zones.bracket(focus, y: y, centres: g.centres, table: g.table, scene: scene, into: &screen)
        }
        Zones.rows(y: g.zoneY, count: g.zoneRows, nameX: g.nameX, fullNames: g.fullNames && !g.boxed, centres: g.centres,
                   table: g.table, scene: scene, into: &screen)
        if let side = g.side { SideColumn(scene: scene).draw(side, into: &screen) }
        ShellRows(scene: scene).draw(messageY: g.messageY, keybarY: g.keybarY, x: g.boxed ? (g.gutter ?? 0) : g.x0,
                                     widen: !g.boxed && g.columns < scene.bands, into: &screen)
    }

    /// What each scale measures, over it and in its colour: the bars' at the left, the curve's at the right.
    private func titles(_ box: Rect, into screen: inout Screen) {
        let left = " level dBFS ", right = " EQ dB ", title = " meter "
        screen.ink(left, x: box.x + 1, y: box.y, t.style(scaleInk(-18), nil, .bold))
        screen.ink(right, x: box.right - 1 - right.count, y: box.y, t.style(p.curve, nil, .bold))
        let x = box.x + (box.width - title.count) / 2
        if x > box.x + left.count + 1, x + title.count < box.right - right.count - 1 {
            screen.ink(title, x: x, y: box.y, t.style(p.text2, nil, .bold))
        }
    }

    /// The level scale's labels: the bars' colour at that level, lifted a little toward the text so
    /// the dark end still reads.
    private func scaleInk(_ db: Double) -> Swatch { t.level(db).mixed(toward: p.text, 0.2) }

    /// The row a level's scale label and grid line sit on.
    private static func row(_ db: Double, rows: Int) -> Int {
        rows - 1 - min(Int((db - Watch.floorDB) / -Watch.floorDB * Double(rows)), rows - 1)
    }

    static let gridLevels: [Double] = [0, -12, -24, -36, -48]

    private struct Bar {
        var x, width: Int
        var level: Double
        var ghost: Double?
        var peak: Double?
        var outside: Bool
    }

    /// The third octaves when the frame has them and the panel room for them; else the ten bands.
    private func bars(_ g: MeterGeometry) -> [Bar] {
        let inside = scene.inside
        if let pitch = g.pitch, let spectrum = scene.spectrum {
            return spectrum.indices.map { j in
                let band = min(max(Int((Double(j - 2) / 3).rounded()), 0), scene.bands - 1)
                return Bar(x: g.plotX0 + j * pitch, width: pitch - 1, level: spectrum[j], ghost: nil,
                           peak: scene.spectrumPeaks?[j], outside: !inside.contains(band))
            }
        }
        return (0..<g.columns).map { i in
            Bar(x: g.barX(i), width: g.barWidth, level: scene.outLevels[i], ghost: scene.inLevels[i], peak: scene.peaks?[i],
                outside: !inside.contains(i))
        }
    }

    /// The boost or cut area `distance` rows from the curve: brightest at the line, the plain
    /// tint from the fourth row on, so the curve's edge glows. Row 0 is the curve's own cell.
    /// Sixteen colours and none paint no tint at all.
    private static func fills(_ p: Palette, boost: Bool) -> [Swatch] {
        let plain = boost ? p.boostFill : p.cutFill
        return [0.58, 0.68, 0.74, 0.79].map { plain.mixed(toward: boost ? p.boost : p.cut, 1 - $0 / 0.84).with(sgr: nil, []) } + [plain]
    }

    private func meter(_ g: MeterGeometry, into screen: inout Screen) {
        let rows = g.rows, top = g.top, x0 = g.plotX0, width = g.plotWidth
        guard rows > 0, width > 0 else { return }
        let leds = scene.settings.meterStyle == .leds
        let rowInk = (0..<rows).map { b -> (Swatch, Swatch) in
            let c = t.level(Watch.floorDB + (Double(b) + 0.5) / Double(rows) * -Watch.floorDB)
            return (c, t.faded(c))
        }
        var under = [Swatch?](repeating: nil, count: width * rows)
        var tint = [Swatch?](repeating: nil, count: width * rows)
        // The curve's own cells: lit in its side's colour where it has left the 0 dB line.
        var glow = [Swatch?](repeating: nil, count: width * rows)
        let curve = scene.settings.showsCurve && g.columns >= 2
        let zeroRow = Int((Double(rows * 4 - 1) / 2).rounded()) / 4
        if curve {
            scene.curve.update(scene.curveGains, rate: scene.frame.rate, centres: g.centres, x0: x0, width: width, rows: rows, thick: g.boxed)
            let ys = scene.curve.ys
            let lit = g.boxed && (t.depth == .truecolor || t.depth == .indexed)
            let boost = lit ? Self.fills(p, boost: true) : [p.boostFill], cut = lit ? Self.fills(p, boost: false) : [p.cutFill]
            for cx in 0..<width where cx * 2 + 1 < ys.count {
                let row = (ys[cx * 2] + ys[cx * 2 + 1]) / 2 / 4
                guard row != zeroRow else { continue }
                let fills = row < zeroRow ? boost : cut
                for r in min(row, zeroRow)...max(row, zeroRow) {
                    let fill = fills[min(abs(r - row), fills.count - 1)]
                    if r == row { glow[r * width + cx] = lit ? fill : nil } else { tint[r * width + cx] = fill }
                }
            }
        }
        let grid = g.boxed && scene.settings.scale ? Set(Self.gridLevels.map { Self.row($0, rows: rows) }) : []
        let zeroInk = g.boxed ? p.curve.mixed(toward: p.bg, 0.72).with(sgr: nil, .dim) : p.grid
        for r in 0..<rows {
            let line = curve && r == zeroRow ? zeroInk : (grid.contains(r) ? p.grid : nil)
            for cx in 0..<width {
                let bg = tint[r * width + cx]
                if let line {
                    screen.set(x0 + cx, top + r, Cell("┈", style: t.style(line, bg)))
                } else if let bg {
                    screen.set(x0 + cx, top + r, Cell(" ", style: t.style(nil, bg)))
                }
            }
        }
        for bar in bars(g) {
            let outH = (bar.level - Watch.floorDB) / -Watch.floorDB * Double(rows)
            let inH = bar.ghost.map { ($0 - Watch.floorDB) / -Watch.floorDB * Double(rows) } ?? 0
            let peak = bar.peak.map { min(Int(($0 - Watch.floorDB) / -Watch.floorDB * Double(rows)), rows - 1) }
            let full = Int(outH), fraction = outH - Double(full)
            for b in 0..<rows {
                let r = rows - 1 - b, y = top + r
                let ink = bar.outside ? rowInk[b].1 : rowInk[b].0
                for dx in 0..<bar.width {
                    let col = bar.x - x0 + dx
                    guard col >= 0, col < width else { continue }
                    let bg = tint[r * width + col]
                    var cell: Cell?
                    if leds {
                        let db = Watch.floorDB + (Double(b) + 0.5) / Double(rows) * -Watch.floorDB
                        let lit = b < Int(outH.rounded()) || b == peak
                        var c = t.led(db, lit: lit)
                        if bar.outside, lit { c = c.mixed(toward: p.bg, 0.6).with(sgr: nil, .dim) }
                        cell = Cell("▆", style: t.style(c, bg))
                        if lit { under[r * width + col] = c }
                    } else if b < full {
                        cell = Cell(" ", style: t.style(nil, ink, solid: true))
                        under[r * width + col] = ink
                    } else if b == full, fraction > 0.12 {
                        cell = Cell(Watch.partials[min(Int(fraction * 8), 7)], style: t.style(ink, bg))
                        under[r * width + col] = ink
                    } else if let peak, b == peak, peak >= full {
                        var tick = t.level(Watch.floorDB + (Double(b) + 0.5) / Double(rows) * -Watch.floorDB)
                            .mixed(toward: Swatch(0xFFFFFF), 0.35)
                        if bar.outside { tick = t.faded(tick) }
                        cell = Cell("▔", style: t.style(tick, bg))
                    } else if Double(b) < inH {
                        cell = Cell("░", style: t.style(p.ghost, bg))
                    }
                    if let cell { screen.set(x0 + col, y, cell) }
                }
            }
        }
        guard curve else { return }
        for (col, column) in scene.curve.glyphs where col >= 0 && col < width {
            for (r, glyph) in column where r >= 0 && r < rows {
                let below = under[r * width + col]
                let bg = below ?? glow[r * width + col] ?? tint[r * width + col]
                screen.set(x0 + col, top + r, Cell(String(glyph), style: t.style(p.curve, bg, g.boxed ? .bold : [], solid: below != nil)))
            }
        }
        guard g.boxed else { return }
        CurveNodes.draw(scene, centres: g.centres, x0: x0, top: top, width: width, rows: rows, into: &screen) { col, r in
            (under[r * width + col], glow[r * width + col] ?? tint[r * width + col])
        }
    }

    private func scales(_ g: MeterGeometry, into screen: inout Screen) {
        let rows = g.rows
        if let gx = g.gutter {
            for db in [0, -6, -12, -24, -36, -48, -60] {
                let y = g.top + Self.row(Double(db), rows: rows)
                screen.ink(String(format: "%3d", db), x: gx, y: y, t.style(scaleInk(Double(db))))
                screen.ink("┤", x: gx + 4, y: y, t.style(p.border))
            }
        }
        if let ax = g.axis {
            let faint = p.curve.mixed(toward: p.bg, 0.4).with(sgr: nil, [])
            for gain in [12, 6, 0, -6, -12] {
                let y = g.top + Int((Double(12 - gain) / 24 * Double(rows - 1)).rounded())
                screen.ink("├", x: ax, y: y, t.style(p.border))
                screen.ink(gain == 0 ? " 0" : String(format: "%+d", gain), x: ax + 1, y: y, t.style(gain == 0 ? p.curve : faint, nil, gain == 0 ? .bold : []))
            }
        }
    }


    private func numbers(_ g: MeterGeometry, into screen: inout Screen) {
        let gains = scene.gains, out = scene.outLevels
        let inside = scene.inside
        let flashing = scene.flash.flatMap { $0.left > MeterScene.flashBlendFrames ? $0.band : nil }
        for i in 0..<g.columns {
            let outside = !inside.contains(i)
            let silent = out[i] <= Watch.floorDB + 0.5
            let live = silent ? "·" : String(Int(out[i].rounded()))
            let liveInk = silent ? p.text3 : (outside ? t.faded(t.level(out[i])) : t.level(out[i]))
            let bold: Style.Attributes = scene.focus != nil && !outside && !silent ? .bold : []
            put(live, band: i, y: g.liveY, g, t.style(liveInk, nil, bold), into: &screen)
            let label = (g.shortLabels ? Table.shortLabels : Config.bandLabels)[i]
            put(label, band: i, y: g.liveY + 1, g, t.style(outside ? p.text3 : p.text2, nil, flashing == i ? .bold : []), into: &screen)
            gainChip(i, g, gain: gains[i], outside: outside, into: &screen)
        }
    }

    /// Centred on the bar in the panel; right-aligned in its cell in the compact rows.
    private func put(_ text: String, band: Int, y: Int, _ g: MeterGeometry, _ style: Style, into screen: inout Screen) {
        let w = TerminalText.width(text)
        let x = g.boxed ? g.centre(band) - w / 2 : g.x0 + band * g.cell + g.cell - w
        screen.ink(text, x: x, y: y, style)
    }

    private func gainChip(_ i: Int, _ g: MeterGeometry, gain: Double, outside: Bool, into screen: inout Screen) {
        let text = g.cell >= 6 || g.boxed ? MeterScene.gainText(gain) : Table.wholeGain(gain)
        let y = g.liveY + 2
        let ink = t.gain(gain)
        guard !outside else {
            put(text, band: i, y: y, g, t.style(p.text3), into: &screen)
            return
        }
        let fill: Swatch? = gain == 0 ? nil : (gain > 0 ? p.boostFill : p.cutFill)
        var style = t.style(ink, fill)
        if let flash = scene.flash, flash.band == i {
            if flash.left > MeterScene.flashBlendFrames {
                style = t.style(p.onChip, ink, .bold, solid: true)
            } else if t.depth == .truecolor, let fill {
                let step = Double((flash.left + 2) / 3) / 4
                style = t.style(ink.mixed(toward: p.onChip, step), fill.mixed(toward: ink, step))
            }
        }
        guard g.boxed || g.cell >= 6 else {
            put(text, band: i, y: y, g, style, into: &screen)
            return
        }
        let w = TerminalText.width(text) + 2
        let x = g.boxed ? g.centre(i) - (w - 2) / 2 - 1 : g.x0 + i * g.cell + g.cell - w + 1
        screen.ink(" " + text + " ", x: x, y: y, style, limit: g.boxed ? nil : w - 1)
    }
}

/// Rounded boxes: panels, overlays, the side column's gauges.
enum Boxes {
    static func draw(_ r: Rect, into screen: inout Screen, _ t: Theme, border: Swatch, title: String? = nil, right: String? = nil,
                     titleInk: Swatch? = nil, fill: Swatch? = nil) {
        guard r.width >= 2, r.height >= 2 else { return }
        if let fill { screen.fill(r, with: Cell(" ", style: t.style(nil, fill))) }
        let b = t.style(border, fill)
        screen.ink("╭" + String(repeating: "─", count: r.width - 2) + "╮", x: r.x, y: r.y, b)
        for y in (r.y + 1)..<(r.bottom - 1) {
            screen.ink("│", x: r.x, y: y, b)
            screen.ink("│", x: r.right - 1, y: y, b)
        }
        screen.ink("╰" + String(repeating: "─", count: r.width - 2) + "╯", x: r.x, y: r.bottom - 1, b)
        var used = 0
        if let title, r.width >= TerminalText.width(title) + 6 {
            used = screen.ink(" " + title + " ", x: r.x + 2, y: r.y, t.style(titleInk ?? t.p.text2, fill, .bold)) + 2
        }
        if let right, r.width - used >= TerminalText.width(right) + 7 {
            screen.ink(" " + right + " ", x: r.right - 3 - TerminalText.width(right), y: r.y, t.style(t.p.text3, fill))
        }
    }
}

/// The focus bracket and the instrument strip, on the meter's frequency axis, in each
/// instrument's hue.
enum Zones {
    static func bracket(_ focus: Instrument, y: Int, centres: [Int], table: ClosedRange<Int>, scene: MeterScene, into screen: inout Screen) {
        let t = scene.theme
        let hue = t.hue(focus)
        let dim = hue.mixed(toward: t.p.bg, 0.35).with(sgr: nil, .dim)
        for segment in Strip.segments(focus, centres: centres, columns: table) {
            let character = segment.name == focus.character
            for (i, cell) in Strip.labelled(segment, stroke: "─", ends: ("┌", "┐")).enumerated() {
                let style: Style
                switch cell.part {
                case .gap: continue
                case .stroke: style = t.style(character ? hue : dim)
                case .name: style = t.style(character ? hue : dim, nil, character ? .bold : [])
                }
                screen.ink(String(cell.glyph), x: segment.lo + i, y: y, style)
            }
        }
    }

    static func rows(y top: Int, count: Int, nameX: Int, fullNames: Bool, centres: [Int], table: ClosedRange<Int>,
                     scene: MeterScene, into screen: inout Screen) {
        guard scene.strip, count > 0 else { return }
        let t = scene.theme
        let list = scene.focus.map { [$0] } ?? Instruments.all
        let out = scene.outLevels
        for (k, instrument) in list.prefix(count).enumerated() {
            let y = top + k
            let loud = instrument.bands.filter { $0 < centres.count }.map { out[$0] }.max() ?? Watch.floorDB
            let focused = scene.focus != nil
            let hue = loud > -20 || focused ? t.hue(instrument) : t.hue(instrument).mixed(toward: t.p.bg, 0.55)
            let label = fullNames ? instrument.name : instrument.short
            let firstFree = nameX + TerminalText.width(label) + 1
            screen.ink(label, x: nameX, y: y, t.style(hue, nil, focused ? .bold : []))
            for segment in Strip.segments(instrument, centres: centres, columns: table) {
                let character = segment.name == instrument.character
                for (i, cell) in Strip.labelled(segment, stroke: "━").enumerated() where segment.lo + i >= firstFree {
                    let style: Style
                    switch cell.part {
                    case .gap: continue
                    case .stroke: style = t.style(hue)
                    case .name: style = focused && character ? t.style(t.hue(instrument), nil, .bold) : t.style(t.p.text3)
                    }
                    screen.ink(String(cell.glyph), x: segment.lo + i, y: y, style)
                }
            }
        }
    }
}

/// A dot on the curve at each band's centre in its gain's colour, and on the band just edited a
/// ring in the accent with its gain on a chip beside it. `ground` gives a cell's bar colour, if a
/// bar is under it, and its background otherwise.
enum CurveNodes {
    static func draw(_ scene: MeterScene, centres: [Int], x0: Int, top: Int, width: Int, rows: Int, into screen: inout Screen,
                     ground: (_ col: Int, _ row: Int) -> (bar: Swatch?, bg: Swatch?)) {
        let t = scene.theme, p = t.p
        let ys = scene.curve.ys, inside = scene.inside
        let edited = scene.flash?.band
        for (band, centre) in centres.enumerated() {
            let col = centre - x0
            guard col >= 0, col < width, col * 2 + 1 < ys.count else { continue }
            let r = min((ys[col * 2] + ys[col * 2 + 1]) / 2 / 4, rows - 1)
            let gain = scene.gains[band]
            var ink = band == edited ? p.accent : (gain == 0 ? p.curve : t.gain(gain))
            let (bar, bg) = ground(col, r)
            // On a bar the gain's colour would be the bar's own: the curve's shows instead.
            if bar != nil, band != edited { ink = p.curve }
            if !inside.contains(band) { ink = t.faded(ink) }
            screen.set(x0 + col, top + r, Cell(band == edited ? "◉" : "●", style: t.style(ink, bar ?? bg, .bold, solid: bar != nil)))
            guard band == edited else { continue }
            let text = " " + MeterScene.gainText(gain) + " "
            screen.ink(text, x: x0 + col - text.count / 2, y: top + (r > 0 ? r - 1 : r + 1), t.style(p.onChip, p.accent, .bold, solid: true))
        }
    }
}
