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

    /// Two rows beyond the four fixed ones (header, live row, labels, gains) stay free, one of
    /// them for the "widen" note, so the frame never scrolls the alternate screen.
    /// Four columns is the floor: at three, neighbouring labels and numbers run together.
    /// The focus bracket and the zone strip take their room from the meter down to its four-row
    /// floor — the bracket first, since it names what the dimmed bars mean — then strip rows drop
    /// from the bottom.
    static func fit(cols: Int, rows: Int, zones: Int = 0, bracket: Bool = false) -> WatchLayout {
        let cellWidth = min(max((cols - 2) / 10, 4), 8)
        let bracketRows = bracket && rows >= 10 ? 1 : 0
        let zoneRows = min(max(zones, 0), max(rows - 9 - bracketRows, 0))
        return WatchLayout(columns: min(Config.bandLabels.count, max(1, (cols - 2) / cellWidth)),
                           cellWidth: cellWidth, meterRows: max(4, rows - 5 - zoneRows - bracketRows),
                           shortLabels: cellWidth < 6, width: cols, zoneRows: zoneRows, bracketRows: bracketRows)
    }

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
    static let leave = "\u{1B}[?25h\u{1B}[?1049l"
    private static let bands = Config.bandLabels.count
    static let floorDB = -60.0
    private static let hotDB = -6.0
    private static let partials = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    static func requireTerminal(isTTY: Bool) throws {
        guard isTTY else { throw CLIError.usage("eq watch needs a terminal") }
    }

    /// Truncates or pads to `n` so a daemon/CLI version skew (a shorter array on the wire)
    /// can't index out of bounds and trap — a trap bypasses every terminal-restore path.
    /// Also sanitizes non-finite elements to `fill`, for the same reason.
    static func padded(_ a: [Double], to n: Int, with fill: Double) -> [Double] {
        let clean = a.map { $0.isFinite ? $0 : fill }
        return clean.count >= n ? Array(clean.prefix(n)) : clean + Array(repeating: fill, count: n - clean.count)
    }

    /// Header, the focus bracket, `meterRows` of bars, up to `zoneRows` of the instrument strip,
    /// the live level row, labels, gains, and one footer row: the save-as `prompt`, else a `note`,
    /// else the one-line hint when the box does not fit, else — when not every band fits — a
    /// note to widen the terminal. Sharing that row keeps the frame inside the height
    /// `WatchLayout.fit` budgeted. With a `focus` the strip shows only that instrument.
    static func frame(_ f: MeterFrame, layout: WatchLayout, strip: Bool = false, focus: Instrument? = nil,
                      hint: Bool = false, flash: Int? = nil, note: String? = nil,
                      preset: Table.PresetMark? = nil, preference: Preference? = nil, prompt: String? = nil) -> [String] {
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
        let title = header(f, layout: layout, tableWidth: tableWidth, preset: preset, preference: preference, focus: focus)
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
        let boxFits = HintBox.width * 2 <= layout.width && rows >= HintBox.rows.count
        if hint, boxFits {
            let column = max(indent + tableWidth - HintBox.width, 0)
            for (i, row) in HintBox.rows.enumerated() {
                lines[1 + top.count + i] = overlay(lines[1 + top.count + i], row, at: column, width: HintBox.width)
            }
        }
        lines += stripped.map { Strip.row($0, layout: layout, levels: outLevels, gains: gains, highlighted: focus != nil) }
        lines += tail.map { margin + $0 }
        let room = max(layout.width - indent, 1)
        if let prompt {
            // The end of a long name stays in sight: that is where the typing happens.
            let typed = String(prompt.suffix(max(room - promptLabel.count - 1, 0)))
            lines.append(margin + Paint.ink(.dim, promptLabel) + typed + "▏")
        } else if let footer = note ?? (hint && !boxFits ? HintBox.compact(width: room) : nil) ?? (columns < bands ? "… widen for all bands" : nil) {
            lines.append(margin + Paint.ink(.dim, String(footer.prefix(room))))
        }
        return lines
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
                               preset: Table.PresetMark?, preference: Preference?, focus: Instrument?) -> (plain: Int, painted: String) {
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
        if let preset { segments.append((preset.name + (preset.modified ? "*" : ""), Table.presetLabel(preset))) }
        if let preference {
            let parts = [("bass", preference.bass), ("treble", preference.treble), ("tilt", preference.tilt)].filter { $0.1 != 0 }
            if !parts.isEmpty {
                segments.append((parts.map { "\($0.0) \(String(format: "%+g", $0.1))" }.joined(separator: " "),
                                 parts.map { "\($0.0) " + Paint.ink(Paint.gain($0.1), String(format: "%+g", $0.1)) }.joined(separator: " ")))
            }
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
                let gap = flag.plain == "LIMIT" ? max(1, tableWidth - flag.plain.count - plain.count) : 1
                plain += String(repeating: " ", count: gap) + flag.plain
                painted += String(repeating: " ", count: gap) + flag.painted
            }
            return (plain.count, painted)
        }
        while compose().plain > cols, segments.count > 1 { segments.removeLast() }
        while compose().plain > cols, !flags.isEmpty { flags.removeLast() }
        if compose().plain > cols { focusSegment = nil }
        if compose().plain > cols {
            let cut = String(device.prefix(cols))
            return (cut.count, Paint.ink(.bold, cut))
        }
        return compose()
    }

    /// Frame counts at the daemon's 30 frames a second.
    static let hintFrames = 240
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
    static func cannotListen(_ instrument: Instrument) -> String { "can't listen to \(instrument.name) at this rate" }

    /// Redraws on every frame the source delivers; the key and the terminal size are checked
    /// between frames, which at 30 frames a second is quicker than a person notices.
    /// `edit` applies a band, preamp, preset or undo step; what it throws is shown in the footer
    /// for two seconds. `preset` names the current device's preset for the header; it is asked
    /// again after every edit and once a second, so a change from another terminal shows too.
    /// `send` writes one request line to the daemon (solo on/off); a solo this loop turned on is
    /// turned off again on the way out, and the daemon drops it anyway once the socket closes.
    static func run(source: MeterSource, size: () -> (cols: Int, rows: Int) = { (80, 24) },
                    zones: Bool = false, hintDismissed: Bool = false, emit: (String) -> Void,
                    readKey: () -> String?, edit: (WatchAction) throws -> Void = { _ in },
                    preset: () -> Table.PresetMark? = { nil }, preference: () -> Preference? = { nil },
                    dismissHint: () -> Void = {}, send: (String) throws -> Void = { _ in }) -> Int32 {
        emit(enter)
        var current = size()
        var strip = zones
        var focus: Int?
        var listening = false
        var dismissed = hintDismissed
        var hintLeft = dismissed ? 0 : hintFrames
        var flash: (band: Int, left: Int)?
        var note: (text: String, left: Int)?
        var prompt: String?
        var mark = preset()
        var layer = preference()
        var framesSinceMark = 0
        var rate: Double?
        var focused: Instrument? { focus.map { Instruments.all[$0] } }
        func fit() -> WatchLayout {
            .fit(cols: current.cols, rows: current.rows,
                 zones: strip ? (focus == nil ? Instruments.all.count : 1) : 0, bracket: focus != nil)
        }
        var layout = fit()
        func show(_ text: String) { note = (text, noteFrames) }
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
            mark = preset()
            layer = preference()
            framesSinceMark = 0
        }
        func request(_ range: HzRange?) -> Bool {
            do {
                try send(soloRequest(range))
            } catch {
                show("listen: the daemon did not take the request")
                return false
            }
            // The daemon refuses silently (and drops the previous solo); the same clamp here says why.
            if let range, let rate, let instrument = focused,
               EQProcessor.clampSolo(low: range.low, high: range.high, sampleRate: rate) == nil {
                show(cannotListen(instrument))
            }
            return true
        }
        func refocus(_ index: Int?) {
            focus = index
            if listening {
                // A failed send most likely means the socket is gone, and the daemon clears then.
                listening = request(focused?.outerSpan) && focus != nil
            }
            layout = fit()
        }
        let eof = source.lines(maxLines: nil) { line in
            if let f = try? JSONDecoder().decode(MeterFrame.self, from: Data(line.utf8)) {
                rate = f.rate
                let now = size()
                var clear = ""
                if now != current {
                    current = now
                    layout = fit()
                    // A terminal reflows on resize, so the old frame lands in places the new one never overwrites.
                    clear = "\u{1B}[2J"
                }
                framesSinceMark += 1
                if framesSinceMark >= markFrames { mark = preset(); layer = preference(); framesSinceMark = 0 }
                let lines = frame(f, layout: layout, strip: strip, focus: focused, hint: hintLeft > 0,
                                  flash: flash?.band, note: note?.text, preset: mark, preference: layer, prompt: prompt)
                emit(clear + "\u{1B}[H" + lines.map { $0 + "\u{1B}[K" }.joined(separator: "\n") + "\u{1B}[J")
                hintLeft = max(hintLeft - 1, 0)
                flash = flash.flatMap { $0.left > 1 ? ($0.band, $0.left - 1) : nil }
                note = note.flatMap { $0.left > 1 ? ($0.text, $0.left - 1) : nil }
            }
            guard let keys = readKey() else { return true }
            hintLeft = 0
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
            for action in WatchKeys.actions(for: keys) {
                switch action {
                case .quit:
                    if listening { _ = request(nil) }
                    return false
                case .zones:
                    strip.toggle()
                    layout = fit()
                case .help: hintLeft = hintFrames
                case .dismissHelp:
                    if !dismissed { dismissed = true; dismissHint() }
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
                        listening = request(instrument.outerSpan)
                    }
                case .bandStep, .preamp, .bass, .treble, .cyclePreset, .previousPreset, .undo, .savePreset:
                    apply(action)
                }
            }
            return true
        }
        emit(leave)
        return eof ? 1 : 0
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
