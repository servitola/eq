import EQTerm
import Foundation

/// The top row: the device as a chip, then rate, preamp, preset or app, knobs, tone, compressor,
/// colour and focus as segments that drop from the right to fit; peak and the flags at the right.
struct StatusBar {
    let scene: MeterScene

    private typealias Run = (text: String, ink: Swatch, attributes: Style.Attributes)
    private typealias Segment = [Run]
    private static let no = Style.Attributes()

    private var t: Theme { scene.theme }
    private var p: Palette { t.p }
    private var f: MeterFrame { scene.frame }

    private var rate: String { f.rate.isFinite ? String(format: "%.1f", f.rate / 1000) : "?" }
    private var device: String { f.device ?? "no device" }

    /// The focused knob shows at 0 too, so the first arrow press has a number to move.
    private var knobs: [(Instrument, Double)] {
        Instruments.all.compactMap { instrument in
            let gain = scene.header.knobs?[instrument.name] ?? 0
            return gain != 0 || instrument == scene.focus ? (instrument, gain) : nil
        }
    }

    private var tone: [(String, Double)] {
        guard f.app == nil, let preference = scene.header.preference else { return [] }
        return [("bass", preference.bass), ("treble", preference.treble), ("tilt", preference.tilt)].filter { $0.1 != 0 }
    }

    private var segments: [Segment] {
        var result: [Segment] = [[(rate + " kHz", p.text2, Self.no)]]
        let preamp = f.preamp.isFinite ? Table.gain(f.preamp) : "?"
        result.append([("preamp ", p.text3, Self.no), (preamp, t.gain(f.preamp), Self.no), (" dB", p.text3, Self.no)])
        // While an app rule plays, the device's preset and layers are not what you hear, so they step aside.
        if let app = f.app {
            result.append([("app: ", p.text3, Self.no), (app.name, p.title, .bold), (" → ", p.text3, Self.no), (app.preset, p.accent, Self.no)])
        } else if let preset = scene.header.preset {
            result.append([("◆ ", p.accent, Self.no), (preset.name, p.text, .bold)] + (preset.modified ? [("*", p.warn, .bold)] : []))
        }
        if f.app == nil, !knobs.isEmpty {
            result.append(knobs.enumerated().flatMap { i, knob -> Segment in
                [((i > 0 ? " " : "") + "● ", t.hue(knob.0), Self.no), (knob.0.name + " ", p.text, Self.no), (Table.gain(knob.1), t.gain(knob.1), Self.no)]
            })
        }
        if !tone.isEmpty {
            result.append(tone.enumerated().flatMap { i, part -> Segment in
                [((i > 0 ? " " : "") + part.0 + " ", p.text3, Self.no), (String(format: "%+g", part.1), t.gain(part.1), Self.no)]
            })
        }
        if let mode = scene.header.dynamics?.comp {
            // The daemon's live reduction; without it (an older daemon) only the mode shows.
            let reduction = scene.live ? f.comp.flatMap { $0.isFinite ? String(format: "%.1f", $0 == 0 ? 0 : $0) : nil } : nil
            result.append([(mode.rawValue, p.accent, Self.no), (" comp", p.text3, Self.no)] + (reduction.map { [(" " + $0, p.warn, Self.no)] } ?? []))
        }
        if let colour = scene.header.dynamics?.color {
            result.append([(colour.kind.rawValue, p.accent, Self.no), (" " + String(format: "%g", colour.amount), p.text2, Self.no)])
        }
        return result
    }

    private var focusSegment: Segment? {
        scene.focus.map { instrument in
            let span = instrument.outerSpan
            let range = " (\(InstrumentTable.hz(span.low, gap: " "))–\(InstrumentTable.hz(span.high, gap: " ")))"
            return [("focus: ", p.text3, Self.no), (instrument.name, t.hue(instrument), .bold), (range, p.text2, Self.no)]
        }
    }

    private var flags: [(String, Swatch)] {
        var flags: [(String, Swatch)] = []
        if f.solo != nil { flags.append(("SOLO", p.solo)) }
        if !f.enabled { flags.append(("BYPASS", p.warn)) }
        if scene.limiting { flags.append(("LIMIT", p.danger)) }
        return flags
    }

    private static func width(_ segment: Segment) -> Int { segment.reduce(0) { $0 + TerminalText.width($1.text) } }

    func studio(into screen: inout Screen, width: Int) {
        let status = t.style(nil, p.status)
        screen.fill(Rect(x: 0, y: 0, width: width, height: 1), with: Cell(" ", style: status))
        var segments = self.segments
        var flags = self.flags
        var focus = focusSegment
        var peak = scene.live
        let peakText = f.peak.isFinite ? Table.gain(f.peak) : "?"
        let head = " ◉ " + device + " "
        func right() -> Int { (peak ? 6 + TerminalText.width(peakText) + 4 : 0) + flags.reduce(0) { $0 + $1.0.count + 3 } }
        func left() -> Int {
            TerminalText.width(head) + (segments + (focus.map { [$0] } ?? [])).reduce(0) { $0 + Self.width($1) + 3 }
        }
        while left() + right() > width, !segments.isEmpty { segments.removeLast() }
        if left() + right() > width { peak = false }
        while left() + right() > width, !flags.isEmpty { flags.removeLast() }
        if left() + right() > width { focus = nil }
        var x = screen.ink(" ◉ ", x: 0, y: 0, t.style(p.accent, p.chipHi, solid: true))
        x += screen.ink(TerminalText.prefix(device + " ", columns: max(width - x, 0)), x: x, y: 0,
                        t.style(p.title, p.chipHi, .bold, solid: true))
        for (i, segment) in (segments + (focus.map { [$0] } ?? [])).enumerated() {
            x += screen.ink(i == 0 ? " " : " │ ", x: x, y: 0, t.style(p.border))
            for run in segment { x += screen.ink(run.text, x: x, y: 0, t.style(run.ink, nil, run.attributes)) }
        }
        var rx = width - right()
        if peak {
            rx += screen.ink(" peak ", x: rx, y: 0, t.style(p.text3))
            rx += screen.ink(peakText, x: rx, y: 0, t.style(t.level(f.peak)))
            rx += screen.ink(" dB ", x: rx, y: 0, t.style(p.text3))
        }
        for (flag, ink) in flags {
            rx += screen.ink(" \(flag) ", x: rx, y: 0, t.style(p.onChip, ink, .bold, solid: true)) + 1
        }
    }

    /// Engraved upper-case labels, and three lamps that are always there and light up.
    func console(into screen: inout Screen, width: Int) {
        screen.fill(Rect(x: 0, y: 0, width: width, height: 1), with: Cell(" ", style: t.style(nil, p.status)))
        let lamps: [(String, Bool, Swatch)] = [("SOLO", f.solo != nil, p.solo), ("BYPASS", !f.enabled, p.warn), ("LIMIT", scene.limiting, p.danger)]
        let lampsWidth = lamps.reduce(0) { $0 + $1.0.count + 4 }
        var labels: [(String, String, Swatch, Style.Attributes)] = [("DEVICE", device, p.title, .bold), ("RATE", rate + "k", p.text, .bold)]
        if let app = f.app {
            labels.append(("APP", app.name + " → " + app.preset, p.title, .bold))
        } else if let preset = scene.header.preset {
            labels.append(("PRESET", preset.name + (preset.modified ? "*" : ""), p.title, .bold))
        }
        if let focus = scene.focus { labels.append(("FOCUS", focus.name.uppercased(), t.hue(focus), .bold)) }
        for (instrument, gain) in knobs where f.app == nil {
            labels.append((instrument.name.uppercased(), Table.gain(gain), t.gain(gain), .bold))
        }
        var x = 1
        for (label, value, ink, attributes) in labels {
            let need = label.count + 1 + TerminalText.width(value) + 3
            guard x + need <= width - lampsWidth else { break }
            x += screen.ink(label + " ", x: x, y: 0, t.style(p.text3))
            x += screen.ink(value, x: x, y: 0, t.style(ink, nil, attributes)) + 3
        }
        guard width >= lampsWidth else { return }
        var rx = width - lampsWidth
        for (name, on, ink) in lamps {
            screen.ink("●", x: rx, y: 0, t.style(on ? ink : p.lampOff))
            screen.ink(name, x: rx + 2, y: 0, t.style(on ? p.title : p.text3, nil, on ? .bold : []))
            rx += name.count + 4
        }
    }
}

/// The message row and the keybar under every view.
struct ShellRows {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    func draw(messageY: Int?, keybarY: Int, x: Int, widen: Bool, into screen: inout Screen) {
        let width = scene.size.cols
        let room = max(width - x, 1)
        var said = false
        let y = messageY ?? keybarY
        if let (label, field) = field {
            let used = screen.ink(label, x: x, y: y, t.style(scene.palette != nil ? p.accent : p.text3, nil, scene.palette != nil ? .bold : []))
            screen.ink(field.display(width: max(room - used, 1)), x: x + used, y: y, t.style(p.text))
            said = true
        } else if let message = scene.message {
            let (mark, ink): (String, Swatch?) = {
                switch message.kind {
                case .ok: return ("✓ ", p.ok)
                case .warn: return ("! ", p.warn)
                case .error: return ("✗ ", p.danger)
                case .plain: return ("", nil)
                }
            }()
            let used = mark.isEmpty ? 0 : screen.ink(mark, x: x, y: y, t.style(ink, nil, .bold))
            screen.ink(TerminalText.prefix(message.text, columns: max(room - used, 0)), x: x + used, y: y, t.style(fadingText))
            said = true
        } else if widen, messageY != nil {
            screen.ink(TerminalText.prefix("… widen for all bands", columns: room), x: x, y: y, t.style(p.text3))
        }
        guard messageY != nil || !said else { return }
        keybar(y: keybarY, compact: messageY == nil, into: &screen)
    }

    /// The text field the message row holds: save as, the palette's line, the events filter.
    private var field: (String, TextField)? {
        if let prompt = scene.prompt { return (Watch.promptLabel, prompt) }
        if let entry = scene.entry { return (scene.tune.selected.prompt, entry) }
        if let palette = scene.palette { return (": ", palette.field) }
        if let filter = scene.filterField { return ("filter: ", filter) }
        return nil
    }

    /// The last `fadeFrames` of a message step from `text2` to `text3` in three steps.
    private var fadingText: Swatch {
        let left = scene.messageLeft
        guard left < MeterScene.fadeFrames else { return p.text2 }
        let step = Double(3 - left * 3 / MeterScene.fadeFrames) / 3
        return p.text2.mixed(toward: p.text3, step).with(sgr: nil, [])
    }

    private func keybar(y: Int, compact: Bool, into screen: inout Screen) {
        let entries = Keybar.entries(scene.keyContext, state: scene.keyState, width: scene.size.cols, compact: compact,
                                     extra: Keybar.keycapPadding)
        var x = 0
        for (i, entry) in entries.enumerated() {
            if i > 0 { x += screen.ink(Keybar.separator, x: x, y: y, t.style(p.text3)) }
            x += screen.ink(" " + entry.key + " ", x: x, y: y, t.style(p.keyFg, p.keyBg, .bold))
            x += screen.ink(" " + entry.text, x: x, y: y, t.style(p.text3))
        }
    }
}

/// Output, dynamics, tone and knobs as rounded boxes of gauges beside the studio meter.
struct SideColumn {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    func draw(_ r: Rect, into screen: inout Screen) {
        let w = r.width
        var y = r.y
        let bottom = r.bottom
        let x = r.x
        if y + 4 <= bottom {
            Boxes.draw(Rect(x: x, y: y, width: w, height: 4), into: &screen, t, border: p.border, title: "output")
            screen.ink("peak ", x: x + 2, y: y + 1, t.style(p.text3))
            let gw = w - 14
            let peak = scene.frame.peak.isFinite ? scene.frame.peak : Watch.floorDB
            let lit = Int((min(max(peak, Watch.floorDB), 0) - Watch.floorDB) / -Watch.floorDB * Double(gw))
            for i in 0..<gw {
                let db = Watch.floorDB + (Double(i) + 0.5) / Double(gw) * -Watch.floorDB
                screen.ink(i < lit ? "█" : "·", x: x + 7 + i, y: y + 1, t.style(i < lit ? t.level(db) : p.grid))
            }
            if let held = scene.outputPeak {
                let at = Int((min(max(held, Watch.floorDB), 0) - Watch.floorDB) / -Watch.floorDB * Double(gw))
                if at < gw { screen.ink("▏", x: x + 7 + at, y: y + 1, t.style(p.title)) }
            }
            screen.ink(String(format: "%5.1f", peak), x: x + w - 6, y: y + 1, t.style(p.text))
            screen.ink("limit ", x: x + 2, y: y + 2, t.style(p.text3))
            screen.ink("●", x: x + 8, y: y + 2, t.style(scene.limiting ? p.danger : p.grid))
            screen.ink(scene.limiting ? "limiting" : "idle", x: x + 10, y: y + 2, t.style(scene.limiting ? p.danger : p.text3))
            y += 4
        }
        if y + 5 <= bottom {
            Boxes.draw(Rect(x: x, y: y, width: w, height: 5), into: &screen, t, border: p.border, title: "dynamics")
            let dynamics = scene.header.dynamics
            screen.ink("comp", x: x + 2, y: y + 1, t.style(p.text3))
            screen.ink(dynamics?.comp?.rawValue ?? "off", x: x + 8, y: y + 1,
                       dynamics?.comp == nil ? t.style(p.text3) : t.style(p.accent, nil, .bold))
            screen.ink("GR", x: x + 2, y: y + 2, t.style(p.text3))
            let reduction = scene.frame.comp.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let gw = w - 15
            let n = Int((min(abs(reduction), 12) / 12 * Double(gw)).rounded())
            screen.ink(String(repeating: "·", count: gw - n), x: x + 8, y: y + 2, t.style(p.grid))
            screen.ink(String(repeating: "█", count: n), x: x + 8 + gw - n, y: y + 2, t.style(p.warn))
            screen.ink(String(format: "%5.1f", reduction == 0 ? 0 : reduction), x: x + w - 6, y: y + 2, t.style(p.warn))
            screen.ink("colour", x: x + 2, y: y + 3, t.style(p.text3))
            if let colour = dynamics?.color {
                screen.ink(colour.kind.rawValue, x: x + 9, y: y + 3, t.style(p.accent, nil, .bold))
                gauge(x: x + 14, y: y + 3, width: w - 21, fraction: colour.amount, into: &screen)
                screen.ink(String(format: "%4.1f", colour.amount), x: x + w - 5, y: y + 3, t.style(p.text))
            } else {
                screen.ink("off", x: x + 9, y: y + 3, t.style(p.text3))
            }
            y += 5
        }
        let preference = scene.header.preference ?? Preference()
        if y + 5 <= bottom {
            Boxes.draw(Rect(x: x, y: y, width: w, height: 5), into: &screen, t, border: p.border, title: "tone")
            for (i, part) in [("bass", preference.bass), ("treble", preference.treble), ("tilt", preference.tilt)].enumerated() {
                screen.ink(part.0, x: x + 2, y: y + 1 + i, t.style(p.text3))
                Gauges.bipolar(x: x + 9, y: y + 1 + i, width: w - 17, value: part.1, span: 6, t, into: &screen)
                screen.ink(MeterScene.gainText(part.1).leftPadded(to: 5), x: x + w - 6, y: y + 1 + i, t.style(t.gain(part.1)))
            }
            y += 5
        }
        let rows = min(Instruments.all.count, bottom - y - 2)
        guard rows > 0 else { return }
        Boxes.draw(Rect(x: x, y: y, width: w, height: rows + 2), into: &screen, t, border: scene.focus != nil ? p.borderHi : p.border,
                   title: "knobs")
        for (i, instrument) in Instruments.all.prefix(rows).enumerated() {
            let value = scene.header.knobs?[instrument.name] ?? 0
            let focused = scene.focus == instrument
            let ry = y + 1 + i
            if focused { screen.fill(Rect(x: x + 1, y: ry, width: w - 2, height: 1), with: Cell(" ", style: t.style(nil, p.sel))) }
            screen.ink("●", x: x + 2, y: ry, t.style(t.hue(instrument)))
            screen.ink(instrument.name, x: x + 4, y: ry, t.style(focused || value != 0 ? p.title : p.text2, nil, focused ? .bold : []))
            Gauges.bipolar(x: x + 12, y: ry, width: w - 20, value: value, span: 12, t, into: &screen)
            screen.ink(MeterScene.gainText(value).leftPadded(to: 5), x: x + w - 6, y: ry, t.style(t.gain(value)))
        }
    }

    private func gauge(x: Int, y: Int, width: Int, fraction: Double, into screen: inout Screen) {
        guard width > 0 else { return }
        let cells = min(max(fraction, 0), 1) * Double(width)
        let full = Int(cells)
        let part = Array(" ▏▎▍▌▋▊▉")[min(Int((cells - Double(full)) * 8), 7)]
        screen.ink(String(repeating: "█", count: full), x: x, y: y, t.style(p.accent))
        guard full < width else { return }
        screen.ink(part == " " ? "·" : String(part), x: x + full, y: y, t.style(part == " " ? p.grid : p.accent))
        screen.ink(String(repeating: "·", count: width - full - 1), x: x + full + 1, y: y, t.style(p.grid))
    }
}

enum Gauges {
    /// A centre tick, a bar from the centre toward the value, a dot at the value: `┄┄┼━━●┄`.
    static func bipolar(x: Int, y: Int, width: Int, value: Double, span: Double, _ t: Theme, into screen: inout Screen) {
        guard width >= 3 else { return }
        let half = width / 2
        screen.ink(String(repeating: "┄", count: width), x: x, y: y, t.style(t.p.grid))
        screen.ink("┼", x: x + half, y: y, t.style(t.p.borderHi))
        let n = min(Int((abs(value) / span * Double(half)).rounded()), value > 0 ? width - 1 - half : half)
        guard value != 0, value.isFinite else { return }
        let ink = t.style(t.gain(value))
        guard n > 0 else {
            screen.ink("●", x: x + half, y: y, ink)
            return
        }
        if value > 0 {
            screen.ink(String(repeating: "━", count: n - 1), x: x + half + 1, y: y, ink)
            screen.ink("●", x: x + half + n, y: y, ink)
        } else {
            screen.ink(String(repeating: "━", count: n - 1), x: x + half - n + 1, y: y, ink)
            screen.ink("●", x: x + half - n, y: y, ink)
        }
    }
}
