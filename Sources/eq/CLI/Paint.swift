import Darwin
import Foundation

/// Sixteen terminal colours, each with exactly one meaning across every command —
/// so "green" or "red" carries the same reading in `status`, `devices`, and `doctor`
/// without re-reading labels.
enum Paint {
    enum Ink: Int { case bold = 1, dim = 2, red = 31, green = 32, yellow = 33, magenta = 35, cyan = 36 }

    static var forced: Bool?

    static var enabled: Bool {
        forced ?? (isatty(1) == 1
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            && ProcessInfo.processInfo.environment["TERM"] != "dumb")
    }

    static func ink(_ ink: Ink, _ text: String) -> String {
        guard enabled else { return text }
        return "\u{1B}[\(ink.rawValue)m\(text)\u{1B}[0m"
    }

    static func gain(_ value: Double) -> Ink {
        value > 0 ? .green : (value < 0 ? .magenta : .dim)
    }

    private static let glyphs = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    static func glyph(for value: Double) -> String {
        let index = Int(((value + 12) / 24 * 7).rounded(.down))
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
