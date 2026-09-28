import Foundation

enum WatchAction: Equatable {
    case bandStep(Int, Double)
    case preamp(Double)
    case bass(Double), treble(Double)
    case cyclePreset, previousPreset, undo
    case savePreset(String)
    case startSave, zones, help, dismissHelp, quit
    case focusNext, focusPrevious, unfocus, listen
    /// A key's step for the focused instrument's knob; `boost` is that step once the focus names it.
    case knob(Double), boost(String, Double)
}

enum WatchKeys {
    static let step = 0.5
    /// A CSI's parameter and intermediate bytes, then the final byte that ends it.
    static let parameters: ClosedRange<UInt8> = 0x20...0x3F
    static let finals: ClosedRange<UInt8> = 0x40...0x7E

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
        case "b", "и": return .bass(step)
        case "B", "И": return .bass(-step)
        case "t", "е": return .treble(step)
        case "T", "Е": return .treble(-step)
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
        case ".", ">", "ю", "Ю": return .knob(step)
        case ",", "<", "б", "Б": return .knob(-step)
        case "\u{1B}": return .unfocus
        default: break
        }
        if let band = digits.firstIndex(of: c) { return .bandStep(band, step) }
        if let band = usShifted.firstIndex(of: c) ?? ruShifted.firstIndex(of: c) { return .bandStep(band, -step) }
        return nil
    }

    /// Complete keys as `KeyBuffer` hands them over. Arrows arrive as `ESC [ A`…`D`, or `ESC O A`…`D`
    /// when the terminal is in application-cursor mode; any other escape sequence is skipped whole,
    /// so its tail never reads as letter commands. A bare `ESC`, or `ESC [`/`ESC O` whose parameters
    /// run into anything but a final byte (the end, another `ESC`), is the Esc key and whatever was
    /// typed after it: the buffer only lets such a tail through once nothing followed it.
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
            let start = i
            while i < chars.count, let byte = chars[i].asciiValue, Self.parameters.contains(byte) { i += 1 }
            guard i < chars.count, let byte = chars[i].asciiValue, Self.finals.contains(byte) else {
                result.append(.unfocus)
                i = start - 1
                continue
            }
            switch chars[i] {
            case "A": result.append(.previousPreset)
            case "B": result.append(.cyclePreset)
            case "C": result.append(.knob(step))
            case "D": result.append(.knob(-step))
            default: break
            }
            i += 1
        }
        return result
    }
}

/// Terminal input arrives in whatever pieces the tty hands over: an arrow's `ESC [ B` or a
/// Cyrillic letter's two bytes can straddle two reads. Only whole keys go out; an unfinished
/// tail waits for the next read.
struct KeyBuffer {
    private var pending: [UInt8] = []
    // Longer than any sequence a terminal sends for a key; a tail this long is not a key.
    static let maxTail = 32

    /// `bytes` is everything one read drained, possibly nothing. A lone `ESC`, or `ESC [`/`ESC O`
    /// and parameters, left over from the previous read is the Esc key and what was typed after it
    /// only when this read brought nothing more; a terminal writes a whole sequence at once, a
    /// person does not.
    mutating func feed(_ bytes: [UInt8]) -> String? {
        if bytes.isEmpty, pending.first == 0x1B,
           pending.count == 1 || pending[1] == UInt8(ascii: "[") || pending[1] == UInt8(ascii: "O") {
            defer { pending = [] }
            return String(decoding: pending, as: UTF8.self)
        }
        pending += bytes
        var end = 0
        while end < pending.count, let length = Self.token(pending, at: end) { end += length }
        let complete = pending[..<end]
        pending.removeFirst(end)
        if pending.count > Self.maxTail { pending = [] }
        return complete.isEmpty ? nil : String(decoding: complete, as: UTF8.self)
    }

    /// The length of the whole key starting at `i`, or nil when it is cut off.
    private static func token(_ b: [UInt8], at i: Int) -> Int? {
        guard b[i] == 0x1B else { return character(b, at: i) }
        guard i + 1 < b.count else { return nil }
        guard b[i + 1] == UInt8(ascii: "[") || b[i + 1] == UInt8(ascii: "O") else {
            return character(b, at: i + 1).map { $0 + 1 }
        }
        var j = i + 2
        while j < b.count, WatchKeys.parameters.contains(b[j]) { j += 1 }
        guard j < b.count else { return nil }
        // Anything but a final byte (another ESC, a letter) ends a sequence a person typed, unfinished.
        return WatchKeys.finals.contains(b[j]) ? j - i + 1 : j - i
    }

    private static func character(_ b: [UInt8], at i: Int) -> Int? {
        let lead = b[i]
        let length = lead < 0x80 ? 1 : lead >> 5 == 0b110 ? 2 : lead >> 4 == 0b1110 ? 3 : lead >> 3 == 0b11110 ? 4 : 1
        guard i + length <= b.count else { return nil }
        // A broken sequence goes out one byte at a time and decodes to U+FFFD, which is no key.
        let continued = b[(i + 1)..<(i + length)].allSatisfy { $0 & 0xC0 == 0x80 }
        return continued ? length : 1
    }
}

enum HintBox {
    static let width = 29
    private static let compactSegments = ["1…0 up", "⇧ down", "+/− preamp", "b bass", "t treble", "p ↑↓ preset", "u undo", "s save",
                                          "z zones", "[ ] focus", "← → boost", "l listen", "h help", "q quit"]

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
        [("b t", "bass/treble, ⇧ down")],
        [("p ↑↓", "preset  "), ("u", "undo")],
        [("s", "save as preset")],
        [("z", "zones   "), ("h", "this hint")],
        [("[ ]", "focus   "), ("l", "listen")],
        [("← →", "focused one ±0.5")],
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
