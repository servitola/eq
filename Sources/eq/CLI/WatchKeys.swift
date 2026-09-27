import Foundation

enum WatchAction: Equatable {
    case bandStep(Int, Double)
    case preamp(Double)
    case cyclePreset, previousPreset, undo
    case savePreset(String)
    case startSave, zones, help, dismissHelp, quit
    case focusNext, focusPrevious, unfocus, listen
}

enum WatchKeys {
    static let step = 0.5

    private static let digits = Array("1234567890")
    private static let usShifted = Array("!@#$%^&*()")
    /// Shift+7 on a Russian layout is `?`, which is help on a US one; help wins, so band 7 cannot
    /// be lowered from a Russian layout — `h` (`р`) is the layout-proof help key.
    private static let ruShifted = Array("!\"№;%:?*()")

    /// Russian letters sit on the same physical keys, so `q` still quits without switching layout.
    static func action(for key: String) -> WatchAction? {
        guard key.count == 1, let c = key.first else { return nil }
        switch c {
        case "+", "=": return .preamp(step)
        case "-", "_": return .preamp(-step)
        case "z", "Z", "я", "Я": return .zones
        case "p", "P", "з", "З": return .cyclePreset
        case "u", "U", "г", "Г": return .undo
        case "s", "S", "ы", "Ы": return .startSave
        case "h", "H", "?", "р", "Р": return .help
        case "x", "X", "ч", "Ч": return .dismissHelp
        case "q", "Q", "й", "Й", "\u{03}": return .quit
        case "]", "\t", "ъ", "Ъ": return .focusNext
        case "[", "х", "Х": return .focusPrevious
        case "l", "L", "д", "Д": return .listen
        case "\u{1B}": return .unfocus
        default: break
        }
        if let band = digits.firstIndex(of: c) { return .bandStep(band, step) }
        if let band = usShifted.firstIndex(of: c) ?? ruShifted.firstIndex(of: c) { return .bandStep(band, -step) }
        return nil
    }

    /// Everything one read delivered. ↑/↓ arrive as `ESC [ A`/`B`, or `ESC O A`/`B` when the
    /// terminal is in application-cursor mode; any other escape sequence is skipped whole, so its
    /// tail never reads as letter commands. A bare `ESC` is the Esc key only when nothing follows
    /// it in the same read — a sequence always arrives in one piece at these lengths.
    static func actions(for keys: String) -> [WatchAction] {
        let chars = Array(keys)
        var result: [WatchAction] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            i += 1
            guard c == "\u{1B}" else {
                if let action = action(for: String(c)) { result.append(action) }
                continue
            }
            guard i < chars.count else { result.append(.unfocus); break }
            let introducer = chars[i]
            i += 1
            guard introducer == "[" || introducer == "O" else { continue }
            // CSI parameters and intermediates run until the final byte, @ through ~.
            while i < chars.count, !(chars[i].asciiValue.map { (0x40...0x7E).contains($0) } ?? false) { i += 1 }
            guard i < chars.count else { break }
            switch chars[i] {
            case "A": result.append(.previousPreset)
            case "B": result.append(.cyclePreset)
            default: break
            }
            i += 1
        }
        return result
    }
}

enum HintBox {
    static let width = 29
    private static let compactSegments = ["1…0 up", "⇧ down", "+/− preamp", "p ↑↓ preset", "u undo", "s save",
                                          "z zones", "[ ] focus", "l listen", "h help", "q quit"]

    /// Whole segments drop from the right to fit `width`, except `q quit`: the way out always shows.
    static func compact(width: Int) -> String {
        var segments = compactSegments
        func line() -> String { segments.joined(separator: " · ") }
        while line().count > width, segments.count > 1 { segments.remove(at: segments.count - 2) }
        return line()
    }

    private static let entries: [[(key: String, text: String)]] = [
        [("1…0", "band up   0.5 dB")],
        [("⇧1…0", "band down 0.5 dB")],
        [("+ −", "preamp")],
        [("p ↑↓", "preset  "), ("u", "undo")],
        [("s", "save as preset")],
        [("z", "zones   "), ("h", "this hint")],
        [("[ ]", "focus   "), ("l", "listen")],
        [("x", "hide this for good")],
        [("q", "quit")],
    ]

    /// The first key of a row is padded to a six-column key column; a later key only gets a space.
    static var rows: [String] {
        let inner = width - 4
        let border = { (text: String) in Paint.ink(.dim, text) }
        let top = border("┌ ") + "tune" + border(" " + String(repeating: "─", count: width - 8) + "┐")
        let body = entries.map { parts -> String in
            var plain = 0
            let content = parts.enumerated().map { i, part -> String in
                let key = i == 0 ? part.key + String(repeating: " ", count: max(6 - part.key.count, 0)) : part.key + " "
                plain += key.count + part.text.count
                return Paint.ink(.dim, key) + part.text
            }.joined()
            return border("│ ") + content + String(repeating: " ", count: max(inner - plain, 0)) + border(" │")
        }
        return [top] + body + [border("└" + String(repeating: "─", count: width - 2) + "┘")]
    }
}
