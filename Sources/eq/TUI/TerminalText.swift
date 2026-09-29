import Darwin
import Foundation

/// Columns a string takes in a terminal, per grapheme cluster. Darwin's `wcwidth` answers −1 for
/// everything outside ASCII until `setlocale(LC_CTYPE, "UTF-8")` ran (`useUTF8Widths`); it has
/// no emoji sequences, so a cluster with U+FE0F or an emoji-presentation scalar counts 2.
enum TerminalText {
    static func useUTF8Widths() {
        setlocale(LC_CTYPE, "UTF-8")
    }

    static func width(_ text: String) -> Int {
        text.reduce(0) { $0 + width(of: $1) }
    }

    static func width(of c: Character) -> Int {
        if let ascii = c.asciiValue { return ascii < 0x20 || ascii == 0x7F ? 0 : 1 }
        let scalars = c.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if first.properties.isEmojiPresentation || scalars.contains("\u{FE0F}") { return 2 }
        let measured = Int(wcwidth(wchar_t(bitPattern: first.value)))
        return measured < 0 ? 1 : min(measured, 2)
    }

    /// The longest start of `text` that fits `columns`; a wide glyph that would straddle the
    /// edge is left out and its column padded.
    static func prefix(_ text: String, columns: Int) -> String {
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
}
