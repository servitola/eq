import EQTerm
import Foundation

/// The curves a preview panel draws, each worked out again only when its bands or the panel change.
final class PreviewCurves {
    let main = ChainCurve()
    let behind = ChainCurve()
    let over = ChainCurve()
}

/// A curve on the ten bands' log-frequency axis in a box: boost and cut tinted under it (a
/// backlit window in console), another drawn faint behind it, a third in the accent over it, and
/// a dot on it at each of `nodes`.
struct ResponsePanel {
    let scene: MeterScene

    func draw(_ r: Rect, title: String, right: String?, bands: [EQBand], behind: [EQBand]? = nil, over: [EQBand]? = nil,
              nodes: [(frequency: Double, selected: Bool)] = [], into screen: inout Screen) {
        let t = scene.theme, p = t.p
        let console = scene.settings.look == .console
        Boxes.draw(r, into: &screen, t, border: p.border, title: console ? title.uppercased() : title, right: right, fill: console ? p.surface : nil)
        let rows = r.height - 3, top = r.y + 1
        let x0 = r.x + 6, width = r.right - 2 - x0
        guard rows >= 3, width >= 20 else { return }
        let window: Swatch? = console ? p.windowBg : nil
        if let window { screen.fill(Rect(x: r.x + 1, y: top, width: r.width - 2, height: rows), with: Cell(" ", style: t.style(nil, window, solid: true))) }
        let centres = (0..<10).map { x0 + ($0 * 2 + 1) * width / 20 }
        let rate = scene.frame.rate
        let curves = scene.previews
        curves.main.update(bands, rate: rate, centres: centres, x0: x0, width: width, rows: rows)
        let zeroRow = Int((Double(rows * 4 - 1) / 2).rounded()) / 4
        var tint = [Swatch?](repeating: nil, count: width * rows)
        if !console {
            for cx in 0..<width {
                guard let a = curves.main.ys[cx * 2], let b = curves.main.ys[cx * 2 + 1] else { continue }
                let row = (a + b) / 2 / 4
                for y in min(row, zeroRow)...max(row, zeroRow) where y != row { tint[y * width + cx] = row < zeroRow ? p.boostFill : p.cutFill }
            }
            for y in 0..<rows where y != zeroRow {
                for cx in 0..<width where tint[y * width + cx] != nil {
                    screen.set(x0 + cx, top + y, Cell(" ", style: t.style(nil, tint[y * width + cx])))
                }
            }
        }
        let scale = console ? p.windowFg.mixed(toward: p.windowBg, 0.35) : p.text3
        for cx in 0..<width {
            screen.set(x0 + cx, top + zeroRow, Cell("┈", style: t.style(console ? scale : p.grid, window ?? tint[zeroRow * width + cx])))
        }
        for (gain, y) in [(12, 0), (0, zeroRow), (-12, rows - 1)] {
            screen.ink(gain == 0 ? "  0" : String(format: "%+d", gain).leftPadded(to: 3), x: r.x + 2, y: top + y, t.style(scale, window))
        }
        func glyphs(_ curve: ChainCurve, _ ink: Swatch, _ attributes: Style.Attributes = []) {
            for (col, column) in curve.glyphs where col >= 0 && col < width {
                for (y, glyph) in column where y >= 0 && y < rows {
                    screen.set(x0 + col, top + y, Cell(String(glyph), style: t.style(ink, window ?? tint[y * width + col], attributes)))
                }
            }
        }
        if let behind {
            curves.behind.update(behind, rate: rate, centres: centres, x0: x0, width: width, rows: rows)
            glyphs(curves.behind, console ? scale : p.text3)
        }
        glyphs(curves.main, console ? p.windowFg : p.curve)
        if let over {
            curves.over.update(over, rate: rate, centres: centres, x0: x0, width: width, rows: rows)
            glyphs(curves.over, console ? p.capSel : p.accent, .bold)
        }
        for node in nodes {
            let cx = Int(Strip.x(node.frequency, centres: centres).rounded()) - x0
            guard cx >= 0, cx < width, let dot = curves.main.ys[cx * 2] else { continue }
            let y = min(dot / 4, rows - 1)
            let ink = node.selected ? (console ? p.capSel : p.accent) : (console ? p.needle : p.title)
            screen.set(x0 + cx, top + y, Cell(node.selected ? "◉" : "●", style: t.style(ink, window ?? tint[y * width + cx], .bold)))
        }
        let labels = Table.shortLabels
        let step = width / 10 >= 5 ? 1 : 2
        for (i, label) in labels.enumerated() where i % step == 0 {
            screen.ink(label, x: centres[i] - TerminalText.width(label) / 2, y: top + rows, t.style(p.text3))
        }
    }
}

/// A list panel at the left and a preview at the right; below 60 columns the list alone.
struct SplitLayout {
    var list: Rect
    var preview: Rect?

    init(_ size: Size, wide: Int = 50) {
        let body = Chrome.body(size)
        guard body.width >= 60 else {
            list = body
            preview = nil
            return
        }
        let w = body.width >= 110 ? wide : max(body.width * 9 / 20, 30)
        list = Rect(x: body.x, y: body.y, width: w, height: body.height)
        preview = Rect(x: body.x + w + 1, y: body.y, width: body.width - w - 1, height: body.height)
    }

    /// Rows under the column titles, after `skip` rows of the list's own.
    func visible(skip: Int = 0) -> Int { max(list.height - 3 - skip, 0) }

    /// The item a click at a cell lands on.
    func item(at x: Int, _ y: Int, count: Int, selected: Int, skip: Int = 0) -> Int? {
        let first = list.y + 2 + skip
        guard list.inset(by: 1).contains(x: x, y: y), y >= first else { return nil }
        let visible = self.visible(skip: skip)
        let index = Lists.offset(selected: selected, visible: visible) + y - first
        return y - first < visible && index < count ? index : nil
    }
}

/// The preview's lines under or beside a curve: the preset, the preamp, tone, knobs, dynamics and filters.
enum Layers {
    typealias Line = (label: String, runs: [(text: String, ink: Swatch)])

    static func lines(_ profile: Profile, mark: Table.PresetMark?, _ t: Theme) -> [Line] {
        let p = t.p
        var lines: [Line] = []
        if let mark { lines.append(("preset", [("◆ ", p.accent), (mark.name, p.title)] + (mark.modified ? [("*", p.warn)] : []))) }
        lines.append(("preamp", [(MeterScene.gainText(profile.preamp) + " dB", t.gain(profile.preamp))]))
        let tone = [("bass", profile.preference?.bass ?? 0), ("treble", profile.preference?.treble ?? 0), ("tilt", profile.preference?.tilt ?? 0)]
            .filter { $0.1 != 0 }
        lines.append(("tone", tone.isEmpty ? [("flat", p.text3)]
            : tone.enumerated().flatMap { i, part in [((i > 0 ? "  " : "") + part.0 + " ", p.text2), (String(format: "%+g", part.1), t.gain(part.1))] }))
        let knobs = profile.knobs
        lines.append(("knobs", knobs.isEmpty ? [("none", p.text3)]
            : knobs.enumerated().flatMap { i, knob in [((i > 0 ? "  " : "") + "● ", t.hue(knob.instrument)), (knob.instrument.name + " ", p.text2),
                                                      (String(format: "%+g", knob.gain), t.gain(knob.gain))] }))
        var dynamics: [(String, Swatch)] = []
        if let comp = profile.dynamics?.comp { dynamics += [(comp.rawValue, p.accent), (" comp", p.text2)] }
        if let colour = profile.dynamics?.color {
            dynamics += [((dynamics.isEmpty ? "" : "  ") + colour.kind.rawValue, p.accent), (String(format: " %g", colour.amount), p.text2)]
        }
        lines.append(("dynamics", dynamics.isEmpty ? [("off", p.text3)] : dynamics))
        let filters = profile.filters.count
        lines.append(("filters", filters == 0 ? [("none", p.text3)]
            : [("\(filters)", p.text)] + (profile.imported.map { [(" · " + $0, p.text3)] } ?? [])))
        return lines
    }

    /// What `current` has that `preset` does not, a line each: `32 Hz +4.8 → +3.0`; `same` when nothing.
    static func differences(_ current: Profile?, _ preset: Profile, _ t: Theme, same: String) -> [Line] {
        let p = t.p
        guard let current else { return [("", [("the current curve is not read yet", p.text3)])] }
        var lines: [Line] = []
        func change(_ label: String, _ before: String, _ after: String, _ ink: Swatch) {
            lines.append((label, [(before.leftPadded(to: 5), p.text3), (" → ", p.text3), (after.leftPadded(to: 5), ink)]))
        }
        for (i, (a, b)) in zip(current.bands, preset.bands).enumerated() where a != b {
            change(Table.shortLabels[i] + (i < 5 ? " Hz" : ""), MeterScene.gainText(a), MeterScene.gainText(b), t.gain(b))
        }
        if current.preamp != preset.preamp { change("preamp", MeterScene.gainText(current.preamp), MeterScene.gainText(preset.preamp), t.gain(preset.preamp)) }
        let a = current.preference ?? Preference(), b = preset.preference ?? Preference()
        for (name, x, y) in [("bass", a.bass, b.bass), ("treble", a.treble, b.treble), ("tilt", a.tilt, b.tilt)] where x != y {
            change(name, MeterScene.gainText(x), MeterScene.gainText(y), t.gain(y))
        }
        for instrument in Instruments.all {
            let x = current.instruments?[instrument.name] ?? 0, y = preset.instruments?[instrument.name] ?? 0
            if x != y { change(instrument.name, MeterScene.gainText(x), MeterScene.gainText(y), t.gain(y)) }
        }
        if current.dynamics?.comp != preset.dynamics?.comp {
            change("comp", current.dynamics?.comp?.rawValue ?? "off", preset.dynamics?.comp?.rawValue ?? "off", p.accent)
        }
        if current.dynamics?.color != preset.dynamics?.color {
            func colour(_ d: Dynamics?) -> String { d?.color.map { "\($0.kind.rawValue) \(String(format: "%g", $0.amount))" } ?? "off" }
            change("colour", colour(current.dynamics), colour(preset.dynamics), p.accent)
        }
        if !current.filters.elementsEqual(preset.filters, by: { $0.sounds(like: $1) }) {
            change("filters", "\(current.filters.count)", "\(preset.filters.count)", p.text)
        }
        return lines.isEmpty ? [("", [(same, p.ok)])] : lines
    }

    static func draw(_ lines: [Line], x: Int, y: Int, width: Int, rows: Int, _ t: Theme, upper: Bool, into screen: inout Screen) {
        let labelWidth = 9
        for (i, line) in lines.prefix(rows).enumerated() {
            screen.ink(upper ? line.label.uppercased() : line.label, x: x, y: y + i, t.style(t.p.text3), limit: labelWidth)
            var cx = x + labelWidth
            for run in line.runs where cx < x + width {
                cx += screen.ink(run.text, x: cx, y: y + i, t.style(run.ink), limit: x + width - cx)
            }
        }
    }
}

/// Ten gains as ten cells, a bar each from the bottom (-12 dB) to the top (+12), boost or cut in colour.
enum Spark {
    private static let blocks = Array("▁▂▃▄▅▆▇█")

    static func draw(_ bands: [Double], x: Int, y: Int, _ t: Theme, bg: Swatch?, into screen: inout Screen) {
        for (i, gain) in bands.prefix(10).enumerated() {
            let g = gain.isFinite ? min(max(gain, -12), 12) : 0
            let at = Int(((g + 12) / 24 * 7).rounded())
            screen.ink(String(blocks[at]), x: x + i, y: y, t.style(g == 0 ? t.p.grid : t.gain(g), bg))
        }
    }
}

/// The presets, the current device's marked with `*` when changed since; a preview of the chosen
/// one's curve and layers, or, with `v`, of what differs from the current device's.
struct PresetsView {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette
    private var console: Bool { scene.settings.look == .console }

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    static func selected(_ scene: MeterScene) -> String? {
        let names = scene.library.presetNames
        return names.indices.contains(scene.lists.preset) ? names[scene.lists.preset] : nil
    }

    static func item(at x: Int, _ y: Int, size: Size, count: Int, selected: Int) -> Int? {
        SplitLayout(size).item(at: x, y, count: count, selected: selected)
    }

    private var current: Profile? { scene.header.profile }

    func draw(into screen: inout Screen) {
        Chrome.top(scene, into: &screen)
        let l = SplitLayout(scene.size)
        list(l, into: &screen)
        if let r = l.preview { preview(r, into: &screen) }
        Chrome.bottom(scene, into: &screen)
    }

    private func label(_ text: String) -> String { console ? text.uppercased() : text }

    private func list(_ l: SplitLayout, into screen: inout Screen) {
        let box = l.list
        let names = scene.library.presetNames
        let mark = scene.header.preset
        Boxes.draw(box, into: &screen, t, border: p.borderHi, title: label("presets"), right: scene.library.loaded ? "\(names.count)" : nil,
                   fill: console ? p.surface : nil)
        guard box.height >= 4, box.width >= 20 else { return }
        let spark = box.right - 20, preamp = box.right - 8
        screen.ink(label("preset"), x: box.x + 4, y: box.y + 1, t.style(p.text3))
        if spark > box.x + 16 { screen.ink(label("curve"), x: spark, y: box.y + 1, t.style(p.text3)) }
        screen.ink(label("preamp"), x: preamp - 1, y: box.y + 1, t.style(p.text3))
        if let error = scene.library.error {
            screen.ink(error, x: box.x + 2, y: box.y + 2, t.style(p.danger), limit: box.width - 4)
            return
        }
        guard !names.isEmpty else {
            let text = scene.library.loaded ? "no presets — s saves the current curve as one" : "reading the presets…"
            screen.ink(text, x: box.x + 2, y: box.y + 2, t.style(p.text3), limit: box.width - 4)
            return
        }
        let visible = l.visible()
        let first = Lists.offset(selected: scene.lists.preset, visible: visible)
        for (i, name) in names.enumerated().dropFirst(first).prefix(visible) {
            let y = box.y + 2 + i - first
            let here = i == scene.lists.preset
            let bg: Swatch? = here ? p.sel : nil
            if here { screen.fill(Rect(x: box.x + 1, y: y, width: box.width - 2, height: 1), with: Cell(" ", style: t.style(nil, p.sel))) }
            if here { screen.ink("▸", x: box.x + 1, y: y, t.style(p.accent, bg, .bold)) }
            let isCurrent = mark?.name == name
            if isCurrent { screen.ink("◆", x: box.x + 2, y: y, t.style(p.accent, bg)) }
            let limit = (spark > box.x + 16 ? spark : preamp) - box.x - 6
            let used = screen.ink(TerminalText.truncated(name, columns: limit), x: box.x + 4, y: y,
                                  t.style(here || isCurrent ? p.title : p.text, bg, here || isCurrent ? .bold : []))
            if isCurrent, mark?.modified == true { screen.ink("*", x: box.x + 4 + used, y: y, t.style(p.warn, bg, .bold)) }
            guard let profile = scene.library.presets[name] else { continue }
            if spark > box.x + 16 { Spark.draw(profile.bands, x: spark, y: y, t, bg: bg, into: &screen) }
            screen.ink(MeterScene.gainText(profile.preamp).leftPadded(to: 5), x: preamp, y: y, t.style(t.gain(profile.preamp), bg))
        }
    }

    private func preview(_ r: Rect, into screen: inout Screen) {
        guard let name = Self.selected(scene), let preset = scene.library.presets[name] else {
            Boxes.draw(r, into: &screen, t, border: p.border, title: label("preview"), fill: console ? p.surface : nil)
            return
        }
        let diff = scene.lists.diff
        let device = scene.frame.device ?? "the current device"
        let beside = r.width >= 64
        let side = beside ? 26 : 0
        let lines = diff ? Layers.differences(current, preset, t, same: "the same curve as the current device")
            : Layers.lines(preset, mark: nil, t).map { ($0.label, $0.runs) }
        let under = beside ? 0 : min(lines.count, max(r.height - 9, 0))
        let curve = Rect(x: r.x, y: r.y, width: r.width - side, height: r.height - under)
        ResponsePanel(scene: scene).draw(curve, title: name, right: diff ? "vs \(device), faint" : "curve",
                                         bands: preset.engineBands, behind: diff ? current?.engineBands : nil, into: &screen)
        if beside {
            let box = Rect(x: r.right - side + 1, y: r.y, width: side - 1, height: r.height)
            Boxes.draw(box, into: &screen, t, border: p.border, title: label(diff ? "differs" : "layers"), fill: console ? p.surface : nil)
            Layers.draw(lines, x: box.x + 2, y: box.y + 1, width: box.width - 3, rows: box.height - 2, t, upper: console, into: &screen)
        } else if under > 0 {
            Layers.draw(lines, x: r.x + 2, y: curve.bottom, width: r.width - 3, rows: under, t, upper: console, into: &screen)
        }
    }
}

/// The outputs and the devices with a profile of their own: which one plays, how each is connected,
/// whose curve it has; a preview of the chosen one's curve. In driver mode the EQ device heads the
/// list as what it is, the system's output, and is never one to pick.
struct DevicesView {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette
    private var console: Bool { scene.settings.look == .console }

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    /// Rows the list keeps above the devices: the EQ device's, in driver mode.
    static func skip(_ library: Library) -> Int { library.driver != nil ? 1 : 0 }

    static func item(at x: Int, _ y: Int, size: Size, library: Library, selected: Int) -> Int? {
        SplitLayout(size).item(at: x, y, count: library.rows.count, selected: selected, skip: skip(library))
    }

    static func glyph(_ transport: String?) -> String {
        switch transport {
        case "builtin": return "■"
        case "usb": return "▪"
        case "bluetooth": return "◇"
        case "hdmi", "displayport": return "□"
        case "airplay": return "○"
        case "thunderbolt": return "◆"
        case nil: return "·"
        default: return "▫"
        }
    }

    static func transport(_ transport: String?) -> String {
        switch transport {
        case "builtin": return "built-in"
        case "usb": return "USB"
        case "bluetooth": return "Bluetooth"
        case "hdmi": return "HDMI"
        case "displayport": return "DisplayPort"
        case "airplay": return "AirPlay"
        case "thunderbolt": return "Thunderbolt"
        case nil: return "offline"
        case let other?: return other
        }
    }

    func draw(into screen: inout Screen) {
        Chrome.top(scene, into: &screen)
        let l = SplitLayout(scene.size)
        list(l, into: &screen)
        if let r = l.preview { preview(r, into: &screen) }
        Chrome.bottom(scene, into: &screen)
    }

    private func label(_ text: String) -> String { console ? text.uppercased() : text }

    private func list(_ l: SplitLayout, into screen: inout Screen) {
        let box = l.list
        let library = scene.library
        let rows = library.rows
        let connected = rows.filter(\.connected).count
        Boxes.draw(box, into: &screen, t, border: p.borderHi, title: label("devices"),
                   right: library.loaded ? "\(connected) connected · \(rows.count - connected) not" : nil, fill: console ? p.surface : nil)
        guard box.height >= 4, box.width >= 24 else { return }
        let kind = box.right - 24, curve = box.right - 12
        screen.ink(label("output"), x: box.x + 7, y: box.y + 1, t.style(p.text3))
        if kind > box.x + 20 { screen.ink(label("via"), x: kind, y: box.y + 1, t.style(p.text3)) }
        screen.ink(label("curve"), x: curve, y: box.y + 1, t.style(p.text3))
        var y = box.y + 2
        if let driver = library.driver {
            screen.ink("EQ", x: box.x + 4, y: y, t.style(p.onChip, p.accent, .bold, solid: true))
            let used = screen.ink(driver.name, x: box.x + 7, y: y, t.style(p.title, nil, .bold), limit: box.width - 9)
            let target = driver.target.map { "system output → \($0.name)" } ?? "system output, no device to play on"
            screen.ink(" " + target, x: box.x + 7 + used, y: y, t.style(p.text3), limit: max(box.right - 2 - box.x - 7 - used, 0))
            y += 1
        }
        if let error = library.error {
            screen.ink(error, x: box.x + 2, y: y, t.style(p.danger), limit: box.width - 4)
            return
        }
        guard !rows.isEmpty else {
            screen.ink(library.loaded ? "no outputs" : "reading the outputs…", x: box.x + 2, y: y, t.style(p.text3), limit: box.width - 4)
            return
        }
        let visible = l.visible(skip: Self.skip(library))
        let first = Lists.offset(selected: scene.lists.device, visible: visible)
        for (i, row) in rows.enumerated().dropFirst(first).prefix(visible) {
            let ry = y + i - first
            let here = i == scene.lists.device
            let bg: Swatch? = here ? p.sel : nil
            if here {
                screen.fill(Rect(x: box.x + 1, y: ry, width: box.width - 2, height: 1), with: Cell(" ", style: t.style(nil, p.sel)))
                screen.ink("▸", x: box.x + 1, y: ry, t.style(p.accent, bg, .bold))
            }
            let plays = row.uid == library.current?.uid
            if plays {
                screen.ink("◉", x: box.x + 3, y: ry, t.style(p.accent, bg, .bold))
            } else if row.uid == library.output {
                screen.ink("○", x: box.x + 3, y: ry, t.style(p.text2, bg))
            }
            screen.ink(Self.glyph(row.transport), x: box.x + 5, y: ry, t.style(row.connected ? p.text2 : p.text3, bg))
            let ink: Swatch = plays ? p.title : (row.connected ? p.text : p.text3)
            screen.ink(TerminalText.truncated(row.name, columns: (kind > box.x + 20 ? kind : curve) - box.x - 8), x: box.x + 7, y: ry,
                       t.style(ink, bg, plays || here ? .bold : []))
            if kind > box.x + 20 { screen.ink(Self.transport(row.transport), x: kind, y: ry, t.style(p.text3, bg), limit: curve - kind - 1) }
            let profile = library.profile(row.uid)
            let mark = row.profile == "own" ? library.mark(profile) : nil
            var x = curve
            x += screen.ink(row.profile == "own" ? "own" : "default", x: x, y: ry, t.style(row.profile == "own" ? p.text2 : p.warn, bg))
            if let mark {
                x += screen.ink(" ◆", x: x, y: ry, t.style(p.accent, bg))
                if mark.modified { screen.ink("*", x: x, y: ry, t.style(p.warn, bg, .bold)) }
            }
        }
    }

    private func preview(_ r: Rect, into screen: inout Screen) {
        let library = scene.library
        guard library.rows.indices.contains(scene.lists.device) else {
            Boxes.draw(r, into: &screen, t, border: p.border, title: label("curve"), fill: console ? p.surface : nil)
            return
        }
        let row = library.rows[scene.lists.device]
        let profile = library.profile(row.uid)
        let beside = r.width >= 64
        let side = beside ? 26 : 0
        let lines = Layers.lines(profile, mark: library.mark(profile), t)
        let under = beside ? 0 : min(lines.count, max(r.height - 9, 0))
        let right = row.uid == library.current?.uid ? "plays" : (row.profile == "own" ? "own profile" : "the default profile")
        ResponsePanel(scene: scene).draw(Rect(x: r.x, y: r.y, width: r.width - side, height: r.height - under), title: row.name, right: right,
                                         bands: profile.engineBands, into: &screen)
        if beside {
            let box = Rect(x: r.right - side + 1, y: r.y, width: side - 1, height: r.height)
            Boxes.draw(box, into: &screen, t, border: p.border, title: label("layers"), fill: console ? p.surface : nil)
            Layers.draw(lines, x: box.x + 2, y: box.y + 1, width: box.width - 3, rows: box.height - 2, t, upper: console, into: &screen)
        } else if under > 0 {
            Layers.draw(lines, x: r.x + 2, y: r.bottom - under, width: r.width - 3, rows: under, t, upper: console, into: &screen)
        }
    }
}

/// The current device's parametric filters as a table, the one being added under them; the
/// filters' combined response below, the chosen one's own over it in the accent.
struct FiltersView {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette
    private var console: Bool { scene.settings.look == .console }

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    private var filters: [Filter] { scene.header.profile?.filters ?? [] }

    static func layout(_ size: Size, rows: Int) -> (table: Rect, response: Rect?) {
        let body = Chrome.body(size)
        let wanted = max(rows, 1) + 3
        let room = body.height >= 14 ? body.height - 8 : body.height
        let table = Rect(x: body.x, y: body.y, width: body.width, height: min(wanted, max(room, 0)))
        let rest = body.height - table.height
        return (table, rest >= 6 ? Rect(x: body.x, y: table.bottom, width: body.width, height: rest) : nil)
    }

    static func item(at x: Int, _ y: Int, size: Size, count: Int, selected: Int) -> Int? {
        let table = layout(size, rows: count).table
        let first = table.y + 2
        let visible = max(table.height - 3, 0)
        guard table.inset(by: 1).contains(x: x, y: y), y >= first, y - first < visible else { return nil }
        let index = Lists.offset(selected: selected, visible: visible) + y - first
        return index < count ? index : nil
    }

    /// Where each field's text starts and how wide it is, after `#`.
    private static let columns: [(field: FilterField, x: Int, width: Int)] = [(.type, 7, 9), (.frequency, 18, 9), (.gain, 29, 8), (.q, 39, 5)]

    func draw(into screen: inout Screen) {
        Chrome.top(scene, into: &screen)
        let form = scene.form
        let l = Self.layout(scene.size, rows: filters.count + (form != nil ? 1 : 0))
        table(l.table, into: &screen)
        if let r = l.response {
            let selected = form?.filter ?? (filters.indices.contains(scene.lists.filter) ? filters[scene.lists.filter] : nil)
            let nodes = filters.enumerated().map { (frequency: $0.element.frequency, selected: form == nil && $0.offset == scene.lists.filter) }
                + (form.map { [(frequency: $0.filter.frequency, selected: true)] } ?? [])
            let all = filters + (form.map { [$0.filter] } ?? [])
            ResponsePanel(scene: scene).draw(r, title: "response", right: all.isEmpty ? "no filters" : "filters combined · the chosen one lit",
                                             bands: all.map(Self.band), over: selected.map { [Self.band($0)] }, nodes: nodes, into: &screen)
        }
        Chrome.bottom(scene, into: &screen)
    }

    static func band(_ filter: Filter) -> EQBand { EQBand(type: filter.type, frequency: filter.frequency, gain: filter.gain, q: filter.q) }

    private func table(_ box: Rect, into screen: inout Screen) {
        let imported = scene.header.profile?.imported.flatMap { label in filters.contains { $0.origin == .import } ? label : nil }
        let right = "\(filters.count) of \(Config.maxFilters)" + (imported.map { " · imported: \($0)" } ?? "")
        let device = scene.frame.device.map { " · " + $0 } ?? ""
        Boxes.draw(box, into: &screen, t, border: scene.lists.field != nil || scene.form != nil ? p.borderHi : p.border,
                   title: (console ? "FILTERS" : "filters") + device, right: right, fill: console ? p.surface : nil)
        guard box.height >= 4, box.width >= 50 else { return }
        let heads = ["#", "type", "frequency", "gain", "Q", "source"]
        for (text, x) in zip(heads, [3, 7, 18, 30, 40, 47]) {
            screen.ink(console ? text.uppercased() : text, x: box.x + x, y: box.y + 1, t.style(p.text3))
        }
        let visible = max(box.height - 3, 0)
        let form = scene.form
        guard !filters.isEmpty || form != nil else {
            screen.ink("no filters — a adds one; eq import brings a headphone's correction", x: box.x + 3, y: box.y + 2, t.style(p.text3),
                       limit: box.width - 5)
            return
        }
        let count = filters.count + (form != nil ? 1 : 0)
        let selected = form != nil ? count - 1 : scene.lists.filter
        let first = Lists.offset(selected: selected, visible: visible)
        for i in first..<min(count, first + visible) {
            let y = box.y + 2 + i - first
            let adding = form != nil && i == filters.count
            let filter = adding ? form!.filter : filters[i]
            let here = i == selected
            let bg: Swatch? = here ? p.sel : nil
            if here {
                screen.fill(Rect(x: box.x + 1, y: y, width: box.width - 2, height: 1), with: Cell(" ", style: t.style(nil, p.sel)))
                screen.ink("▸", x: box.x + 1, y: y, t.style(p.accent, bg, .bold))
            }
            screen.ink(adding ? " +" : String(format: "%2d", i + 1), x: box.x + 3, y: y, t.style(adding ? p.accent : p.text3, bg, adding ? .bold : []))
            let editing = adding ? form?.field : (here ? scene.lists.field : nil)
            for column in Self.columns {
                var text = column.field.text(filter)
                if column.field != .type { text = text.leftPadded(to: column.width) }
                let x = box.x + column.x
                if column.field == editing {
                    screen.ink(" " + text + " ", x: x - 1, y: y, t.style(p.onChip, console ? p.capSel : p.accent, .bold, solid: true))
                    continue
                }
                let ink: Swatch
                switch column.field {
                case .type: ink = p.accent
                case .frequency: ink = p.title
                case .gain: ink = FilterField.usesGain(filter.type) ? t.gain(filter.gain) : p.grid
                case .q: ink = p.text2
                }
                screen.ink(text, x: x, y: y, t.style(ink, bg, column.field == .frequency ? .bold : []))
            }
            let source = adding ? "new" : (filter.origin == .import ? "import" : "hand")
            screen.ink(source, x: box.x + 47, y: y, t.style(adding ? p.accent : (filter.origin == .import ? p.accent : p.boost), bg),
                       limit: box.right - 2 - box.x - 47)
        }
    }
}
