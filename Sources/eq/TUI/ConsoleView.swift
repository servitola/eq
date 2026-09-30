import EQTerm
import Foundation

/// The mixing desk: one channel strip per band with a tape label, an LED ladder whose unlit
/// segments stay faintly lit, an amber readout and a fader; lamps in the header rail; and at 110
/// columns a master section with a backlit gain-reduction window.
struct ConsoleView {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    struct Layout {
        var stripWidth: Int
        var ledWidth: Int
        var x0 = 5
        var top = 1
        var bracket: Int
        var ledRows: Int
        var faderRows: Int
        var zoneRows: Int
        var master: Int

        var tapeY: Int { top + bracket }
        var ledY: Int { tapeY + 1 }
        var lcdY: Int { ledY + ledRows }
        var zoneY: Int { lcdY + 1 }
        var faderY: Int { zoneY + zoneRows }
        var gainY: Int { faderY + faderRows }

        func stripX(_ band: Int) -> Int { x0 + band * stripWidth }
        func ledX(_ band: Int) -> Int { stripX(band) + (stripWidth - 1 - ledWidth) / 2 }
        var centres: [Int] { (0..<10).map { ledX($0) + ledWidth / 2 } }
        var table: ClosedRange<Int> { x0...(x0 + stripWidth * 10 - 2) }
    }

    /// nil when the desk does not fit; the studio's compact rows draw instead.
    static func layout(_ full: Size, zones: Int, focus: Bool, tabs: Int = 0) -> Layout? {
        let size = Size(cols: full.cols, rows: full.rows - tabs)
        let master = size.cols >= 110 ? 30 : 0
        let stripWidth = min(8, (size.cols - master - 5) / 10)
        guard stripWidth >= 5 else { return nil }
        let bracket = focus ? 1 : 0
        let zoneRows = zones == 0 ? 0 : min(zones, max(full.rows - 26, 1))
        var faderRows = size.rows >= 30 ? 9 : 5
        func leds() -> Int { size.rows - 1 - 1 - 1 - faderRows - 1 - zoneRows - 2 - bracket - 1 }
        if leds() < 6 { faderRows = 3 }
        guard leds() >= 3 else { return nil }
        return Layout(stripWidth: stripWidth, ledWidth: stripWidth >= 7 ? 3 : 2, top: 1 + tabs, bracket: bracket, ledRows: leds(),
                      faderRows: faderRows, zoneRows: zoneRows, master: master)
    }

    func draw(into screen: inout Screen) {
        let zones = scene.strip ? (scene.focus == nil ? Instruments.all.count : 1) : 0
        guard let l = Self.layout(scene.size, zones: zones, focus: scene.focus != nil, tabs: scene.tabRows) else {
            StudioView(scene: scene, compact: true).draw(into: &screen)
            return
        }
        let size = scene.size
        screen.fill(screen.area, with: Cell(" ", style: t.style(nil, p.surface)))
        StatusBar(scene: scene).console(into: &screen, width: size.cols)
        if scene.tabRows > 0 { TabRow.draw(scene, into: &screen) }
        if let focus = scene.focus {
            Zones.bracket(focus, y: l.top, centres: l.centres, table: l.table, scene: scene, into: &screen)
        }
        if scene.settings.scale {
            screen.ink("dBFS", x: 1, y: l.tapeY, t.style(p.text3))
            for db in [0, -6, -18, -30, -42, -60] {
                let b = min(Int((Double(db) - Watch.floorDB) / -Watch.floorDB * Double(l.ledRows)), l.ledRows - 1)
                screen.ink(String(format: "%3d", db), x: 1, y: l.ledY + l.ledRows - 1 - b, t.style(t.led(Double(db) - 0.5, lit: true)))
            }
        }
        for band in 0..<10 { strip(band, l, into: &screen) }
        if scene.settings.showsCurve { curve(l, into: &screen) }
        Zones.rows(y: l.zoneY, count: l.zoneRows, nameX: 1, fullNames: false, centres: l.centres, table: l.table, scene: scene,
                   into: &screen)
        if l.master > 0 { master(Rect(x: size.cols - l.master, y: l.top, width: l.master - 1, height: size.rows - l.top - 2), into: &screen) }
        ShellRows(scene: scene).draw(messageY: size.rows - 2, keybarY: size.rows - 1, x: 1, widen: false, into: &screen)
    }

    private func strip(_ band: Int, _ l: Layout, into screen: inout Screen) {
        let x = l.stripX(band)
        let outside = !scene.inside.contains(band)
        let level = scene.outLevels[band]
        let gain = scene.gains[band]
        for y in l.tapeY...l.gainY { screen.ink("│", x: x + l.stripWidth - 1, y: y, t.style(p.groove)) }
        let short = Table.shortLabels[band]
        var label = " " + short + (l.stripWidth >= 8 ? String(" Hz".prefix(max(l.stripWidth - 2 - short.count, 0))) : "") + " "
        label = String(label.prefix(l.stripWidth - 1))
        let pad = l.stripWidth - 1 - label.count
        label = String(repeating: " ", count: pad / 2) + label + String(repeating: " ", count: pad - pad / 2)
        screen.ink(label, x: x, y: l.tapeY, t.style(p.tapeFg, outside ? p.tapeBg.mixed(toward: p.surface, 0.55) : p.tapeBg, .bold, solid: true))

        // Three LED columns are the band's three third octaves, when the frame has them.
        let thirds = l.ledWidth == 3 ? scene.spectrum.map { s in (0..<3).map { (s[3 * band + 1 + $0], scene.spectrumPeaks?[3 * band + 1 + $0]) } } : nil
        let ladders = thirds ?? [(level, scene.peaks?[band])]
        let ladderWidth = thirds == nil ? l.ledWidth : 1
        let bars = scene.settings.meterStyle == .bars
        for (k, ladder) in ladders.enumerated() {
            let x = l.ledX(band) + k * ladderWidth
            let litH = (ladder.0 - Watch.floorDB) / -Watch.floorDB * Double(l.ledRows)
            let peak = ladder.1.map { min(Int(($0 - Watch.floorDB) / -Watch.floorDB * Double(l.ledRows)), l.ledRows - 1) }
            for b in 0..<l.ledRows {
                let db = Watch.floorDB + (Double(b) + 0.5) / Double(l.ledRows) * -Watch.floorDB
                let y = l.ledY + l.ledRows - 1 - b
                let on = b < Int(litH.rounded()) || b == peak
                let text = String(repeating: bars ? " " : "▆", count: ladderWidth)
                if bars {
                    guard on else { continue }
                    let c = outside ? t.faded(t.level(db)) : t.level(db)
                    screen.ink(b == peak && b >= Int(litH.rounded()) ? String(repeating: "▔", count: ladderWidth) : text, x: x, y: y,
                               b == peak && b >= Int(litH.rounded()) ? t.style(c) : t.style(nil, c, solid: true))
                    continue
                }
                var c = t.led(db, lit: on && !outside)
                if on, outside { c = t.led(db, lit: true).mixed(toward: p.surface, 0.6).with(sgr: nil, .dim) }
                screen.ink(text, x: x, y: y, t.style(c))
            }
        }
        let readout = level > Watch.floorDB ? String(format: "%5.1f", level) : "  -∞ "
        screen.ink(readout, x: x + (l.stripWidth - 1 - 5) / 2, y: l.lcdY, t.style(outside ? p.text3 : p.lcdFg, p.lcdBg))

        let centre = x + (l.stripWidth - 1) / 2
        let rows = l.faderRows
        for k in 0..<rows {
            let value = 12 - Double(k) * 24 / Double(rows - 1)
            let y = l.faderY + k
            if abs(value) < 1e-6, l.stripWidth >= 7 {
                screen.ink("╶─", x: centre - 2, y: y, t.style(p.text3))
                screen.ink("─╴", x: centre + 1, y: y, t.style(p.text3))
            }
            let filled = (gain > 0 && value >= 0 && value <= gain) || (gain < 0 && value <= 0 && value >= gain)
            screen.ink(filled ? "┃" : "│", x: centre, y: y, t.style(filled ? t.gain(gain) : p.track))
        }
        let capRow = l.faderY + Int(((12 - gain) / 24 * Double(rows - 1)).rounded())
        let flashing = scene.flash.map { $0.band == band && $0.left > MeterScene.flashBlendFrames } ?? false
        let cap = l.stripWidth >= 7 ? "▐███▌" : "▐█▌"
        screen.ink(cap, x: centre - cap.count / 2, y: capRow, t.style(flashing ? p.capSel : (outside ? p.track : p.cap)))
        let text = MeterScene.gainText(gain)
        screen.ink(text, x: centre - text.count / 2, y: l.gainY, t.style(outside ? p.text3 : t.gain(gain), nil, .bold))
    }

    private func curve(_ l: Layout, into screen: inout Screen) {
        let width = l.table.count
        scene.curve.update(scene.curveGains, rate: scene.frame.rate, centres: l.centres, x0: l.x0, width: width, rows: l.ledRows, thick: true)
        for (col, column) in scene.curve.glyphs where col >= 0 && col < width {
            for (r, glyph) in column where r >= 0 && r < l.ledRows {
                screen.ink(String(glyph), x: l.x0 + col, y: l.ledY + r, t.style(p.curve, nil, .bold))
            }
        }
        CurveNodes.draw(scene, centres: l.centres, x0: l.x0, top: l.ledY, width: width, rows: l.ledRows, into: &screen) { col, r in
            (nil, p.surface)
        }
    }


    private static let arrows = Array("↙←↖↑↗→↘")

    private func master(_ r: Rect, into screen: inout Screen) {
        Boxes.draw(r, into: &screen, t, border: p.border, title: "MASTER", fill: p.surface)
        let ix = r.x + 2, iw = r.width - 4
        var y = r.y + 2
        let bottom = r.bottom - 1
        let reduction = scene.frame.comp.flatMap { $0.isFinite ? $0 : nil } ?? 0
        if y + 4 <= bottom {
            screen.fill(Rect(x: ix, y: y, width: iw, height: 4), with: Cell(" ", style: t.style(nil, p.windowBg, solid: true)))
            let scale = [20, 10, 6, 3, 1, 0]
            for (j, v) in scale.enumerated() {
                screen.ink(String(v), x: ix + 1 + Int((Double(j) * Double(iw - 3) / Double(scale.count - 1)).rounded()), y: y,
                           t.style(p.windowFg))
            }
            screen.ink("╷" + String(repeating: "┈", count: max(iw - 4, 0)) + "╷", x: ix + 1, y: y + 1, t.style(p.windowFg))
            let at = ix + 1 + Int((pow(1 - min(abs(reduction), 20) / 20, 2) * Double(iw - 3)).rounded())
            screen.ink("┃", x: at, y: y + 1, t.style(p.needle, nil, .bold))
            screen.ink("┃", x: at, y: y + 2, t.style(p.needle, nil, .bold))
            screen.ink("GR", x: ix + 1, y: y + 3, t.style(p.windowFg, nil, .bold))
            screen.ink(String(format: "%5.1f", reduction == 0 ? 0 : reduction), x: ix + iw - 6, y: y + 3, t.style(p.needle, nil, .bold))
            y += 5
        }
        if y < bottom {
            screen.ink("COMP", x: ix, y: y, t.style(p.text3))
            let mode = scene.header.dynamics?.comp?.rawValue ?? "off"
            for (j, m) in ["off", "gentle", "night"].enumerated() {
                let on = m == mode
                let lx = ix + [5, 10, 18][j]
                screen.ink("●", x: lx, y: y, t.style(on ? p.accent : p.lampOff))
                screen.ink(m, x: lx + 1, y: y, t.style(on ? p.title : p.text3, nil, on ? .bold : []))
            }
            y += 2
        }
        if y < bottom {
            screen.ink("LIMIT", x: ix, y: y, t.style(p.text3))
            screen.ink("●", x: ix + 6, y: y, t.style(scene.limiting ? p.danger : p.lampOff))
            screen.ink("PEAK", x: ix + 12, y: y, t.style(p.text3))
            let peak = scene.frame.peak.isFinite ? scene.frame.peak : Watch.floorDB
            screen.ink(String(format: " %5.1f ", peak), x: ix + 17, y: y, t.style(p.lcdFg, p.lcdBg))
            y += 2
        }
        if y < bottom {
            screen.ink("PREAMP", x: ix, y: y, t.style(p.text3))
            let tw = iw - 14
            let preamp = scene.frame.preamp.isFinite ? scene.frame.preamp : 0
            let pos = Int(((min(max(preamp, -12), 12) + 12) / 24 * Double(tw - 1)).rounded())
            screen.ink(String(repeating: "─", count: tw), x: ix + 7, y: y, t.style(p.track))
            screen.ink("┼", x: ix + 7 + tw / 2, y: y, t.style(p.text3))
            screen.ink("█", x: ix + 7 + pos, y: y, t.style(p.cap))
            screen.ink(MeterScene.gainText(preamp).leftPadded(to: 5), x: ix + 8 + tw, y: y, t.style(t.gain(preamp), nil, .bold))
            y += 2
        }
        let preference = scene.header.preference ?? Preference()
        if y + 1 < bottom {
            knob(x: ix, y: y, label: "BASS", value: preference.bass, span: 6, into: &screen)
            knob(x: ix + 9, y: y, label: "TREB", value: preference.treble, span: 6, into: &screen)
            knob(x: ix + 18, y: y, label: "TILT", value: preference.tilt, span: 6, into: &screen)
            y += 3
        }
        if y < bottom {
            screen.ink("INSTRUMENT KNOBS", x: ix, y: y, t.style(p.text3))
            y += 1
        }
        var last = y
        for (j, instrument) in Instruments.all.enumerated() {
            let ky = y + (j / 3) * 3
            guard ky + 1 < bottom else { break }
            knob(x: ix + (j % 3) * 9, y: ky, label: instrument.short.uppercased(), value: scene.header.knobs?[instrument.name] ?? 0,
                 span: 12, hue: t.hue(instrument), selected: scene.focus == instrument, into: &screen)
            last = ky + 3
        }
        y = last
        if y < bottom, let colour = scene.header.dynamics?.color {
            screen.ink("COLOUR", x: ix, y: y, t.style(p.text3))
            screen.ink(colour.kind.rawValue.uppercased(), x: ix + 7, y: y, t.style(p.accent, nil, .bold))
            let lit = Int((min(max(colour.amount, 0), 1) * 10).rounded())
            screen.ink(String(repeating: "▆", count: lit), x: ix + 13, y: y, t.style(p.accent))
            screen.ink(String(repeating: "▆", count: 10 - lit), x: ix + 13 + lit, y: y, t.style(p.lampOff))
        }
    }

    /// A knob cap whose arrow points at the value, seven positions from −span to +span.
    private func knob(x: Int, y: Int, label: String, value: Double, span: Double, hue: Swatch? = nil, selected: Bool = false,
                      into screen: inout Screen) {
        let v = value.isFinite ? min(max(value, -span), span) : 0
        let arrow = Self.arrows[Int(((v + span) / (2 * span) * 6).rounded())]
        screen.ink(" \(arrow) ", x: x, y: y, t.style(value == 0 ? p.title : t.gain(value), selected ? p.chipHi : p.chip, .bold))
        screen.ink(label, x: x + 4, y: y, t.style(hue ?? p.text3, nil, selected ? .bold : []))
        screen.ink(MeterScene.gainText(value).leftPadded(to: 5), x: x, y: y + 1, t.style(t.gain(value)))
    }
}
