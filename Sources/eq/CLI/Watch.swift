import EQTerm
import Foundation

struct WatchLayout: Equatable {
    var columns: Int
    var cellWidth: Int
    var meterRows: Int
    var shortLabels: Bool
    var width: Int
    var zoneRows = 0
    var bracketRows = 0
    /// The message row and the keybar share the bottom row.
    var folded = false

    /// Six rows are fixed: header, live row, labels, gains, the message row and the keybar, so
    /// the frame never scrolls the alternate screen. Below ten rows the meter's four-row floor
    /// and those six do not fit, so the message row folds into the keybar and the meter takes
    /// what is left, down to one row.
    /// Four columns is the floor: at three, neighbouring labels and numbers run together.
    /// The focus bracket and the zone strip take their room from the meter down to its four-row
    /// floor — the bracket first, since it names what the dimmed bars mean — then strip rows drop
    /// from the bottom.
    static func fit(cols: Int, rows: Int, zones: Int = 0, bracket: Bool = false) -> WatchLayout {
        let cellWidth = min(max((cols - 2) / 10, 4), 8)
        let folded = rows < 10
        let bracketRows = bracket && rows >= 11 ? 1 : 0
        let zoneRows = folded ? 0 : min(max(zones, 0), max(rows - 10 - bracketRows, 0))
        return WatchLayout(columns: min(Config.bandLabels.count, max(1, (cols - 2) / cellWidth)),
                           cellWidth: cellWidth,
                           meterRows: folded ? max(1, rows - 5) : max(4, rows - 6 - zoneRows - bracketRows),
                           shortLabels: cellWidth < 6, width: cols, zoneRows: zoneRows, bracketRows: bracketRows, folded: folded)
    }

    /// The rows between the header and the message row, where an overlay draws.
    var bodyRows: Int { bracketRows + meterRows + zoneRows + 3 }

    var visibleColumns: Int { min(max(columns, 1), Config.bandLabels.count) }
    var cell: Int { max(cellWidth, 1) }
    var tableWidth: Int { visibleColumns * cell }
    var barWidth: Int { cell >= 7 ? 3 : (cell >= 5 ? 2 : 1) }

    /// Bars sit right-aligned in their cell, under the right end of the label.
    func barStart(_ band: Int) -> Int { band * cell + cell - barWidth }
    func centre(_ band: Int) -> Int { barStart(band) + (barWidth - 1) / 2 }
}

enum Watch {
    private static let bands = Config.bandLabels.count
    static let floorDB = -60.0
    private static let hotDB = -6.0
    static let partials = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    static func requireTerminal(isTTY: Bool, command: String = "watch") throws {
        guard isTTY else { throw CLIError.usage("eq \(command) needs a terminal") }
    }

    /// Truncates or pads to `n` so a daemon/CLI version skew (a shorter array on the wire)
    /// can't index out of bounds and trap — a trap bypasses every terminal-restore path.
    /// Also sanitizes non-finite elements to `fill`, for the same reason.
    static func padded(_ a: [Double], to n: Int, with fill: Double) -> [Double] {
        let clean = a.map { $0.isFinite ? $0 : fill }
        return clean.count >= n ? Array(clean.prefix(n)) : clean + Array(repeating: fill, count: n - clean.count)
    }

    /// Header, the focus bracket, `meterRows` of bars, up to `zoneRows` of the instrument strip,
    /// the live level row, labels, gains, the message row — the save-as `prompt`, else a `note`,
    /// else, when not every band fits, a note to widen the terminal — and the keybar, which is
    /// always there; folded into one row, only a prompt or a note covers it, and only for a while. With a `focus` the strip shows only that instrument. A `modal` draws over
    /// everything between the header and the message row.
    static func frame(_ f: MeterFrame, layout: WatchLayout, strip: Bool = false, focus: Instrument? = nil,
                      modal: WatchModal? = nil, flash: Int? = nil, note: String? = nil,
                      preset: Table.PresetMark? = nil, preference: Preference? = nil, knobs: [String: Double]? = nil,
                      dynamics: Dynamics? = nil, prompt: TextField? = nil, listening: Bool = false, mouse: Bool = false) -> [String] {
        picture(f, layout: layout, strip: strip, focus: focus, modal: modal, flash: flash, note: note, preset: preset,
                preference: preference, knobs: knobs, dynamics: dynamics, prompt: prompt, listening: listening, mouse: mouse).lines()
    }

    /// `frame` before it becomes text: what the meter view draws as cells.
    static func picture(_ f: MeterFrame, layout: WatchLayout, strip: Bool = false, focus: Instrument? = nil,
                        modal: WatchModal? = nil, flash: Int? = nil, note: String? = nil,
                        preset: Table.PresetMark? = nil, preference: Preference? = nil, knobs: [String: Double]? = nil,
                        dynamics: Dynamics? = nil, prompt: TextField? = nil, listening: Bool = false, mouse: Bool = false) -> MeterPicture {
        let columns = layout.visibleColumns
        let rows = max(layout.meterRows, 1)
        let w = layout.cell
        let stripped = strip ? Array((focus.map { [$0] } ?? Instruments.all).prefix(max(layout.zoneRows, 0))) : []
        let focused = focus.map { Set($0.bands) }
        let outside = Set((0..<columns).filter { band in focused.map { !$0.contains(band) } ?? false })
        let gains = padded(f.gains, to: bands, with: 0).prefix(columns).map { min(max($0, -12), 12) }
        let inLevels = padded(f.in, to: bands, with: floorDB).prefix(columns).map(clampLevel)
        let outLevels = padded(f.out, to: bands, with: floorDB).prefix(columns).map(clampLevel)
        let barInks = (0..<columns).map { outside.contains($0) ? .dim : barInk(gain: gains[$0], level: outLevels[$0]) }

        let tableWidth = layout.tableWidth
        let indent = stripped.isEmpty ? max(layout.width - tableWidth, 0) / 2 : Strip.placement(layout).start
        let title = header(f, layout: layout, tableWidth: tableWidth, preset: preset, preference: preference, knobs: knobs,
                           dynamics: dynamics, focus: focus)
        let margin = String(repeating: " ", count: indent)

        var top: [String] = []
        if let focus, layout.bracketRows > 0 { top.append(margin + Strip.bracket(focus, layout: layout)) }
        let bars = MeterBars(
            margin: indent, pad: max(w - layout.barWidth, 0), barWidth: layout.barWidth, rows: rows,
            markers: gains.map { g in min(max(Int(((12 - g) / 24 * Double(rows - 1)).rounded()), 0), rows - 1) },
            outTops: outLevels.map { height($0, rows: rows) }, inTops: inLevels.map { height($0, rows: rows) },
            barInks: barInks,
            markerInks: (0..<columns).map { outside.contains($0) ? .dim : Paint.level(Paint.gain(gains[$0]), hot: abs(gains[$0]) > 6) })
        let live = (0..<columns).map { i -> String in
            let text = outLevels[i] <= floorDB + 0.5 ? "·" : String(Int(outLevels[i].rounded()))
            // Inside a focus the numbers are what gets tuned against, so they stand out.
            let ink = focus != nil && !outside.contains(i)
                ? (gains[i] == 0 ? .bold : Paint.level(Paint.gain(gains[i]), hot: true)) : barInks[i]
            return paint(ink, text.leftPadded(to: w))
        }.joined()
        let tail = [live, Table.labelsRow(width: w, short: layout.shortLabels, columns: columns, bold: flash, focus: focused),
                    Table.gainsRow(gains, width: w, dimmed: outside)]
        // The header centres with the bars when it fits beside them, and slides left rather than truncate.
        let headerIndent = String(repeating: " ", count: min(indent, max(layout.width - title.plain, 0)))
        var shown: [MeterPicture.Row] = ([headerIndent + title.painted] + top).map { .text($0) }
        shown += (0..<bars.rows).map { .bars($0) }
        shown += stripped.map { .text(Strip.row($0, layout: layout, levels: outLevels, gains: gains, highlighted: focus != nil)) }
        shown += tail.map { .text(margin + $0) }
        let box = modal.flatMap { WatchOverlay.box($0, region: shown.count - 1, width: layout.width, focus: focus, knobs: knobs) }
        let room = max(layout.width - indent, 1)
        var message: String?
        if let prompt {
            message = margin + Paint.ink(.dim, promptLabel) + prompt.display(width: max(room - promptLabel.count, 1))
        } else if let text = note ?? (columns < bands && !layout.folded ? "… widen for all bands" : nil) {
            message = margin + Paint.ink(.dim, TerminalText.prefix(text, columns: room))
        }
        let context: KeyContext = prompt != nil ? .prompt : modal?.context ?? .meter
        let state = KeyState(strip: strip, focused: focus != nil, listening: listening, mouse: mouse)
        let bar = Keybar.line(context, state: state, width: layout.width, compact: layout.folded)
        shown += (layout.folded ? [message ?? bar] : [message ?? "", bar]).map { .text($0) }
        return MeterPicture(rows: shown, bars: bars, box: box)
    }

    /// Splices `text` over `width` visible columns of a painted line: escapes don't take a column,
    /// and the colour running under the box is cut before it and resumed after it.
    static func overlay(_ line: String, _ text: String, at column: Int, width: Int) -> String {
        var head = "", tail = "", active = "", escape = ""
        var visible = 0
        for c in line {
            if !escape.isEmpty || c == "\u{1B}" {
                escape.append(c)
                guard c.isLetter else { continue }
                if visible >= column + width { tail += escape } else if visible < column { head += escape }
                if visible < column + width { active = escape == "\u{1B}[0m" ? "" : escape }
                escape = ""
                continue
            }
            if visible < column { head.append(c) } else if visible >= column + width { tail.append(c) }
            visible += 1
        }
        head += String(repeating: " ", count: max(column - visible, 0))
        let reset = Paint.enabled ? "\u{1B}[0m" : ""
        return head + reset + text + (tail.isEmpty ? "" : active + tail)
    }

    /// A flat band has no colour of its own; a loud one still has to stand out from dim.
    static func barInk(gain: Double, level: Double) -> Paint.Ink? {
        let hot = level >= hotDB
        if gain == 0 { return hot ? nil : .dim }
        return Paint.level(Paint.gain(gain), hot: hot)
    }

    private static func clampLevel(_ db: Double) -> Double {
        min(max(db, floorDB), 99)
    }

    /// How many meter rows a level fills, fractional, capped at the meter's height.
    private static func height(_ db: Double, rows: Int) -> Double {
        min(max((db - floorDB) / -floorDB * Double(rows), 0), Double(rows))
    }

    private static func paint(_ ink: Paint.Ink?, _ text: String) -> String {
        ink.map { Paint.ink($0, text) } ?? text
    }

    static let promptLabel = "save as: "

    static func focusText(_ instrument: Instrument) -> String {
        let span = instrument.outerSpan
        return "focus: \(instrument.name) (\(InstrumentTable.hz(span.low, gap: " "))–\(InstrumentTable.hz(span.high, gap: " ")))"
    }

    /// Segments drop from the right until the line fits, then the flags, then the focus: the
    /// flags explain a surprising sound, and the focus explains why most bars went dim.
    private static func header(_ f: MeterFrame, layout: WatchLayout, tableWidth: Int,
                               preset: Table.PresetMark?, preference: Preference?, knobs: [String: Double]?,
                               dynamics: Dynamics?, focus: Instrument?) -> (plain: Int, painted: String) {
        let cols = max(layout.width, 1)
        let device = f.device ?? "no device"
        let rate = f.rate.isFinite ? String(format: "%.1f", f.rate / 1000) : "?"
        let preamp = f.preamp.isFinite ? Table.gain(f.preamp) : "?"
        let peak = f.peak.isFinite ? Table.gain(f.peak) : "?"
        var segments: [(plain: String, painted: String)] = [
            (device, Paint.ink(.bold, device)),
            ("\(rate) kHz", "\(rate) kHz"),
            ("preamp \(preamp) dB", "preamp \(Paint.ink(Paint.gain(f.preamp), preamp)) dB"),
        ]
        // While an app rule plays, the device's preset and layers are not what you hear, so they step aside.
        if let app = f.app {
            segments.append(("app: \(app.label)", "app: " + Paint.ink(.bold, app.name) + " → " + Paint.ink(.cyan, app.preset)))
        } else if let preset {
            segments.append((preset.name + (preset.modified ? "*" : ""), Table.presetLabel(preset)))
        }
        if f.app == nil, let preference {
            let parts = [("bass", preference.bass), ("treble", preference.treble), ("tilt", preference.tilt)].filter { $0.1 != 0 }
            if !parts.isEmpty {
                segments.append((parts.map { "\($0.0) \(String(format: "%+g", $0.1))" }.joined(separator: " "),
                                 parts.map { "\($0.0) " + Paint.ink(Paint.gain($0.1), String(format: "%+g", $0.1)) }.joined(separator: " ")))
            }
        }
        // The focused knob shows at 0 too, so the first arrow press has a number to move.
        let turned = Instruments.all.compactMap { instrument -> (String, Double)? in
            let gain = knobs?[instrument.name] ?? 0
            return gain != 0 || instrument == focus ? (instrument.name, gain) : nil
        }
        if f.app == nil, !turned.isEmpty {
            segments.append((turned.map { "\($0.0) \(String(format: "%+.1f", $0.1))" }.joined(separator: " "),
                             turned.map { "\($0.0) " + Paint.ink(Paint.gain($0.1), String(format: "%+.1f", $0.1)) }.joined(separator: " ")))
        }
        if let mode = dynamics?.comp {
            // The daemon's live reduction; without it (an older daemon) only the mode shows.
            let reduction = f.comp.flatMap { $0.isFinite ? String(format: "%.1f", $0 == 0 ? 0 : $0) : nil }
            let plain = "\(mode.rawValue) comp" + (reduction.map { " " + $0 } ?? "")
            segments.append((plain, Paint.ink(.cyan, mode.rawValue) + " comp" + (reduction.map { " " + Paint.ink(.yellow, $0) } ?? "")))
        }
        if let colour = dynamics?.color {
            let amount = String(format: "%g", colour.amount)
            segments.append(("\(colour.kind.rawValue) \(amount)", Paint.ink(.cyan, colour.kind.rawValue) + " " + amount))
        }
        segments.append(("peak \(peak) dB", "peak \(peak) dB"))
        var focusSegment = focus.map { instrument -> (plain: String, painted: String) in
            let text = focusText(instrument)
            return (text, text.replacingOccurrences(of: instrument.name, with: Paint.ink(.bold, instrument.name)))
        }
        var flags: [(plain: String, painted: String)] = []
        if f.solo != nil { flags.append(("SOLO", Paint.ink(.brightYellow, "SOLO"))) }
        if !f.enabled { flags.append(("BYPASS", Paint.ink(.yellow, "BYPASS"))) }
        if f.limiting { flags.append(("LIMIT", Paint.ink(.yellow, "LIMIT"))) }

        func compose() -> (plain: Int, painted: String) {
            let shown = segments + (focusSegment.map { [$0] } ?? [])
            var plain = shown.map(\.plain).joined(separator: " · ")
            var painted = shown.map(\.painted).joined(separator: " · ")
            for flag in flags {
                // LIMIT sits at the right edge of the bars, where the eye already is.
                let gap = flag.plain == "LIMIT" ? max(1, tableWidth - flag.plain.count - TerminalText.width(plain)) : 1
                plain += String(repeating: " ", count: gap) + flag.plain
                painted += String(repeating: " ", count: gap) + flag.painted
            }
            return (TerminalText.width(plain), painted)
        }
        while compose().plain > cols, segments.count > 1 { segments.removeLast() }
        while compose().plain > cols, !flags.isEmpty { flags.removeLast() }
        if compose().plain > cols { focusSegment = nil }
        if compose().plain > cols {
            let cut = TerminalText.prefix(device, columns: cols)
            return (TerminalText.width(cut), Paint.ink(.bold, cut))
        }
        return compose()
    }

    /// Frame counts at the daemon's 30 frames a second.
    static let flashFrames = 15
    static let noteFrames = 60
    static let markFrames = 30

    /// The line `l` sends over the meter socket; `nil` asks the daemon to stop soloing.
    static func soloRequest(_ range: HzRange?) -> String {
        guard let range else { return #"{"solo":null}"# }
        func number(_ v: Double) -> String { v.rounded() == v && abs(v) < 1e15 ? String(Int(v)) : String(v) }
        return #"{"solo":{"low":\#(number(range.low)),"high":\#(number(range.high))}}"#
    }

    static func outsideNote(_ instrument: Instrument) -> String { "outside \(instrument.name) — Esc to unfocus" }
    static let listenNeedsFocus = "focus an instrument first — [ ] or Tab"
    static let paletteNote = "the command palette is not here yet — ? lists every key"
    static func cannotListen(_ instrument: Instrument) -> String { "can't listen to \(instrument.name) at this rate" }
    static let listenFailed = "listen: the daemon did not take the request"
    static let reconnecting = "daemon gone — reconnecting"

    /// What the header shows of the current device's profile beside the meters.
    struct Header {
        var preset: Table.PresetMark?
        var preference: Preference?
        var knobs: [String: Double]?
        var dynamics: Dynamics?
        var mouse = false
    }
}

/// An overlay the watch draws over the meter until it is closed.
enum WatchModal: Equatable {
    case help(scroll: Int), instruments(scroll: Int)

    var context: KeyContext {
        switch self {
        case .help: return .help
        case .instruments: return .instruments
        }
    }

    var scroll: Int {
        switch self {
        case .help(let scroll), .instruments(let scroll): return scroll
        }
    }

    /// Stops where the last line comes into view, so ↑ answers at once after too many ↓.
    func scrolled(by delta: Int, layout: WatchLayout) -> WatchModal {
        let lines = WatchOverlay.lines(self, focus: nil, knobs: nil).count
        let visible = max(min(lines + 2, layout.bodyRows) - 2, 1)
        let next = min(max(scroll + delta, 0), max(lines - visible, 0))
        switch self {
        case .help: return .help(scroll: next)
        case .instruments: return .instruments(scroll: next)
        }
    }
}

enum WatchOverlay {
    typealias Line = (plain: String, painted: String)

    static func lines(_ modal: WatchModal, focus: Instrument?, knobs: [String: Double]?) -> [Line] {
        switch modal {
        case .help: return helpLines()
        case .instruments: return instrumentLines(focus: focus, knobs: knobs)
        }
    }

    private static func helpLines() -> [Line] {
        let entries = KeyHelp.lines()
        let keyWidth = entries.filter { !$0.text.isEmpty }.map { TerminalText.width($0.key) }.max() ?? 0
        return entries.map { entry in
            if entry.text.isEmpty { return (entry.key, Paint.ink(.bold, entry.key)) }
            let key = entry.key + String(repeating: " ", count: max(keyWidth - TerminalText.width(entry.key), 0))
            return (key + "  " + entry.text, Paint.ink(.cyan, key) + "  " + entry.text)
        }
    }

    /// What `eq zones` and `eq boost` list, one row per range: the instrument and its knob on the
    /// first, the character range (the one the knob turns and `l` solos) in bold.
    private static func instrumentLines(focus: Instrument?, knobs: [String: Double]?) -> [Line] {
        let nameWidth = Instruments.all.map(\.name.count).max() ?? 0
        let rangeWidth = Instruments.all.flatMap { $0.ranges.map { InstrumentTable.rangeText($0).count } }.max() ?? 0
        let head = "  " + "".padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  knob  "
            + "range".padding(toLength: rangeWidth, withPad: " ", startingAt: 0) + "  bands"
        var result: [Line] = [(head, Paint.ink(.dim, head))]
        for instrument in Instruments.all {
            let gain = knobs?[instrument.name] ?? 0
            for (index, range) in instrument.ranges.enumerated() {
                let first = index == 0
                let marker = first && instrument == focus ? "▸ " : "  "
                let name = (first ? instrument.name : "").padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                let knob = first ? String(format: "%+.1f", gain) : "    "
                let rangeText = InstrumentTable.rangeText(range).padding(toLength: rangeWidth, withPad: " ", startingAt: 0)
                let bands = InstrumentTable.bandsText(range)
                let plain = marker + name + "  " + knob + "  " + rangeText + "  " + bands
                let painted = marker + (first ? Paint.ink(.bold, name) : name) + "  "
                    + (first ? Paint.ink(Paint.gain(gain), knob) : knob) + "  "
                    + (range.name == instrument.character ? Paint.ink(.bold, rangeText) : rangeText) + "  " + Paint.ink(.dim, bands)
                result.append((plain, painted))
            }
        }
        return result
    }

    struct Box {
        var rows: [String]
        var column: Int
        var top: Int
        var width: Int
    }

    /// A box centred over the `region` rows under the header, which stays visible above it.
    /// Lines wider than the box are cut with `…`; when not all fit, the bottom border says which
    /// part shows. Nil when the region is too small for one.
    static func box(_ modal: WatchModal, region: Int, width: Int, focus: Instrument?, knobs: [String: Double]?) -> Box? {
        let content = self.lines(modal, focus: focus, knobs: knobs)
        let title: String
        switch modal {
        case .help: title = "keys"
        case .instruments: title = "instruments"
        }
        let boxWidth = min(width, (content.map { TerminalText.width($0.plain) }.max() ?? 0) + 4)
        guard region >= 3, boxWidth >= title.count + 6 else { return nil }
        let height = min(content.count + 2, region)
        let visible = height - 2
        let start = min(max(modal.scroll, 0), max(content.count - visible, 0))
        let inner = boxWidth - 4
        let border = { (text: String) in Paint.ink(.dim, text) }
        var rows = [border("┌ ") + title + border(" " + String(repeating: "─", count: max(boxWidth - title.count - 4, 0)) + "┐")]
        for line in content[start..<min(start + visible, content.count)] {
            let fits = TerminalText.width(line.plain) <= inner
            let plain = fits ? line.plain : TerminalText.prefix(line.plain, columns: inner - 1) + "…"
            let text = fits ? line.painted : plain
            rows.append(border("│ ") + text + String(repeating: " ", count: max(inner - TerminalText.width(plain), 0)) + border(" │"))
        }
        let position = content.count > visible ? " \(start + 1)–\(start + visible) of \(content.count) " : ""
        let dashes = max(boxWidth - 2 - position.count, 0)
        rows.append(border("└" + String(repeating: "─", count: dashes / 2) + position + String(repeating: "─", count: dashes - dashes / 2) + "┘"))
        return Box(rows: rows, column: max((width - boxWidth) / 2, 0), top: 1 + max((region - height) / 2, 0), width: boxWidth)
    }
}

/// One meter frame before it becomes text or cells: the rows around the bars as painted lines,
/// the bars as numbers, the overlay box on top. `lines` is what `Watch.frame` returns and the
/// golden files hold; `draw` puts the same on a screen without going through text for the bars.
struct MeterPicture {
    enum Row {
        case text(String)
        /// A meter row, 0 at the top.
        case bars(Int)
    }

    var rows: [Row]
    var bars: MeterBars
    var box: WatchOverlay.Box?

    func lines() -> [String] {
        var lines = rows.map { row -> String in
            switch row {
            case .text(let text): return text
            case .bars(let r): return bars.line(r)
            }
        }
        if let box {
            for (i, row) in box.rows.enumerated() {
                lines[box.top + i] = Watch.overlay(lines[box.top + i], row, at: box.column, width: box.width)
            }
        }
        return lines
    }

    func draw(into screen: inout Screen) {
        let styles = bars.styles()
        for (y, row) in rows.enumerated() {
            switch row {
            case .text(let text): AnsiText.draw(text, into: &screen, x: 0, y: y)
            case .bars(let r): bars.draw(r, y: y, styles: styles, into: &screen)
            }
        }
        if let box {
            for (i, row) in box.rows.enumerated() { AnsiText.draw(row, into: &screen, x: box.column, y: box.top + i, limit: box.width) }
        }
    }
}

/// The bars of one frame: each band's slider marker row, level and input ghost, in meter rows.
struct MeterBars {
    var margin: Int
    var pad: Int
    var barWidth: Int
    var rows: Int
    var markers: [Int]
    var outTops: [Double]
    var inTops: [Double]
    var barInks: [Paint.Ink?]
    var markerInks: [Paint.Ink]

    /// What band `i` shows on meter row `r`: the marker wins over a partial top, since where the
    /// slider sits matters more than an eighth of a row.
    func glyph(_ r: Int, band i: Int) -> (glyph: String, ink: Paint.Ink?)? {
        if r == markers[i] { return ("▬", markerInks[i]) }
        let b = rows - 1 - r
        let full = Int(outTops[i])
        let fraction = outTops[i] - Double(full)
        if b < full { return ("█", barInks[i]) }
        if b == full, fraction > 0 { return (Watch.partials[min(Int(fraction * 8), Watch.partials.count - 1)], barInks[i]) }
        if Double(b) < inTops[i] { return ("░", .dim) }
        return nil
    }

    func line(_ r: Int) -> String {
        var line = String(repeating: " ", count: margin)
        let gap = String(repeating: " ", count: pad)
        for i in markers.indices {
            line += gap
            guard let shown = glyph(r, band: i) else {
                line += String(repeating: " ", count: barWidth)
                continue
            }
            let text = String(repeating: shown.glyph, count: barWidth)
            line += shown.ink.map { Paint.ink($0, text) } ?? text
        }
        return line
    }

    struct Styles {
        var bars: [Style]
        var markers: [Style]
        var ghost: Style
    }

    /// Asked once a frame: whether colour is on is a `getenv` and an `isatty` away.
    func styles() -> Styles {
        let on = Paint.enabled
        return Styles(bars: barInks.map { Paint.style($0, on: on) }, markers: markerInks.map { Paint.style($0, on: on) },
                      ghost: Paint.style(.dim, on: on))
    }

    func draw(_ r: Int, y: Int, styles: Styles, into screen: inout Screen) {
        for i in markers.indices {
            guard let shown = glyph(r, band: i) else { continue }
            let style = shown.glyph == "▬" ? styles.markers[i] : (shown.glyph == "░" ? styles.ghost : styles.bars[i])
            let x = margin + i * (pad + barWidth) + pad
            for dx in 0..<barWidth { screen.set(x + dx, y, Cell(shown.glyph, style: style)) }
        }
    }
}
