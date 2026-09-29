import Darwin
import Foundation

/// Columns a string takes in a terminal, per grapheme cluster. Darwin's `wcwidth` answers −1 for
/// everything outside ASCII until `setlocale(LC_CTYPE, "UTF-8")` ran (`useUTF8Widths`); it has
/// no emoji sequences, so a cluster with U+FE0F or an emoji-presentation scalar counts 2.
public enum TerminalText {
    public static func useUTF8Widths() {
        setlocale(LC_CTYPE, "UTF-8")
    }

    public static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    private static let narrow: [ClosedRange<UInt32>] = [0x2010...0x2027, 0x2190...0x21FF, 0x2500...0x25FF, 0x2800...0x28FF]

    public static func width(of c: Character) -> Int {
        if let ascii = c.asciiValue { return ascii < 0x20 || ascii == 0x7F ? 0 : 1 }
        let scalars = c.unicodeScalars
        guard let first = scalars.first else { return 0 }
        // Box drawing, blocks, geometric shapes, arrows, braille, dashes and the ellipsis — what the
        // screens are drawn with — are one column; asking the Unicode tables for each costs more
        // than the rest of a frame.
        if scalars.count == 1, Self.narrow.contains(where: { $0.contains(first.value) }) { return 1 }
        if first.properties.isEmojiPresentation || scalars.contains("\u{FE0F}") { return 2 }
        let measured = Int(wcwidth(wchar_t(bitPattern: first.value)))
        return measured < 0 ? 1 : min(measured, 2)
    }

    /// The longest start of `text` that fits `columns`; a wide glyph that would straddle the
    /// edge is left out and its column padded.
    public static func prefix(_ text: String, columns: Int) -> String {
        var result = ""
        var used = 0
        for c in text {
            let w = width(of: c)
            guard used + w <= columns else {
                result += String(repeating: " ", count: columns - used)
                break
            }
            result.append(c)
            used += w
        }
        return result
    }

    /// `prefix`, with `…` in the last column when something was cut.
    public static func truncated(_ text: String, columns: Int) -> String {
        guard columns > 0 else { return "" }
        guard width(text) > columns else { return text }
        return prefix(text, columns: columns - 1) + "…"
    }
}
