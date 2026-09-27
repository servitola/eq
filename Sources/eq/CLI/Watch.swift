import Darwin
import Foundation

protocol MeterSource {
    func lines(maxLines: Int?, handle: (String) -> Bool)
}

extension MeterClient: MeterSource {}

enum Watch {
    static let minColumns = 64, minRows = 16, meterRows = 12
    static let enter = "\u{1B}[?1049h\u{1B}[?25l"
    static let leave = "\u{1B}[?25h\u{1B}[?1049l"
    private static let bands = Config.bandLabels.count

    static func requireTerminal(isTTY: Bool, cols: Int, rows: Int) throws {
        guard isTTY, cols >= minColumns, rows >= minRows else {
            throw CLIError.usage("eq watch needs a terminal of at least \(minColumns)×\(minRows)")
        }
    }

    /// Truncates or pads to `n` so a daemon/CLI version skew (a shorter array on the wire)
    /// can't index out of bounds and trap — a trap bypasses every terminal-restore path.
    static func padded(_ a: [Double], to n: Int, with fill: Double) -> [Double] {
        a.count >= n ? Array(a.prefix(n)) : a + Array(repeating: fill, count: n - a.count)
    }

    static func frame(_ f: MeterFrame, rows: Int = meterRows) -> [String] {
        let gains = padded(f.gains, to: bands, with: 0)
        let inLevels = padded(f.in, to: bands, with: -60)
        let outLevels = padded(f.out, to: bands, with: -60)
        var lines = [header(f)]
        let markers = (0..<bands).map { i in
            min(max(Int(((12 - gains[i]) / 24 * Double(rows - 1)).rounded()), 0), rows - 1)
        }
        for r in 0..<rows {
            let level = -60 + 60 * Double(rows - 1 - r) / Double(rows - 1)
            lines.append((0..<bands).map { i -> String in
                let pad = String(repeating: " ", count: Table.width - 1)
                if r == markers[i] { return pad + Paint.ink(Paint.gain(gains[i]), "▬") }
                if outLevels[i] >= level { return pad + Paint.ink(Paint.gain(gains[i]), "█") }
                if inLevels[i] >= level { return pad + Paint.ink(.dim, "░") }
                return pad + " "
            }.joined())
        }
        lines += [Table.labelsRow(), Table.gainsRow(gains)]
        return lines
    }

    private static func header(_ f: MeterFrame) -> String {
        let device = f.device ?? "no device"
        let rate = String(format: "%.1f", f.rate / 1000)
        let preamp = Table.gain(f.preamp)
        var plain = "\(device) · \(rate) kHz · preamp \(preamp) dB"
        var painted = "\(Paint.ink(.bold, device)) · \(rate) kHz · preamp \(Paint.ink(Paint.gain(f.preamp), preamp)) dB"
        if !f.enabled {
            plain += " BYPASS"
            painted += " " + Paint.ink(.yellow, "BYPASS")
        }
        if f.limiting {
            // Right edge of the band table (10 columns × 6), so LIMIT still fits a 64-column terminal.
            let limit = "LIMIT"
            let pad = max(1, Table.width * bands - limit.count - plain.count)
            painted += String(repeating: " ", count: pad) + Paint.ink(.yellow, limit)
        }
        return painted
    }

    /// Redraws on every frame the source delivers; the key is checked between frames, which at
    /// 30 frames a second is quicker than a person notices.
    static func run(source: MeterSource, emit: (String) -> Void, readKey: () -> UInt8?) -> Int32 {
        emit(enter)
        source.lines(maxLines: nil) { line in
            if let f = try? JSONDecoder().decode(MeterFrame.self, from: Data(line.utf8)) {
                emit("\u{1B}[H" + frame(f).map { $0 + "\u{1B}[K" }.joined(separator: "\n") + "\u{1B}[J")
            }
            switch readKey() {
            case UInt8(ascii: "q"), UInt8(ascii: "Q"), 3: return false
            default: return true
            }
        }
        emit(leave)
        return 0
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
