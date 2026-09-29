import EQTerm
import Foundation

/// The curve as one editable strip: the whole chain's response with a node per band, the ten
/// bands as vertical sliders with a live mini-meter each, and the chain beside or under them:
/// preamp, tone, tilt, compressor, colour, and what the output does (peak, limiter, headroom).
/// In console the sliders are faders on channel strips and the chain a master section.
struct TuneView {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette
    private let console: Bool
    private let profile: Profile

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
        console = scene.settings.look == .console
        profile = Self.profile(scene)
    }

    /// The saved curve; before the first header, what the frame and the header carry of it.
    static func profile(_ scene: MeterScene) -> Profile {
        if let profile = scene.header.profile { return profile }
        let f = scene.frame
        return Profile(name: nil, preamp: f.preamp.isFinite ? f.preamp : 0, bands: scene.gains, preference: scene.header.preference,
                       instruments: scene.header.knobs, dynamics: scene.header.dynamics)
    }

    struct Layout {
        var response: Rect?
        var bands: Rect
        var chain: Rect
        /// The chain as a tall column right of the bands; under them, it is two rows.
        var beside: Bool
        var cell: Int
        var x0: Int
        /// The first slider row and how many there are, +12 dB at the top.
        var top: Int
        var rows: Int

        func centre(_ band: Int) -> Int { x0 + band * cell + cell / 2 }
        var centres: [Int] { (0..<10).map(centre) }
        var labelY: Int { top + rows }
        var valueY: Int { top + rows + 1 }
        var meterY: Int { top + rows + 2 }

        func row(_ gain: Double) -> Int {
            let g = gain.isFinite ? min(max(gain, -Curve.span), Curve.span) : 0
            return Int(((Curve.span - g) / (2 * Curve.span) * Double(rows - 1)).rounded())
        }

        /// A cap never sits on the 0 dB row for a band that is not flat, however coarse the rows.
        func cap(_ gain: Double) -> Int {
            let at = row(gain), zero = row(0)
            guard at == zero, gain != 0, gain.isFinite else { return at }
            return min(max(gain > 0 ? zero - 1 : zero + 1, 0), rows - 1)
        }
    }

    static let gutter = 6
    static let chainWidth = 28
    static let chainRows = 4

    /// nil where the sliders do not fit: the controls as a list instead.
    static func layout(_ size: Size) -> Layout? {
        guard size.cols >= 60, size.rows >= 12 else { return nil }
        let top = 1 + (size.rows >= TabRow.minRows ? 1 : 0)
        let bottom = size.rows - 2
        let beside = size.cols >= 110
        var stack = Rect(x: 1, y: top, width: size.cols - 2 - (beside ? chainWidth + 1 : 0), height: bottom - top)
        let chain: Rect
        if beside {
            chain = Rect(x: stack.right + 1, y: top, width: chainWidth, height: stack.height)
        } else {
            stack.height -= chainRows
            chain = Rect(x: 1, y: stack.bottom, width: size.cols - 2, height: chainRows)
        }
        // Short terminals give the sliders the rows: a 6 dB step a row would hide small gains.
        var response = stack.height >= 18 ? min(10, max(6, stack.height / 3)) : 5
        if stack.height - response - 5 < 5 { response = 0 }
        let height = stack.height - response
        guard height - 5 >= 3 else { return nil }
        let bands = Rect(x: stack.x, y: stack.y + response, width: stack.width, height: height)
        let inner = bands.width - 2
        let cell = min(8, (inner - gutter - 1) / 10)
        guard cell >= 5 else { return nil }
        return Layout(response: response > 0 ? Rect(x: stack.x, y: stack.y, width: stack.width, height: response) : nil, bands: bands,
                      chain: chain, beside: beside, cell: cell, x0: bands.x + 1 + gutter + (inner - gutter - cell * 10) / 2,
                      top: bands.y + 1, rows: height - 5)
    }

    /// Where each chain control sits: a row each in the tall column (a knob each for tone in
    /// console), items along two rows under the bands.
    static func places(_ l: Layout, console: Bool) -> [(control: TuneControl, rect: Rect)] {
        let c = l.chain
        guard l.beside else {
            var result: [(TuneControl, Rect)] = []
            for (line, controls) in [[TuneControl.preamp, .bass, .treble, .tilt], [.comp, .colour, .amount]].enumerated() {
                var x = c.x + 2
                for control in controls {
                    let w = itemWidth(control)
                    result.append((control, Rect(x: x, y: c.y + 1 + line, width: w, height: 1)))
                    x += w + 2
                }
            }
            return result
        }
        let x = c.x + 1, w = c.width - 2
        var y = c.y + 2
        if console {
            var result: [(TuneControl, Rect)] = [(.preamp, Rect(x: x, y: y, width: w, height: 1))]
            y += 2
            for (i, control) in [TuneControl.bass, .treble, .tilt].enumerated() {
                result.append((control, Rect(x: x + 1 + i * 8, y: y, width: 8, height: 2)))
            }
            y += 3
            for control in [TuneControl.comp, .colour, .amount] {
                result.append((control, Rect(x: x, y: y, width: w, height: 1)))
                y += 2
            }
            return result
        }
        let spread = c.height >= 24 ? 2 : 1
        var result: [(TuneControl, Rect)] = []
        for control in [TuneControl.preamp, .bass, .treble, .tilt] {
            result.append((control, Rect(x: x, y: y, width: w, height: 1)))
            y += spread
        }
        // A row for the dynamics heading, after a blank one.
        y += spread == 1 ? 2 : 1
        for control in [TuneControl.comp, .colour, .amount] {
            result.append((control, Rect(x: x, y: y, width: w, height: 1)))
            y += spread
        }
        return result
    }

    /// Items under the bands: a label and a value field of a fixed width, so a click lands on the
    /// same place whatever the value.
    static func itemWidth(_ control: TuneControl) -> Int {
        switch control {
        case .comp, .colour: return control.name.count + 1 + 8
        case .amount: return control.name.count + 1 + 4
        default: return control.name.count + 1 + 6
        }
    }

    /// What a click or the wheel at a cell means: the band under it, or a chain control.
    static func control(at x: Int, _ y: Int, size: Size, look: Look) -> TuneControl? {
        guard let l = layout(size) else { return nil }
        let columns = l.x0..<(l.x0 + l.cell * 10)
        let bands = (l.bands.y + 1)..<(l.bands.bottom - 1)
        let response = l.response.map { ($0.y + 1)..<($0.bottom - 1) } ?? 0..<0
        if columns.contains(x), bands.contains(y) || response.contains(y) { return .band((x - l.x0) / l.cell) }
        return places(l, console: look == .console).first { $0.rect.contains(x: x, y: y) }?.control
    }

    /// The message row while nothing else is said: the selected control and how it moves.
    static func hint(_ control: TuneControl, app: AppMatch?) -> String {
        let text: String
        switch control {
        case .comp: text = "comp — ↑↓ off · gentle · night, Enter types one, 0 turns it off"
        case .colour: text = "colour — ↑↓ off · tape · tube, Enter types one, 0 turns it off"
        case .amount: text = "colour amount — ↑↓ 0.1, ⇧↑↓ 0.3, Alt↑↓ 0.05, Enter types a value"
        case .tilt: text = "tilt — ↑↓ 0.1 dB/octave, ⇧↑↓ 0.5, Alt↑↓ 0.05, Enter types a value"
        default: text = "\(control.name) selected — ↑↓ 0.5 dB, ⇧↑↓ 3 dB, Alt↑↓ 0.1 dB, Enter types a value"
        }
        guard let app else { return text }
        return "\(app.name) plays \(app.preset); edits here change this device's own curve · " + text
    }

    private var selected: TuneControl { scene.tune.selected }

    /// The most the whole chain lifts any frequency from 20 Hz to 20 kHz, preamp included.
    private var headroom: Double {
        -(profile.preamp + scene.chainCurve.peak(profile.engineBands, rate: scene.frame.rate))
    }

    func draw(into screen: inout Screen) {
        let size = scene.size
        if console {
            screen.fill(screen.area, with: Cell(" ", style: t.style(nil, p.surface)))
            StatusBar(scene: scene).console(into: &screen, width: size.cols)
        } else {
            StatusBar(scene: scene).studio(into: &screen, width: size.cols)
        }
        if scene.tabRows > 0 { TabRow.draw(scene, into: &screen) }
        if let l = Self.layout(size) {
            if let r = l.response { response(r, l, into: &screen) }
            if console { faders(l, into: &screen) } else { sliders(l, into: &screen) }
            if l.beside { column(l, into: &screen) } else { rows(l, into: &screen) }
        } else {
            list(into: &screen)
        }
        ShellRows(scene: scene).draw(messageY: size.rows >= 10 ? size.rows - 2 : nil, keybarY: size.rows - 1, x: 1, widen: false,
                                     into: &screen)
    }

    private func border(_ group: Int) -> Swatch { selected.group == group ? p.borderHi : p.border }

    private func label(_ text: String) -> String { console ? text.uppercased() : text }

    // MARK: Response

    private func response(_ r: Rect, _ l: Layout, into screen: inout Screen) {
        let over = -headroom
        Boxes.draw(r, into: &screen, t, border: border(0), title: label("response"), right: over > 0 ? nil : "+12 … -12 dB")
        if over > 0 {
            let long = " ! clips \(Table.gain(over)) dB — lower the preamp "
            let text = r.width >= TerminalText.width(long) + 16 ? long : " ! clips \(Table.gain(over)) dB "
            screen.ink(text, x: r.right - 2 - TerminalText.width(text), y: r.y, t.style(p.warn, console ? p.surface : nil, .bold))
        }
        let rows = r.height - 2, top = r.y + 1
        let x0 = r.x + 6, width = r.right - 1 - x0
        guard rows >= 3, width > 0 else { return }
        let window: Swatch? = console ? p.windowBg : nil
        if let window { screen.fill(Rect(x: r.x + 1, y: top, width: r.width - 2, height: rows), with: Cell(" ", style: t.style(nil, window, solid: true))) }
        let scale = console ? p.windowFg.mixed(toward: p.windowBg, 0.35) : p.text3
        let curve = scene.chainCurve
        curve.update(profile.engineBands, rate: scene.frame.rate, centres: l.centres, x0: x0, width: width, rows: rows)
        let zeroRow = Int((Double(rows * 4 - 1) / 2).rounded()) / 4
        var tint = [Swatch?](repeating: nil, count: width * rows)
        if !console {
            for cx in 0..<width {
                guard let a = curve.ys[cx * 2], let b = curve.ys[cx * 2 + 1] else { continue }
                let row = (a + b) / 2 / 4
                for y in min(row, zeroRow)...max(row, zeroRow) where y != row {
                    tint[y * width + cx] = row < zeroRow ? p.boostFill : p.cutFill
                }
            }
            for y in 0..<rows where y != zeroRow {
                for cx in 0..<width where tint[y * width + cx] != nil {
                    screen.set(x0 + cx, top + y, Cell(" ", style: t.style(nil, tint[y * width + cx])))
                }
            }
        }
        for cx in 0..<width {
            screen.set(x0 + cx, top + zeroRow, Cell("┈", style: t.style(console ? scale : p.grid, window ?? tint[zeroRow * width + cx])))
        }
        for (gain, y) in [(12, 0), (0, zeroRow), (-12, rows - 1)] {
            screen.ink(gain == 0 ? "  0" : String(format: "%+d", gain).leftPadded(to: 3), x: r.x + 2, y: top + y, t.style(scale, window))
        }
        let ink = console ? p.windowFg : p.curve
        for (col, column) in curve.glyphs where col >= 0 && col < width {
            for (y, glyph) in column where y >= 0 && y < rows {
                screen.set(x0 + col, top + y, Cell(String(glyph), style: t.style(ink, window ?? tint[y * width + col])))
            }
        }
        for band in 0..<10 {
            let cx = l.centre(band) - x0
            guard cx >= 0, cx < width, let dot = curve.ys[cx * 2] else { continue }
            let here = selected == .band(band)
            let gain = TuneControl.band(band).value(in: profile)
            let node = here ? (console ? p.capSel : p.accent) : (console ? (gain == 0 ? p.windowFg : p.needle) : t.gain(gain))
            let y = min(dot / 4, rows - 1)
            screen.set(x0 + cx, top + y, Cell(here ? "◉" : "●", style: t.style(node, window ?? tint[y * width + cx], .bold)))
        }
    }

    // MARK: Bands, studio

    private func sliders(_ l: Layout, into screen: inout Screen) {
        Boxes.draw(l.bands, into: &screen, t, border: border(0), title: "bands", right: "gain dB · level")
        scaleLabels(l, into: &screen)
        let zero = l.row(0)
        for band in 0..<10 {
            let cx = l.centre(band)
            let here = selected == .band(band)
            let bg: Swatch? = here ? p.sel : nil
            if here {
                let w = l.cell - 1
                screen.fill(Rect(x: cx - w / 2, y: l.top, width: w, height: l.rows + 3), with: Cell(" ", style: t.style(nil, p.sel)))
            }
            let gain = TuneControl.band(band).value(in: profile)
            let cap = l.cap(gain)
            for k in 0..<l.rows {
                let filled = k != cap && (min(cap, zero)...max(cap, zero)).contains(k) && gain != 0
                screen.ink(filled ? "┃" : "│", x: cx, y: l.top + k, t.style(filled ? t.gain(gain) : p.border, bg))
            }
            screen.ink("▐█▌", x: cx - 1, y: l.top + cap, t.style(here ? p.accent : p.title, bg))
            let name = (l.cell >= 7 ? Config.bandLabels : Table.shortLabels)[band]
            if here {
                let chip = " " + name + " "
                screen.ink(chip, x: cx - TerminalText.width(chip) / 2, y: l.labelY, t.style(p.onChip, p.accent, .bold, solid: true))
            } else {
                screen.ink(name, x: cx - TerminalText.width(name) / 2, y: l.labelY, t.style(p.text2))
            }
            value(band, gain: gain, x: cx, y: l.valueY, bg: bg, into: &screen)
            miniMeter(band, x: cx, y: l.meterY, width: min(5, l.cell - 3), into: &screen)
        }
    }

    private func scaleLabels(_ l: Layout, into screen: inout Screen) {
        for gain in [12, 6, 0, -6, -12] {
            let text = gain == 0 ? "0" : String(format: "%+d", gain)
            let ink = console ? p.text3 : (gain == 0 ? p.curve : p.text3)
            screen.ink(text.leftPadded(to: 3), x: l.bands.x + 2, y: l.top + l.row(Double(gain)), t.style(ink))
        }
    }

    private func value(_ band: Int, gain: Double, x: Int, y: Int, bg: Swatch?, into screen: inout Screen) {
        let text = MeterScene.gainText(gain)
        var style = t.style(t.gain(gain), bg)
        if let flash = scene.flash, flash.band == band, flash.left > MeterScene.flashBlendFrames {
            style = t.style(p.onChip, t.gain(gain) == p.text3 ? p.accent : t.gain(gain), .bold, solid: true)
        }
        // The units digit under the slider, the sign left of it.
        screen.ink(text, x: text.hasPrefix("+") || text.hasPrefix("-") ? x - 1 : x, y: y, style)
    }

    /// The band's level now: an eighth block by height in studio, a row of LEDs in console.
    private func miniMeter(_ band: Int, x: Int, y: Int, width: Int, into screen: inout Screen) {
        let level = scene.outLevels[band]
        let start = x - width / 2
        if console {
            let lit = Int(((level - Watch.floorDB) / -Watch.floorDB * Double(width)).rounded())
            for i in 0..<width {
                let db = Watch.floorDB + (Double(i) + 0.5) / Double(width) * -Watch.floorDB
                screen.ink("▆", x: start + i, y: y, t.style(t.led(db, lit: i < lit), p.surface))
            }
            return
        }
        guard level > Watch.floorDB + 0.5 else {
            screen.ink(String(repeating: "·", count: width), x: start, y: y, t.style(p.grid))
            return
        }
        let h = (level - Watch.floorDB) / -Watch.floorDB * 8
        screen.ink(String(repeating: Watch.partials[min(max(Int(h) - 1, 0), 7)], count: width), x: start, y: y, t.style(t.level(level)))
    }

    // MARK: Bands, console

    private func faders(_ l: Layout, into screen: inout Screen) {
        Boxes.draw(l.bands, into: &screen, t, border: border(0), title: "FADERS", right: "GAIN dB · LEVEL", fill: p.surface)
        scaleLabels(l, into: &screen)
        let zero = l.row(0)
        for band in 0..<10 {
            let cx = l.centre(band)
            let here = selected == .band(band)
            let left = l.x0 + band * l.cell
            if band < 9 {
                for y in l.top...l.meterY { screen.ink("│", x: left + l.cell - 1, y: y, t.style(p.groove)) }
            }
            let bg: Swatch? = here ? p.sel : nil
            if here {
                screen.fill(Rect(x: left, y: l.top, width: l.cell - 1, height: l.rows), with: Cell(" ", style: t.style(nil, p.sel)))
            }
            let gain = TuneControl.band(band).value(in: profile)
            let cap = l.cap(gain)
            let wide = l.cell >= 7
            for k in 0..<l.rows {
                if k == zero, wide {
                    screen.ink("╶─", x: cx - 2, y: l.top + k, t.style(p.text3, bg))
                    screen.ink("─╴", x: cx + 1, y: l.top + k, t.style(p.text3, bg))
                }
                let filled = k != cap && (min(cap, zero)...max(cap, zero)).contains(k) && gain != 0
                screen.ink(filled ? "┃" : "│", x: cx, y: l.top + k, t.style(filled ? t.gain(gain) : p.track, bg))
            }
            let flashing = scene.flash.map { $0.band == band && $0.left > MeterScene.flashBlendFrames } ?? false
            let capText = wide ? "▐███▌" : "▐█▌"
            screen.ink(capText, x: cx - capText.count / 2, y: l.top + cap, t.style(here || flashing ? p.capSel : p.cap, bg))
            var tape = " " + Table.shortLabels[band] + (l.cell >= 8 ? " Hz" : "") + " "
            tape = String(tape.prefix(l.cell - 1))
            let pad = l.cell - 1 - tape.count
            tape = String(repeating: " ", count: pad / 2) + tape + String(repeating: " ", count: pad - pad / 2)
            screen.ink(tape, x: left, y: l.labelY, t.style(p.tapeFg, here ? p.capSel : p.tapeBg, .bold, solid: true))
            let readout = MeterScene.gainText(gain).leftPadded(to: 5)
            screen.ink(readout, x: cx - 2, y: l.valueY, t.style(here || flashing ? p.lcdFg : t.gain(gain), p.lcdBg,
                                                                                      here || flashing ? .bold : []))
            miniMeter(band, x: cx, y: l.meterY, width: min(5, l.cell - 3), into: &screen)
        }
    }

    // MARK: Chain

    private func column(_ l: Layout, into screen: inout Screen) {
        let c = l.chain
        Boxes.draw(c, into: &screen, t, border: selected.group > 0 ? p.borderHi : p.border, title: label("chain"), fill: console ? p.surface : nil)
        let places = Self.places(l, console: console)
        var y = (places.last?.rect.bottom ?? c.y + 2) + 1
        if console {
            for place in places { consoleControl(place.control, place.rect, into: &screen) }
        } else {
            for place in places { row(place.control, place.rect, into: &screen) }
            if let comp = places.first(where: { $0.control == .comp }) {
                heading("dynamics", x: c.x + 2, y: comp.rect.y - 1, width: c.width - 4, into: &screen)
            }
        }
        guard y + 4 <= c.bottom - 1 else { return }
        if !console {
            heading("output", x: c.x + 2, y: y, width: c.width - 4, into: &screen)
            y += 1
        } else {
            screen.ink("OUTPUT", x: c.x + 2, y: y, t.style(p.text3))
            y += 1
        }
        output(x: c.x + 2, y: y, width: c.width - 4, into: &screen)
    }

    private func heading(_ text: String, x: Int, y: Int, width: Int, into screen: inout Screen) {
        let used = screen.ink(text, x: x, y: y, t.style(p.text3))
        screen.ink(String(repeating: "─", count: max(width - used - 1, 0)), x: x + used + 1, y: y, t.style(p.border))
    }

    /// Where a gauge or a knob reaches its end; tone as the side column draws it.
    private func span(_ control: TuneControl) -> Double {
        switch control {
        case .tilt: return Preference.tiltRange.upperBound
        case .bass, .treble: return 6
        default: return Curve.span
        }
    }

    /// One control of the studio column: label, a gauge or `‹ mode ›`, the value.
    private func row(_ control: TuneControl, _ r: Rect, into screen: inout Screen) {
        let here = selected == control
        let bg: Swatch? = here ? p.sel : nil
        if here {
            screen.fill(r, with: Cell(" ", style: t.style(nil, p.sel)))
            screen.ink("▸", x: r.x, y: r.y, t.style(p.accent, bg, .bold))
        }
        screen.ink(control.name, x: r.x + 1, y: r.y, t.style(here ? p.accent : p.text3, bg, here ? .bold : []))
        let gx = r.x + 9, gw = r.width - 16
        let v = control.value(in: profile)
        switch control {
        case .comp, .colour:
            let on = v >= 1
            let arrows = t.style(here ? p.accent : p.text3, bg)
            screen.ink("‹", x: gx, y: r.y, arrows)
            screen.ink(control.text(in: profile), x: gx + 2, y: r.y, t.style(on ? p.accent : p.text3, bg, on ? .bold : []))
            screen.ink("›", x: gx + 9, y: r.y, arrows)
        case .amount:
            gauge(x: gx, y: r.y, width: gw, fraction: v, on: profile.dynamics?.color != nil, into: &screen)
            screen.ink(control.text(in: profile).leftPadded(to: 5), x: r.right - 6, y: r.y, t.style(v > 0 ? p.text : p.text3, bg))
        default:
            Gauges.bipolar(x: gx, y: r.y, width: gw, value: v, span: span(control), t, into: &screen)
            screen.ink(control.text(in: profile).leftPadded(to: 5), x: r.right - 6, y: r.y, t.style(t.gain(v), bg))
        }
    }

    private func gauge(x: Int, y: Int, width: Int, fraction: Double, on: Bool, into screen: inout Screen) {
        guard width > 0 else { return }
        let n = on ? Int((min(max(fraction, 0), 1) * Double(width)).rounded()) : 0
        screen.ink(String(repeating: "█", count: n), x: x, y: y, t.style(p.accent))
        screen.ink(String(repeating: "·", count: width - n), x: x + n, y: y, t.style(p.grid))
    }

    /// One control of the console's chain: a fader, a knob, a row of lamps, an LED bar.
    private func consoleControl(_ control: TuneControl, _ r: Rect, into screen: inout Screen) {
        let here = selected == control
        let name = control == .treble ? "TREB" : control.name.uppercased()
        let v = control.value(in: profile)
        func tag(_ x: Int, _ y: Int) -> Int {
            screen.ink(name, x: x, y: y, here ? t.style(p.onChip, p.capSel, .bold, solid: true) : t.style(p.text3))
        }
        switch control {
        case .preamp:
            _ = tag(r.x + 1, r.y)
            let tw = r.width - 15
            let pos = Int(((min(max(v, -12), 12) + 12) / 24 * Double(tw - 1)).rounded())
            screen.ink(String(repeating: "─", count: tw), x: r.x + 8, y: r.y, t.style(p.track))
            screen.ink("┼", x: r.x + 8 + tw / 2, y: r.y, t.style(p.text3))
            screen.ink("█", x: r.x + 8 + pos, y: r.y, t.style(here ? p.capSel : p.cap))
            screen.ink(MeterScene.gainText(v).leftPadded(to: 5), x: r.right - 6, y: r.y, t.style(t.gain(v), nil, .bold))
        case .bass, .treble, .tilt:
            let s = span(control)
            let clamped = v.isFinite ? min(max(v, -s), s) : 0
            let arrow = Self.arrows[Int(((clamped + s) / (2 * s) * 6).rounded())]
            screen.ink(" \(arrow) ", x: r.x, y: r.y, t.style(v == 0 ? p.title : t.gain(v), here ? p.capSel : p.chip, .bold))
            screen.ink(name, x: r.x + 4, y: r.y, t.style(here ? p.capSel : p.text3, nil, here ? .bold : []))
            screen.ink(control.text(in: profile).leftPadded(to: 5), x: r.x, y: r.y + 1, t.style(t.gain(v)))
        case .comp, .colour:
            var x = r.x + 1 + tag(r.x + 1, r.y) + 1
            let names = ["off"] + (control == .comp ? Dynamics.Compressor.allCases.map(\.rawValue) : Dynamics.ColourKind.allCases.map(\.rawValue))
            for (i, mode) in names.enumerated() {
                let on = Int(v) == i
                screen.ink("●", x: x, y: r.y, t.style(on ? p.accent : p.lampOff))
                x += 1 + screen.ink(mode, x: x + 1, y: r.y, t.style(on ? p.title : p.text3, nil, on ? .bold : [])) + 1
            }
        default:
            _ = tag(r.x + 1, r.y)
            let lit = profile.dynamics?.color == nil ? 0 : Int((min(max(v, 0), 1) * 10).rounded())
            screen.ink(String(repeating: "▆", count: lit), x: r.x + 9, y: r.y, t.style(p.accent))
            screen.ink(String(repeating: "▆", count: 10 - lit), x: r.x + 9 + lit, y: r.y, t.style(p.lampOff))
            screen.ink(control.text(in: profile).leftPadded(to: 5), x: r.right - 6, y: r.y, t.style(p.lcdFg, p.lcdBg))
        }
    }

    private static let arrows = Array("↙←↖↑↗→↘")

    /// Peak with its hold, the limiter, and the headroom the curve leaves: over 0 dBFS a boost
    /// clips before the limiter catches it.
    private func output(x: Int, y: Int, width: Int, into screen: inout Screen) {
        let peak = scene.frame.peak.isFinite ? scene.frame.peak : Watch.floorDB
        screen.ink(label("peak"), x: x, y: y, t.style(p.text3))
        if console {
            screen.ink(String(format: " %5.1f ", peak), x: x + 7, y: y, t.style(p.lcdFg, p.lcdBg))
        } else {
            let gw = width - 14
            let lit = Int((min(max(peak, Watch.floorDB), 0) - Watch.floorDB) / -Watch.floorDB * Double(gw))
            for i in 0..<max(gw, 0) {
                let db = Watch.floorDB + (Double(i) + 0.5) / Double(gw) * -Watch.floorDB
                screen.ink(i < lit ? "█" : "·", x: x + 8 + i, y: y, t.style(i < lit ? t.level(db) : p.grid))
            }
            screen.ink(String(format: "%5.1f", peak), x: x + width - 5, y: y, t.style(p.text))
        }
        screen.ink(label("limit"), x: x, y: y + 1, t.style(p.text3))
        screen.ink("●", x: x + 8, y: y + 1, t.style(scene.limiting ? p.danger : (console ? p.lampOff : p.grid)))
        screen.ink(scene.limiting ? "limiting" : "idle", x: x + 10, y: y + 1, t.style(scene.limiting ? p.danger : p.text3))
        let over = -headroom
        screen.ink(label("clip"), x: x, y: y + 2, t.style(p.text3))
        if over > 0 {
            screen.ink("●", x: x + 8, y: y + 2, t.style(p.danger))
            screen.ink("\(Table.gain(over)) dB over", x: x + 10, y: y + 2, t.style(p.warn, nil, .bold))
        } else {
            screen.ink(console ? "●" : "✓", x: x + 8, y: y + 2, t.style(console ? p.lampOff : p.ok))
            screen.ink(String(format: "%.1f dB spare", -over), x: x + 10, y: y + 2, t.style(p.text3))
        }
    }

    /// Under the bands: the chain as items along two rows, the output at the right of the second.
    private func rows(_ l: Layout, into screen: inout Screen) {
        let c = l.chain
        Boxes.draw(c, into: &screen, t, border: selected.group > 0 ? p.borderHi : p.border, title: label("chain"), fill: console ? p.surface : nil)
        let places = Self.places(l, console: console)
        for (control, r) in places {
            let here = selected == control
            let v = control.value(in: profile)
            let tagStyle = here ? t.style(p.onChip, console ? p.capSel : p.accent, .bold, solid: true) : t.style(p.text3)
            let used = screen.ink(label(control.name), x: r.x, y: r.y, tagStyle) + 1
            let text = control.isChoice ? "‹" + control.text(in: profile) + "›"
                : control.text(in: profile).leftPadded(to: r.width - used)
            let ink: Swatch = control.isChoice || control == .amount ? (v > 0 ? p.accent : p.text3) : t.gain(v)
            screen.ink(text, x: r.x + used, y: r.y, console ? t.style(p.lcdFg, p.lcdBg, here ? .bold : []) : t.style(ink, nil, here ? .bold : []))
        }
        let peak = scene.frame.peak.isFinite ? scene.frame.peak : Watch.floorDB
        let over = -headroom
        // Headroom matters most, then the limiter; the peak goes first when the row is short.
        var parts: [(String, Swatch)] = [(String(format: "peak %.1f", peak), p.text2), ("● limit", scene.limiting ? p.danger : p.text3),
                                         (over > 0 ? "clips \(Table.gain(over))" : String(format: "%.1f dB spare", -over), over > 0 ? p.warn : p.text3)]
        let start = (places.last?.rect.right ?? c.x) + 3
        func total() -> Int { parts.reduce(0) { $0 + TerminalText.width($1.0) + 2 } }
        while !parts.isEmpty, c.right - 1 - total() < start { parts.removeFirst() }
        var x = c.right - total()
        for (text, ink) in parts { x += screen.ink(text, x: x, y: c.y + 2, t.style(ink, nil, ink == p.warn ? .bold : [])) + 2 }
    }

    // MARK: Too small for sliders

    /// Every control as a row, the selected one marked, scrolled to keep it in sight.
    private func list(into screen: inout Screen) {
        let size = scene.size
        let top = 1 + scene.tabRows
        let visible = max(size.rows - 2 - top, 0)
        let all = TuneControl.all
        let first = min(max(selected.index - visible / 2, 0), max(all.count - visible, 0))
        for (i, control) in all.dropFirst(first).prefix(visible).enumerated() {
            let y = top + i
            let here = control == selected
            if here { screen.fill(Rect(x: 0, y: y, width: size.cols, height: 1), with: Cell(" ", style: t.style(nil, p.sel))) }
            let bg: Swatch? = here ? p.sel : nil
            screen.ink(here ? "▸" : " ", x: 1, y: y, t.style(p.accent, bg, .bold))
            screen.ink(control.name, x: 3, y: y, t.style(here ? p.title : p.text2, bg, here ? .bold : []))
            let v = control.value(in: profile)
            let ink: Swatch = control.isChoice || control == .amount ? (v > 0 ? p.accent : p.text3) : t.gain(v)
            screen.ink(control.text(in: profile).leftPadded(to: 7), x: 12, y: y, t.style(ink, bg))
            if case .band(let band) = control, size.cols >= 26 {
                miniMeter(band, x: 23, y: y, width: 3, into: &screen)
            }
        }
    }
}

/// The whole chain's response for the Tune view, worked out again only when the curve, the rate
/// or the geometry changes: the braille glyphs over the panel, and the loudest point.
final class ChainCurve {
    private struct Key: Equatable {
        var bands: [EQBand]
        var rate: Double
        var centres: [Int]
        var x0, width, rows: Int
    }

    private var key: Key?
    /// A dot row per half column, nil outside 10 Hz up to the lower of 22 kHz and Nyquist.
    private(set) var ys: [Int?] = []
    private(set) var glyphs: [Int: [Int: Character]] = [:]
    private var peakKey: ([EQBand], Double)?
    private var peakValue = 0.0

    private static func coefficients(_ bands: [EQBand], fs: Double) -> [BiquadCoefficients] {
        bands.filter { band in
            band.isEnabled && band.frequency < fs / 2 && band.gain.isFinite
                && !(band.gain == 0 && [.peak, .lowShelf, .highShelf].contains(band.type))
        }.map { BiquadCoefficients.make(type: $0.type, frequency: $0.frequency, gainDB: $0.gain, q: $0.q, sampleRate: fs) }
    }

    private static func rate(_ rate: Double) -> Double { rate > 0 ? rate : Config.stabilityCheckRate }

    func update(_ bands: [EQBand], rate: Double, centres: [Int], x0: Int, width: Int, rows: Int) {
        let next = Key(bands: bands, rate: rate, centres: centres, x0: x0, width: width, rows: rows)
        guard next != key else { return }
        key = next
        let fs = Self.rate(rate)
        let filters = Self.coefficients(bands, fs: fs)
        let total = Double(rows * 4 - 1)
        let top = min(22000, fs * 0.49)
        ys = (0..<(width * 2)).map { dx in
            let f = Strip.frequency(at: Double(x0) + (Double(dx) + 0.5) / 2, centres: centres)
            guard f >= 10, f <= top else { return nil }
            let g = min(max(filters.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: fs) }, -Curve.span), Curve.span)
            return Int(((Curve.span - g) / (2 * Curve.span) * total).rounded())
        }
        guard var lo = ys.firstIndex(where: { $0 != nil }) else {
            glyphs = [:]
            return
        }
        lo += lo % 2
        var hi = lo
        while hi < ys.count, ys[hi] != nil { hi += 1 }
        let cells = Curve.cells(ys[lo..<hi].map { $0! })
        glyphs = Dictionary(uniqueKeysWithValues: cells.map { ($0.key + lo / 2, $0.value) })
    }

    /// The loudest the chain lifts anything from 20 Hz to 20 kHz, on a twelfth-octave sweep.
    func peak(_ bands: [EQBand], rate: Double) -> Double {
        if let peakKey, peakKey.0 == bands, peakKey.1 == rate { return peakValue }
        let fs = Self.rate(rate)
        let filters = Self.coefficients(bands, fs: fs)
        let points = (0...120).map { 20 * pow(1000, Double($0) / 120) }.filter { $0 < fs / 2 }
        peakValue = points.map { f in filters.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: fs) } }.max() ?? 0
        peakKey = (bands, rate)
        return peakValue
    }
}
