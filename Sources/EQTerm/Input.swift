public enum KeyCode: Hashable {
    /// Printable characters and the control characters a terminal sends as themselves: Enter
    /// (`\n` while ICRNL is on), Tab, Backspace (DEL), Ctrl-letters.
    case char(Character)
    case esc, up, down, left, right, home, end, pageUp, pageDown, insert, delete, backTab
    case function(Int)
}

public struct Modifiers: OptionSet, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 1)
    public static let alt = Modifiers(rawValue: 2)
    public static let ctrl = Modifiers(rawValue: 4)
}

public struct KeyPress: Hashable {
    public var code: KeyCode
    public var modifiers: Modifiers

    public init(_ code: KeyCode, _ modifiers: Modifiers = []) {
        self.code = code
        self.modifiers = modifiers
    }
}

public struct Mouse: Hashable {
    public enum Action: Hashable { case press, release, drag, move, wheelUp, wheelDown }
    public enum Button: Hashable { case left, middle, right, none }
    public var action: Action
    public var button: Button
    /// Zero-based cell.
    public var x: Int
    public var y: Int
    public var modifiers: Modifiers

    public init(_ action: Action, button: Button = .none, x: Int, y: Int, modifiers: Modifiers = []) {
        self.action = action
        self.button = button
        self.x = x
        self.y = y
        self.modifiers = modifiers
    }
}

public enum InputEvent: Hashable {
    case key(KeyPress)
    case mouse(Mouse)
    case paste(String)
    /// Focus reporting (DECSET 1004): the terminal window gained or lost focus.
    case focus(Bool)
    /// A DECRQM answer: `mode` is recognised and set (1, 3), reset (2, 4) or unknown (0).
    case modeReport(mode: Int, value: Int)
}

/// Terminal input arrives in whatever pieces the tty hands over: an arrow's `ESC [ B` or a
/// Cyrillic letter's two bytes can straddle two reads. Only whole keys go out; an unfinished
/// tail waits for the next read.
public struct KeyBuffer {
    private var pending: [UInt8] = []
    /// Longer than any sequence a terminal sends for a key; a tail this long is not a key.
    public static let maxTail = 32
    /// A CSI's parameter and intermediate bytes, then the final byte that ends it.
    static let parameters: ClosedRange<UInt8> = 0x20...0x3F
    static let finals: ClosedRange<UInt8> = 0x40...0x7E

    public init() {}

    /// Whether what waits is a bare `ESC` (or `ESC [`, `ESC O` and parameters) that only
    /// becomes the Esc key if nothing follows it.
    public var holdsEscape: Bool {
        pending.first == 0x1B && (pending.count == 1 || pending[1] == UInt8(ascii: "[") || pending[1] == UInt8(ascii: "O"))
    }

    /// `bytes` is everything one read drained, possibly nothing. A lone `ESC`, or `ESC [`/`ESC O`
    /// and parameters, left over from the previous read is the Esc key and what was typed after it
    /// only when this read brought nothing more; a terminal writes a whole sequence at once, a
    /// person does not.
    public mutating func feed(_ bytes: [UInt8]) -> String? {
        if bytes.isEmpty, holdsEscape {
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
        while j < b.count, parameters.contains(b[j]) { j += 1 }
        guard j < b.count else { return nil }
        // Anything but a final byte (another ESC, a letter) ends a sequence a person typed, unfinished.
        return finals.contains(b[j]) ? j - i + 1 : j - i
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

/// Bytes to events: `KeyBuffer` for whole keys, then the sequences parsed, and a bracketed
/// paste (`ESC [200~` … `ESC [201~`) gathered into one event however many reads it spans.
public struct InputDecoder {
    private var buffer = KeyBuffer()
    private var paste: String?
    /// A paste longer than this is cut: a stuck terminal must not grow it without end.
    public static let maxPaste = 1 << 16

    public init() {}

    public var holdsEscape: Bool { paste == nil && buffer.holdsEscape }

    public mutating func feed(_ bytes: [UInt8]) -> [InputEvent] {
        guard let text = buffer.feed(bytes) else { return [] }
        var result: [InputEvent] = []
        for event in InputParser.events(in: text) {
            switch event {
            case .key(let key) where paste != nil:
                if case .char(let c) = key.code, paste!.utf8.count < Self.maxPaste { paste!.append(c) }
            case .paste("\u{1B}[200~"):
                paste = ""
            case .paste("\u{1B}[201~"):
                if let text = paste { result.append(.paste(text)) }
                paste = nil
            default:
                if paste == nil { result.append(event) }
            }
        }
        return result
    }
}

public enum InputParser {
    /// Complete input as `KeyBuffer` hands it over. A bare `ESC`, or `ESC [`/`ESC O` whose
    /// parameters run into anything but a final byte (the end, another `ESC`), is the Esc key
    /// and whatever was typed after it: the buffer only lets such a tail through once nothing
    /// followed it. `ESC` and a character is that character with Alt. Paste brackets come out
    /// as `.paste` with the bracket itself, for `InputDecoder` to gather.
    public static func events(in text: String) -> [InputEvent] {
        let chars = Array(text)
        var result: [InputEvent] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            i += 1
            guard c == "\u{1B}" else {
                result.append(.key(KeyPress(.char(c))))
                continue
            }
            guard i < chars.count else { result.append(.key(KeyPress(.esc))); break }
            let introducer = chars[i]
            i += 1
            guard introducer == "[" || introducer == "O" else {
                if introducer != "\u{1B}" { result.append(.key(KeyPress(.char(introducer), .alt))) }
                continue
            }
            let start = i
            while i < chars.count, let byte = chars[i].asciiValue, KeyBuffer.parameters.contains(byte) { i += 1 }
            guard i < chars.count, let byte = chars[i].asciiValue, KeyBuffer.finals.contains(byte) else {
                result.append(.key(KeyPress(.esc)))
                i = start - 1
                continue
            }
            let parameters = String(chars[start..<i])
            if let event = sequence(introducer: introducer, parameters: parameters, final: chars[i]) { result.append(event) }
            i += 1
        }
        return result
    }

    private static func sequence(introducer: Character, parameters: String, final: Character) -> InputEvent? {
        if introducer == "O" {
            switch final {
            case "P", "Q", "R", "S": return .key(KeyPress(.function(Int(final.asciiValue! - UInt8(ascii: "P")) + 1)))
            default: return cursor(final).map { .key(KeyPress($0)) }
            }
        }
        if parameters.hasPrefix("<"), final == "M" || final == "m" { return mouse(parameters.dropFirst(), release: final == "m") }
        if parameters.hasPrefix("?"), parameters.hasSuffix("$"), final == "y" {
            let numbers = parameters.dropFirst().dropLast().split(separator: ";").compactMap { Int($0) }
            guard numbers.count == 2 else { return nil }
            return .modeReport(mode: numbers[0], value: numbers[1])
        }
        let numbers = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        let modifiers = numbers.count > 1 ? Self.modifiers(numbers[1] ?? 1) : []
        switch final {
        case "I" where parameters.isEmpty: return .focus(true)
        case "O" where parameters.isEmpty: return .focus(false)
        case "Z": return .key(KeyPress(.backTab, .shift))
        case "P", "Q", "R", "S": return .key(KeyPress(.function(Int(final.asciiValue! - UInt8(ascii: "P")) + 1), modifiers))
        case "~":
            guard let first = numbers.first ?? nil else { return nil }
            if first == 200 || first == 201 { return .paste("\u{1B}[\(first)~") }
            let code: KeyCode?
            switch first {
            case 1, 7: code = .home
            case 2: code = .insert
            case 3: code = .delete
            case 4, 8: code = .end
            case 5: code = .pageUp
            case 6: code = .pageDown
            case 11...15: code = .function(first - 10)
            case 17...21: code = .function(first - 11)
            case 23, 24: code = .function(first - 12)
            default: code = nil
            }
            return code.map { .key(KeyPress($0, modifiers)) }
        default:
            return cursor(final).map { .key(KeyPress($0, modifiers)) }
        }
    }

    private static func cursor(_ final: Character) -> KeyCode? {
        switch final {
        case "A": return .up
        case "B": return .down
        case "C": return .right
        case "D": return .left
        case "H": return .home
        case "F": return .end
        default: return nil
        }
    }

    /// xterm's modifier parameter: 1 plus a bit each for Shift, Alt and Ctrl.
    private static func modifiers(_ value: Int) -> Modifiers {
        Modifiers(rawValue: UInt8(truncatingIfNeeded: max(value - 1, 0) & 7))
    }

    /// SGR (1006) mouse report `b;x;y`, one-based cells; `b` carries the button in its low two
    /// bits, Shift 4, Alt 8, Ctrl 16, motion 32, the wheel 64.
    private static func mouse(_ parameters: Substring, release: Bool) -> InputEvent? {
        let numbers = parameters.split(separator: ";").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        let b = numbers[0]
        var modifiers: Modifiers = []
        if b & 4 != 0 { modifiers.insert(.shift) }
        if b & 8 != 0 { modifiers.insert(.alt) }
        if b & 16 != 0 { modifiers.insert(.ctrl) }
        let x = numbers[1] - 1, y = numbers[2] - 1
        if b & 64 != 0 {
            // 66 and 67 are the horizontal wheel, which nothing here uses.
            guard b & 2 == 0 else { return nil }
            return .mouse(Mouse(b & 1 == 0 ? .wheelUp : .wheelDown, x: x, y: y, modifiers: modifiers))
        }
        let buttons: [Mouse.Button] = [.left, .middle, .right, .none]
        let button = buttons[b & 3]
        let action: Mouse.Action = b & 32 != 0 ? (button == .none ? .move : .drag) : (release ? .release : .press)
        return .mouse(Mouse(action, button: button, x: x, y: y, modifiers: modifiers))
    }
}
