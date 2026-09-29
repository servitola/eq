import Darwin
import Foundation

/// Sixteen terminal colours, each with exactly one meaning across every command —
/// so "green" or "red" carries the same reading in `status`, `devices`, and `doctor`
/// without re-reading labels.
enum Paint {
    enum Ink: Int {
        case bold = 1, dim = 2, red = 31, green = 32, yellow = 33, blue = 34, magenta = 35, cyan = 36
        case brightGreen = 92, brightYellow = 93, brightMagenta = 95
    }

    static var forced: Bool?

    static var enabled: Bool { enabled(fd: 1) }

    /// stderr can be a terminal while stdout is piped, so errors decide on fd 2 separately.
    /// `getenv`, not `ProcessInfo.environment`: that copies the whole environment into a
    /// dictionary on every call, and the watch asks hundreds of times a frame.
    static func enabled(fd: Int32) -> Bool {
        forced ?? (isatty(fd) == 1 && getenv("NO_COLOR") == nil && getenv("TERM").map { strcmp($0, "dumb") != 0 } ?? true)
    }

    static func ink(_ ink: Ink, _ text: String) -> String {
        self.ink(ink, text, on: enabled)
    }

    static func ink(_ ink: Ink?, _ text: String, on: Bool) -> String {
        guard on, let ink else { return text }
        return "\u{1B}[\(ink.rawValue)m\(text)\u{1B}[0m"
    }

    static func gain(_ value: Double) -> Ink {
        value > 0 ? .green : (value < 0 ? .magenta : .dim)
    }

    /// The bright variant of the same meaning, for a signal running hot; still the terminal's palette.
    static func level(_ ink: Ink, hot: Bool) -> Ink {
        guard hot else { return ink }
        switch ink {
        case .green: return .brightGreen
        case .magenta: return .brightMagenta
        case .yellow: return .brightYellow
        default: return ink
        }
    }

    private static let glyphs = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    static func glyph(for value: Double) -> String {
        let index = value.isFinite ? Int(((min(max(value, -12), 12) + 12) / 24 * 7).rounded(.down)) : 0
        return glyphs[min(max(index, 0), glyphs.count - 1)]
    }

    static func spark(_ gains: [Double]) -> String {
        gains.map { ink(gain($0), glyph(for: $0)) }.joined()
    }

    static func state(_ state: Status.State) -> Ink {
        switch state {
        case .running: return .green
        case .starting, .bypassed: return .yellow
        case .failed, .noPermission: return .red
        }
    }
}
