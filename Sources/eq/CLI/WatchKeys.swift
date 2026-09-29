import Foundation

enum WatchAction: Equatable {
    case bandStep(Int, Double)
    case preamp(Double)
    case bass(Double), treble(Double)
    case cyclePreset, previousPreset, undo
    case savePreset(String)
    case startSave, zones, instruments, help, quit
    case focusNext, focusPrevious, unfocus, listen
    /// A key's step for the focused instrument's knob; `boost` is that step once the focus names it.
    case knob(Double), boost(String, Double)
    case cycleComp, cycleColour, colourAmount
    case mouse, palette
    case closeModal, scrollUp, scrollDown
}

enum WatchKeys {
    static let step = KeyTable.step
    /// A CSI's parameter and intermediate bytes, then the final byte that ends it.
    static let parameters: ClosedRange<UInt8> = 0x20...0x3F
    static let finals: ClosedRange<UInt8> = 0x40...0x7E

    /// What one typed character does on the meter; `KeyTable` holds both layouts.
    static func action(for key: String) -> WatchAction? {
        guard key.count == 1, let c = key.first else { return nil }
        return KeyTable.action(for: c == "\u{1B}" ? .esc : .char(c), in: .meter)
    }

    static func actions(for keys: String, in context: KeyContext = .meter) -> [WatchAction] {
        self.keys(in: keys).compactMap { KeyTable.action(for: $0, in: context) }
    }

    /// Complete keys as `KeyBuffer` hands them over. Arrows arrive as `ESC [ A`…`D`, or `ESC O A`…`D`
    /// when the terminal is in application-cursor mode, and the wheel as an SGR mouse report
    /// `ESC [ < 64;x;y M` (65 down); any other escape sequence is skipped whole, so its tail never
    /// reads as letter commands. A bare `ESC`, or `ESC [`/`ESC O` whose parameters run into anything
    /// but a final byte (the end, another `ESC`), is the Esc key and whatever was typed after it:
    /// the buffer only lets such a tail through once nothing followed it.
    static func keys(in keys: String) -> [Key] {
        let chars = Array(keys)
        var result: [Key] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            i += 1
            guard c == "\u{1B}" else {
                result.append(.char(c))
                continue
            }
            guard i < chars.count else { result.append(.esc); break }
            let introducer = chars[i]
            i += 1
            guard introducer == "[" || introducer == "O" else { continue }
            let start = i
            while i < chars.count, let byte = chars[i].asciiValue, Self.parameters.contains(byte) { i += 1 }
            guard i < chars.count, let byte = chars[i].asciiValue, Self.finals.contains(byte) else {
                result.append(.esc)
                i = start - 1
                continue
            }
            let parameters = String(chars[start..<i])
            switch chars[i] {
            case "A": result.append(.up)
            case "B": result.append(.down)
            case "C": result.append(.right)
            case "D": result.append(.left)
            case "M" where parameters.hasPrefix("<64;"): result.append(.wheelUp)
            case "M" where parameters.hasPrefix("<65;"): result.append(.wheelDown)
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
        // A broken sequence goes out one byte at a time and decodes to U+FFFD, which is no key; it
        // is broken as soon as a byte that arrived is no continuation, not once enough arrived.
        guard b[(i + 1)..<min(i + length, b.count)].allSatisfy({ $0 & 0xC0 == 0x80 }) else { return 1 }
        return i + length <= b.count ? length : nil
    }
}
