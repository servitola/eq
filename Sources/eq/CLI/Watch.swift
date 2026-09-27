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

    /// Two rows beyond the four fixed ones (header, live row, labels, gains) stay free, one of
    /// them for the "widen" note, so the frame never scrolls the alternate screen.
    static func fit(cols: Int, rows: Int) -> WatchLayout {
        let cellWidth = min(max((cols - 2) / 10, 3), 8)
        return WatchLayout(columns: min(Config.bandLabels.count, max(1, (cols - 2) / cellWidth)),
                           cellWidth: cellWidth, meterRows: max(4, rows - 5),
                           shortLabels: cellWidth < 6, width: cols)
    }
}

enum Watch {
    static let enter = "\u{1B}[?1049h\u{1B}[?25l"
    static let leave = "\u{1B}[?25h\u{1B}[?1049l"
    private static let bands = Config.bandLabels.count
    private static let floorDB = -60.0
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

    /// Header, `meterRows` of bars, the live level row, labels, gains, and — when not every band
    /// fits — a note to widen the terminal.
    static func frame(_ f: MeterFrame, layout: WatchLayout) -> [String] {
        let columns = min(max(layout.columns, 1), bands)
        let rows = max(layout.meterRows, 1)
        let w = max(layout.cellWidth, 1)
        let gains = padded(f.gains, to: bands, with: 0).prefix(columns).map { min(max($0, -12), 12) }
        let inLevels = padded(f.in, to: bands, with: floorDB).prefix(columns).map(clampLevel)
        let outLevels = padded(f.out, to: bands, with: floorDB).prefix(columns).map(clampLevel)
        let pad = String(repeating: " ", count: w - 1)
        let barInks = (0..<columns).map { i -> Paint.Ink? in
            let hot = outLevels[i] >= hotDB
            // A flat band has no colour of its own; a loud one still has to stand out from dim.
            if gains[i] == 0 { return hot ? nil : .dim }
            return Paint.level(Paint.gain(gains[i]), hot: hot)
        }
        let markers = gains.map { g in
            min(max(Int(((12 - g) / 24 * Double(rows - 1)).rounded()), 0), rows - 1)
        }
        let outTops = outLevels.map { height($0, rows: rows) }
        let inTops = inLevels.map { height($0, rows: rows) }

        var lines = [header(f, layout: layout, tableWidth: columns * w)]
        for r in 0..<rows {
            let b = rows - 1 - r
            lines.append((0..<columns).map { i -> String in
                if r == markers[i] {
                    return pad + Paint.ink(Paint.level(Paint.gain(gains[i]), hot: abs(gains[i]) > 6), "▬")
                }
                let full = Int(outTops[i])
                let fraction = outTops[i] - Double(full)
                if b < full { return pad + paint(barInks[i], "█") }
                if b == full, fraction > 0 {
                    return pad + paint(barInks[i], partials[min(Int(fraction * 8), partials.count - 1)])
                }
                if Double(b) < inTops[i] { return pad + Paint.ink(.dim, "░") }
                return pad + " "
            }.joined())
        }
        lines.append((0..<columns).map { i -> String in
            let text = outLevels[i] <= floorDB + 0.5 ? "·" : String(Int(outLevels[i].rounded()))
            return paint(barInks[i], text.leftPadded(to: w))
        }.joined())
        lines += [Table.labelsRow(width: w, short: layout.shortLabels, columns: columns),
                  Table.gainsRow(gains, width: w)]
        if columns < bands {
            lines.append(Paint.ink(.dim, String("… widen for all bands".prefix(max(layout.width, 1)))))
        }
        return lines
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
    private static func header(_ f: MeterFrame, layout: WatchLayout, tableWidth: Int) -> String {
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
            return Paint.ink(.bold, cut)
        }
        return compose().painted
    }

    /// Redraws on every frame the source delivers; the key is checked between frames, which at
    /// 30 frames a second is quicker than a person notices.
    static func run(source: MeterSource, layout: WatchLayout = .fit(cols: 80, rows: 24),
                    emit: (String) -> Void, readKey: () -> UInt8?) -> Int32 {
        emit(enter)
        let eof = source.lines(maxLines: nil) { line in
            if let f = try? JSONDecoder().decode(MeterFrame.self, from: Data(line.utf8)) {
                emit("\u{1B}[H" + frame(f, layout: layout).map { $0 + "\u{1B}[K" }.joined(separator: "\n") + "\u{1B}[J")
            }
            switch readKey() {
            case UInt8(ascii: "q"), UInt8(ascii: "Q"), 3: return false
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
