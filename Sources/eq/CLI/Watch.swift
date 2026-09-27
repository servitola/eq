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

    /// Two rows beyond the four fixed ones (header, live row, labels, gains) stay free, one of
    /// them for the "widen" note, so the frame never scrolls the alternate screen.
    /// Four columns is the floor: at three, neighbouring labels and numbers run together.
    /// Zone rows take their room from the meter down to its four-row floor, then drop from the bottom.
    static func fit(cols: Int, rows: Int, zones: Int = 0) -> WatchLayout {
        let cellWidth = min(max((cols - 2) / 10, 4), 8)
        let zoneRows = min(max(zones, 0), max(rows - 9, 0))
        return WatchLayout(columns: min(Config.bandLabels.count, max(1, (cols - 2) / cellWidth)),
                           cellWidth: cellWidth, meterRows: max(4, rows - 5 - zoneRows),
                           shortLabels: cellWidth < 6, width: cols, zoneRows: zoneRows)
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

    /// Header, `meterRows` of bars, the live level row, labels, gains, up to `zoneRows` of zones,
    /// and — when not every band fits — a note to widen the terminal.
    static func frame(_ f: MeterFrame, layout: WatchLayout, zones: [Zone] = []) -> [String] {
        let columns = layout.visibleColumns
        let rows = max(layout.meterRows, 1)
        let w = layout.cell
        let shownZones = Array(zones.prefix(max(layout.zoneRows, 0)))
        let gains = padded(f.gains, to: bands, with: 0).prefix(columns).map { min(max($0, -12), 12) }
        let inLevels = padded(f.in, to: bands, with: floorDB).prefix(columns).map(clampLevel)
        let outLevels = padded(f.out, to: bands, with: floorDB).prefix(columns).map(clampLevel)
        let barWidth = layout.barWidth
        let pad = String(repeating: " ", count: max(w - barWidth, 0))
        func bar(_ glyph: String) -> String { String(repeating: glyph, count: barWidth) }
        let barInks = (0..<columns).map { barInk(gain: gains[$0], level: outLevels[$0]) }
        let markers = gains.map { g in
            min(max(Int(((12 - g) / 24 * Double(rows - 1)).rounded()), 0), rows - 1)
        }
        let outTops = outLevels.map { height($0, rows: rows) }
        let inTops = inLevels.map { height($0, rows: rows) }

        let tableWidth = layout.tableWidth
        let indent = shownZones.isEmpty ? max(layout.width - tableWidth, 0) / 2 : Zones.placement(layout).start
        let title = header(f, layout: layout, tableWidth: tableWidth)

        var body: [String] = []
        for r in 0..<rows {
            let b = rows - 1 - r
            body.append((0..<columns).map { i -> String in
                // The marker wins over a partial top: where the slider sits matters more than an eighth of a row.
                if r == markers[i] {
                    return pad + Paint.ink(Paint.level(Paint.gain(gains[i]), hot: abs(gains[i]) > 6), bar("▬"))
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
        body.append((0..<columns).map { i -> String in
            let text = outLevels[i] <= floorDB + 0.5 ? "·" : String(Int(outLevels[i].rounded()))
            return paint(barInks[i], text.leftPadded(to: w))
        }.joined())
        body += [Table.labelsRow(width: w, short: layout.shortLabels, columns: columns),
                 Table.gainsRow(gains, width: w)]
        let margin = String(repeating: " ", count: indent)
        // The header centres with the bars when it fits beside them, and slides left rather than truncate.
        let headerIndent = String(repeating: " ", count: min(indent, max(layout.width - title.plain, 0)))
        var lines = [headerIndent + title.painted] + body.map { margin + $0 }
        lines += Zones.render(shownZones, layout: layout, levels: outLevels, gains: gains)
        if columns < bands {
            lines.append(margin + Paint.ink(.dim, String("… widen for all bands".prefix(max(layout.width - indent, 1)))))
        }
        return lines
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

    /// Segments drop from the right until the line fits; the BYPASS/LIMIT flags outlive them
    /// because they are the ones that explain a surprising sound.
    private static func header(_ f: MeterFrame, layout: WatchLayout, tableWidth: Int) -> (plain: Int, painted: String) {
        let cols = max(layout.width, 1)
        let device = f.device ?? "no device"
        let rate = f.rate.isFinite ? String(format: "%.1f", f.rate / 1000) : "?"
        let preamp = f.preamp.isFinite ? Table.gain(f.preamp) : "?"
        let peak = f.peak.isFinite ? Table.gain(f.peak) : "?"
        var segments: [(plain: String, painted: String)] = [
            (device, Paint.ink(.bold, device)),
            ("\(rate) kHz", "\(rate) kHz"),
            ("preamp \(preamp) dB", "preamp \(Paint.ink(Paint.gain(f.preamp), preamp)) dB"),
            ("peak \(peak) dB", "peak \(peak) dB"),
        ]
        var flags: [(plain: String, painted: String)] = []
        if !f.enabled { flags.append(("BYPASS", Paint.ink(.yellow, "BYPASS"))) }
        if f.limiting { flags.append(("LIMIT", Paint.ink(.yellow, "LIMIT"))) }

        func compose() -> (plain: Int, painted: String) {
            var plain = segments.map(\.plain).joined(separator: " · ")
            var painted = segments.map(\.painted).joined(separator: " · ")
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
        if compose().plain > cols {
            let cut = String(device.prefix(cols))
            return (cut.count, Paint.ink(.bold, cut))
        }
        return compose()
    }

    /// Redraws on every frame the source delivers; the key and the terminal size are checked
    /// between frames, which at 30 frames a second is quicker than a person notices.
    static func run(source: MeterSource, size: () -> (cols: Int, rows: Int) = { (80, 24) },
                    zones: ZoneMode = .off, emit: (String) -> Void, readKey: () -> UInt8?) -> Int32 {
        emit(enter)
        var current = size()
        var mode = zones
        var layout = WatchLayout.fit(cols: current.cols, rows: current.rows, zones: mode.zones.count)
        let eof = source.lines(maxLines: nil) { line in
            if let f = try? JSONDecoder().decode(MeterFrame.self, from: Data(line.utf8)) {
                let now = size()
                var clear = ""
                if now != current {
                    current = now
                    layout = .fit(cols: now.cols, rows: now.rows, zones: mode.zones.count)
                    // A terminal reflows on resize, so the old frame lands in places the new one never overwrites.
                    clear = "\u{1B}[2J"
                }
                emit(clear + "\u{1B}[H" + frame(f, layout: layout, zones: mode.zones).map { $0 + "\u{1B}[K" }.joined(separator: "\n") + "\u{1B}[J")
            }
            switch readKey() {
            case UInt8(ascii: "q"), UInt8(ascii: "Q"), 3: return false
            case UInt8(ascii: "z"), UInt8(ascii: "Z"):
                mode = mode.next
                layout = .fit(cols: current.cols, rows: current.rows, zones: mode.zones.count)
                return true
            default: return true
            }
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

    static func readKey() -> UInt8? {
        var pfd = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 0) > 0 else { return nil }
        var byte: UInt8 = 0
        return read(0, &byte, 1) == 1 ? byte : nil
    }

    static func emit(_ text: String) {
        fputs(text, stdout)
        fflush(stdout)
    }
}
