import Foundation

enum WatchAction: Equatable {
    case bandStep(Int, Double)
    case preamp(Double)
    case zones, help, dismissHelp, quit
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
        case "h", "H", "?", "р", "Р": return .help
        case "x", "X", "ч", "Ч": return .dismissHelp
        case "q", "Q", "й", "Й", "\u{03}": return .quit
        default: break
        }
        if let band = digits.firstIndex(of: c) { return .bandStep(band, step) }
        if let band = usShifted.firstIndex(of: c) ?? ruShifted.firstIndex(of: c) { return .bandStep(band, -step) }
        return nil
    }
}

enum HintBox {
    static let width = 29
    static let compact = "1…0 up · ⇧ down · +/− preamp · z zones · h help · q quit"

    private static let entries: [[(key: String, text: String)]] = [
        [("1…0", "band up   0.5 dB")],
        [("⇧1…0", "band down 0.5 dB")],
        [("+ −", "preamp")],
        [("z", "zones   "), ("h", "this hint")],
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
