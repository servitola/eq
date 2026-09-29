import Darwin
import Foundation

protocol MeterSource {
    /// Returns whether the source ended because its peer closed the connection (EOF), as
    /// opposed to `handle` returning false or `maxLines` being reached.
    func lines(maxLines: Int?, handle: (String) -> Bool) -> Bool
}

extension MeterClient: MeterSource {}

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
    static let enter = "\u{1B}[?1049h\u{1B}[?25l"
    /// Mouse reporting goes off too: `m` may have turned it on.
    static let leave = "\u{1B}[?1000l\u{1B}[?1006l\u{1B}[?25h\u{1B}[?1049l"
    /// Button presses and the wheel, in SGR form (1006), which never sends raw bytes above 127.
    static let mouseOn = "\u{1B}[?1000h\u{1B}[?1006h"
    static let mouseOff = "\u{1B}[?1000l\u{1B}[?1006l"
    private static let bands = Config.bandLabels.count
    static let floorDB = -60.0
    private static let hotDB = -6.0
    private static let partials = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

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
                      dynamics: Dynamics? = nil, prompt: String? = nil, listening: Bool = false, mouse: Bool = false) -> [String] {
        let columns = layout.visibleColumns
        let rows = max(layout.meterRows, 1)
        let w = layout.cell
        let stripped = strip ? Array((focus.map { [$0] } ?? Instruments.all).prefix(max(layout.zoneRows, 0))) : []
        let focused = focus.map { Set($0.bands) }
        let outside = Set((0..<columns).filter { band in focused.map { !$0.contains(band) } ?? false })
        let gains = padded(f.gains, to: bands, with: 0).prefix(columns).map { min(max($0, -12), 12) }
        let inLevels = padded(f.in, to: bands, with: floorDB).prefix(columns).map(clampLevel)
        let outLevels = padded(f.out, to: bands, with: floorDB).prefix(columns).map(clampLevel)
        let barWidth = layout.barWidth
        let pad = String(repeating: " ", count: max(w - barWidth, 0))
        func bar(_ glyph: String) -> String { String(repeating: glyph, count: barWidth) }
        let barInks = (0..<columns).map { outside.contains($0) ? .dim : barInk(gain: gains[$0], level: outLevels[$0]) }
        let markers = gains.map { g in
            min(max(Int(((12 - g) / 24 * Double(rows - 1)).rounded()), 0), rows - 1)
        }
        let outTops = outLevels.map { height($0, rows: rows) }
        let inTops = inLevels.map { height($0, rows: rows) }

        let tableWidth = layout.tableWidth
        let indent = stripped.isEmpty ? max(layout.width - tableWidth, 0) / 2 : Strip.placement(layout).start
        let title = header(f, layout: layout, tableWidth: tableWidth, preset: preset, preference: preference, knobs: knobs,
                           dynamics: dynamics, focus: focus)
        let margin = String(repeating: " ", count: indent)

        var top: [String] = []
        if let focus, layout.bracketRows > 0 { top.append(margin + Strip.bracket(focus, layout: layout)) }
        var body: [String] = []
        for r in 0..<rows {
            let b = rows - 1 - r
            body.append((0..<columns).map { i -> String in
                // The marker wins over a partial top: where the slider sits matters more than an eighth of a row.
                if r == markers[i] {
                    let ink = outside.contains(i) ? .dim : Paint.level(Paint.gain(gains[i]), hot: abs(gains[i]) > 6)
                    return pad + Paint.ink(ink, bar("▬"))
                }
                let full = Int(outTops[i])
                let fraction = outTops[i] - Double(full)
                if b < full { return pad + paint(barInks[i], bar("█")) }
                if b == full, fraction > 0 {
                    return pad + paint(barInks[i], bar(partials[min(Int(fraction * 8), partials.count - 1)]))
                }
                if Double(b) < inTops[i] { return pad + Paint.ink(.dim, bar("░")) }
                return pad + bar(" ")
            }.joined())
        }
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
        var lines = [headerIndent + title.painted] + top + body.map { margin + $0 }
        lines += stripped.map { Strip.row($0, layout: layout, levels: outLevels, gains: gains, highlighted: focus != nil) }
        lines += tail.map { margin + $0 }
        if let modal {
            lines = WatchOverlay.draw(modal, over: lines, width: layout.width, focus: focus, knobs: knobs)
        }
        let room = max(layout.width - indent, 1)
        var message: String?
        if let prompt {
            // The end of a long name stays in sight: that is where the typing happens.
            let typed = String(prompt.suffix(max(room - promptLabel.count - 1, 0)))
            message = margin + Paint.ink(.dim, promptLabel) + typed + "▏"
        } else if let text = note ?? (columns < bands && !layout.folded ? "… widen for all bands" : nil) {
            message = margin + Paint.ink(.dim, TerminalText.prefix(text, columns: room))
        }
        let context: KeyContext = prompt != nil ? .prompt : modal?.context ?? .meter
        let state = KeyState(strip: strip, focused: focus != nil, listening: listening, mouse: mouse)
        let bar = Keybar.line(context, state: state, width: layout.width, compact: layout.folded)
        return lines + (layout.folded ? [message ?? bar] : [message ?? "", bar])
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

    enum PromptStep: Equatable {
        case typing(String), cancel, submit(String)
    }

    /// Esc alone cancels; any other escape sequence (an arrow) is ignored. Enter arrives as `\n`
    /// because ICRNL stays on in the raw mode `LiveTerminal` sets.
    static func promptStep(_ typed: String, _ keys: String) -> PromptStep {
        if keys == "\u{1B}" { return .cancel }
        guard !keys.contains("\u{1B}") else { return .typing(typed) }
        var text = typed
        for c in keys {
            switch c {
            case "\r", "\n", "\r\n": return .submit(text)
            case "\u{7F}", "\u{08}": if !text.isEmpty { text.removeLast() }
            default: if !c.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { text.append(c) }
            }
        }
        return .typing(text)
    }

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

    /// What the header shows of the current device's profile beside the meters.
    struct Header {
        var preset: Table.PresetMark?
        var preference: Preference?
        var knobs: [String: Double]?
        var dynamics: Dynamics?
        var mouse = false
    }

    /// Redraws on every frame the source delivers, and after keys that arrive between frames; a
    /// line that is no frame (the client's wake-up for input) only reads keys, and redraws when
    /// the terminal changed size or `invalidated` says the screen was lost (a resume). The
    /// terminal size is checked on every draw. `edit` applies a band, preamp, preset, knob, mouse
    /// or undo step; what it throws is shown in the message row for two seconds. `header` is asked
    /// again after every edit and once a second, so a change from another terminal shows too, and
    /// `mouse` is told whenever its setting changes. `send` writes one request line to the daemon
    /// (solo on/off); a solo this loop turned on is turned off again on the way out, and the
    /// daemon drops it anyway once the socket closes.
    static func run(source: MeterSource, size: () -> (cols: Int, rows: Int) = { (80, 24) },
                    zones: Bool = false, emit: (String) -> Void,
                    readKey: () -> String?, edit: (WatchAction) throws -> Void = { _ in },
                    header: () -> Header = { Header() },
                    send: (String) throws -> Void = { _ in },
                    invalidated: () -> Bool = { false }, mouse: (Bool) -> Void = { _ in }) -> Int32 {
        emit(enter)
        var current = size()
        var strip = zones
        var focus: Int?
        var listening = false
        var modal: WatchModal?
        var flash: (band: Int, left: Int)?
        var note: (text: String, left: Int)?
        var prompt: String?
        var shown = header()
        var mouseOn = false
        var framesSinceMark = 0
        var last: MeterFrame?
        var requestedAt: Double?
        var clearPending = false
        var focused: Instrument? { focus.map { Instruments.all[$0] } }
        func fit() -> WatchLayout {
            .fit(cols: current.cols, rows: current.rows,
                 zones: strip ? (focus == nil ? Instruments.all.count : 1) : 0, bracket: focus != nil)
        }
        var layout = fit()
        func show(_ text: String) { note = (text, noteFrames) }
        func syncMouse() {
            guard shown.mouse != mouseOn else { return }
            mouseOn = shown.mouse
            mouse(mouseOn)
        }
        syncMouse()
        func refresh() {
            shown = header()
            framesSinceMark = 0
            syncMouse()
        }
        func apply(_ action: WatchAction) {
            if case .bandStep(let band, _) = action, let instrument = focused, !instrument.bands.contains(band) {
                show(outsideNote(instrument))
                return
            }
            do {
                try edit(action)
                if case .bandStep(let band, _) = action { flash = (band, flashFrames) }
            } catch {
                show(String(describing: error).split(separator: "\n").first.map(String.init) ?? "")
            }
            refresh()
        }
        func request(_ range: HzRange?) -> Bool {
            // At 0 Hz the daemon refuses any range, so the frame loop asks once a rate arrives; a solo
            // already sounding is cleared now, or the daemon would carry it across the rebuild.
            let deferred = range != nil && last?.rate == 0
            requestedAt = deferred ? nil : last?.rate
            if deferred, !listening { return true }
            do {
                try send(soloRequest(deferred ? nil : range))
            } catch {
                show("listen: the daemon did not take the request")
                return false
            }
            // The daemon refuses silently (and drops the previous solo); the same clamp here says why.
            if !deferred, let range, let rate = last?.rate, let instrument = focused,
               EQProcessor.clampSolo(low: range.low, high: range.high, sampleRate: rate) == nil {
                show(cannotListen(instrument))
            }
            return true
        }
        func refocus(_ index: Int?) {
            focus = index
            if listening {
                // A failed send most likely means the socket is gone, and the daemon clears then.
                listening = request(focused?.characterRange) && focus != nil
            }
            layout = fit()
        }
        func draw() {
            guard let f = last else { return }
            let now = size()
            var clear = ""
            if now != current || clearPending {
                current = now
                layout = fit()
                clearPending = false
                // A terminal reflows on resize, so the old frame lands in places the new one never overwrites.
                clear = "\u{1B}[2J"
            }
            let lines = frame(f, layout: layout, strip: strip, focus: focused, modal: modal, flash: flash?.band,
                              note: note?.text, preset: shown.preset, preference: shown.preference, knobs: shown.knobs,
                              dynamics: shown.dynamics, prompt: prompt, listening: listening, mouse: mouseOn)
            emit(clear + "\u{1B}[H" + lines.map { $0 + "\u{1B}[K" }.joined(separator: "\n") + "\u{1B}[J")
        }
        /// False to quit.
        func handle(_ keys: String) -> Bool {
            if let typed = prompt {
                switch promptStep(typed, keys) {
                case .typing(let text): prompt = text
                case .cancel: prompt = nil
                case .submit(let name):
                    prompt = nil
                    apply(.savePreset(name))
                }
                return true
            }
            let count = Instruments.all.count
            for key in WatchKeys.keys(in: keys) {
                guard let action = KeyTable.action(for: key, in: modal?.context ?? .meter) else { continue }
                switch action {
                case .quit:
                    if listening { _ = request(nil) }
                    return false
                case .zones:
                    strip.toggle()
                    layout = fit()
                case .help: modal = .help(scroll: 0)
                case .instruments: modal = .instruments(scroll: 0)
                case .closeModal: modal = nil
                case .scrollUp, .scrollDown:
                    modal = modal.map { $0.scrolled(by: action == .scrollUp ? -1 : 1, layout: layout) }
                case .palette: show(paletteNote)
                case .startSave:
                    // The rest of this read would otherwise act as commands after the prompt opened.
                    prompt = ""
                    return true
                case .focusNext: refocus(focus.map { ($0 + 1) % count } ?? 0)
                case .focusPrevious: refocus(focus.map { ($0 + count - 1) % count } ?? count - 1)
                case .unfocus:
                    if focus != nil { refocus(nil) }
                case .listen:
                    guard let instrument = focused else { show(listenNeedsFocus); break }
                    if listening {
                        if request(nil) { listening = false }
                    } else {
                        listening = request(instrument.characterRange)
                    }
                case .knob(let delta):
                    guard let instrument = focused else { show(listenNeedsFocus); break }
                    apply(.boost(instrument.name, delta))
                case .bandStep, .preamp, .bass, .treble, .cyclePreset, .previousPreset, .undo, .savePreset, .boost,
                     .cycleComp, .cycleColour, .colourAmount, .mouse:
                    apply(action)
                }
            }
            return true
        }
        let eof = source.lines(maxLines: nil) { line in
            if invalidated() { clearPending = true }
            let f = try? JSONDecoder().decode(MeterFrame.self, from: Data(line.utf8))
            if let f {
                let hadSolo = last?.solo != nil
                last = f
                // The daemon keeps a solo across a device switch, so only a frame without one asks again:
                // once per rate, or once when it vanished at a rate the range can play (refused at a 0 Hz
                // moment no frame showed).
                if listening, let instrument = focused, f.solo == nil, f.rate > 0 {
                    let range = instrument.characterRange
                    let dropped = hadSolo && EQProcessor.clampSolo(low: range.low, high: range.high, sampleRate: f.rate) != nil
                    if requestedAt != f.rate || dropped { listening = request(range) }
                }
                framesSinceMark += 1
                if framesSinceMark >= markFrames { refresh() }
                draw()
                flash = flash.flatMap { $0.left > 1 ? ($0.band, $0.left - 1) : nil }
                note = note.flatMap { $0.left > 1 ? ($0.text, $0.left - 1) : nil }
            }
            guard let keys = readKey() else {
                if f == nil, clearPending || size() != current { draw() }
                return true
            }
            guard handle(keys) else { return false }
            if f == nil { draw() }
            return true
        }
        emit(leave)
        return eof ? 1 : 0
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

    /// A box centred over `lines[1...]`: the header stays visible above it. Lines wider than the
    /// box are cut with `…`; when not all fit, the bottom border says which part shows.
    static func draw(_ modal: WatchModal, over lines: [String], width: Int, focus: Instrument?, knobs: [String: Double]?) -> [String] {
        let content = self.lines(modal, focus: focus, knobs: knobs)
        let region = lines.count - 1
        let title: String
        switch modal {
        case .help: title = "keys"
        case .instruments: title = "instruments"
        }
        let boxWidth = min(width, (content.map { TerminalText.width($0.plain) }.max() ?? 0) + 4)
        guard region >= 3, boxWidth >= title.count + 6 else { return lines }
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
        var result = lines
        let column = max((width - boxWidth) / 2, 0)
        let top = 1 + max((region - height) / 2, 0)
        for (i, row) in rows.enumerated() {
            result[top + i] = Watch.overlay(result[top + i], row, at: column, width: boxWidth)
        }
        return result
    }
}

// The SIGINT handler is a C function pointer and cannot capture, so the saved state lives here.
private var savedTermios = termios()
private var termiosSaved = false

private func restoreTerminalAndExit(_: Int32) {
    if termiosSaved { tcsetattr(0, TCSANOW, &savedTermios) }
    Watch.leave.utf8CString.withUnsafeBufferPointer { _ = write(1, $0.baseAddress, $0.count - 1) }
    _exit(0)
}

enum LiveTerminal {
    static func width(fd: Int32) -> Int {
        var size = winsize()
        guard isatty(fd) == 1, ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 80 }
        return Int(size.ws_col)
    }

    static func probe() -> (isTTY: Bool, cols: Int, rows: Int) {
        var size = winsize()
        guard isatty(0) == 1, isatty(1) == 1, ioctl(1, TIOCGWINSZ, &size) == 0 else { return (false, 0, 0) }
        return (true, Int(size.ws_col), Int(size.ws_row))
    }

    /// Non-canonical and silent so `q` arrives without Enter and is not echoed over the meters;
    /// ISIG stays on so Ctrl-C still reaches the handler that puts the terminal back.
    static func enterRaw() {
        termiosSaved = tcgetattr(0, &savedTermios) == 0
        signal(SIGINT, restoreTerminalAndExit)
        signal(SIGTERM, restoreTerminalAndExit)
        guard termiosSaved else { return }
        var raw = savedTermios
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(0, TCSANOW, &raw)
    }

    static func leaveRaw() {
        if termiosSaved { tcsetattr(0, TCSANOW, &savedTermios) }
    }

    static let maxRead = 4096

    /// Everything waiting on stdin, up to `maxRead` bytes; a paste longer than that finishes on
    /// the next frame.
    static func drainInput() -> [UInt8] {
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: maxRead)
        var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        while bytes.count < maxRead, poll(&pfd, 1, 0) > 0 {
            let count = read(0, &chunk, maxRead - bytes.count)
            guard count > 0 else { break }
            bytes += chunk.prefix(count)
        }
        return bytes
    }

    static func emit(_ text: String) {
        fputs(text, stdout)
        fflush(stdout)
    }
}
