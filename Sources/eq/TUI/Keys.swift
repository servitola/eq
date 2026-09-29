import EQTerm
import Foundation

/// A key once its escape sequence is decoded. Tab, Ctrl-C and Ctrl-P are characters.
enum Key: Hashable {
    case char(Character)
    case up, down, right, left, esc
    case wheelUp, wheelDown

    var name: String {
        switch self {
        case .char("\t"): return "Tab"
        case .char("\u{03}"): return "Ctrl-C"
        case .char("\u{10}"): return "Ctrl-P"
        case .char(let c): return String(c)
        case .up: return "↑"
        case .down: return "↓"
        case .right: return "→"
        case .left: return "←"
        case .esc: return "Esc"
        case .wheelUp: return "wheel up"
        case .wheelDown: return "wheel down"
        }
    }
}

/// Where a key is looked up: the meter, or the overlay or prompt on top of it. `global` is
/// searched after any of them.
enum KeyContext: CaseIterable {
    case meter, help, instruments, prompt, global
}

/// What the keybar needs to know to show a key's state, or whether to show it at all.
struct KeyState: Equatable {
    var strip = false
    var focused = false
    var listening = false
    var mouse = false
}

struct KeyBinding {
    var context: KeyContext
    var group: String
    /// Keys as a US layout types them; the Russian twins are derived.
    var keys: [Key]
    /// One per key, or one for all of them. nil: the text field handles the key itself.
    var actions: [WatchAction?]
    /// The keys as shown in the help overlay and the README.
    var label: String
    var help: String
    /// The keybar entry, key then text; nil keeps the binding off the bar.
    var bar: (key: String, text: String)? = nil
    /// Keybar order, and the last to drop has the lowest; 0 is never dropped.
    var rank = 0
    var state: ((KeyState) -> String)? = nil
    var when: ((KeyState) -> Bool)? = nil

    func action(at index: Int) -> WatchAction? { actions.count == 1 ? actions[0] : actions[index] }
}

/// The same physical key on a US and a Russian (PC) layout, unshifted then shifted.
enum PhysicalKeys {
    static let us = Array("`1234567890-=qwertyuiop[]\\asdfghjkl;'zxcvbnm,./" + "~!@#$%^&*()_+QWERTYUIOP{}|ASDFGHJKL:\"ZXCVBNM<>?")
    static let ru = Array("ё1234567890-=йцукенгшщзхъ\\фывапролджэячсмитьбю." + "Ё!\"№;%:?*()_+ЙЦУКЕНГШЩЗХЪ/ФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,")

    static func twin(_ key: Key) -> Key? {
        guard case .char(let c) = key, let index = us.firstIndex(of: c), ru[index] != c else { return nil }
        return .char(ru[index])
    }
}

/// The one table of keys: it drives what a key does, the keybar, the help overlay and the
/// README's key table.
enum KeyTable {
    static let step = 0.5
    private static let digits = "1234567890".map { Key.char($0) }
    private static let shiftedDigits = "!@#$%^&*()".map { Key.char($0) }
    private static func chars(_ text: String) -> [Key] { text.map { Key.char($0) } }

    static let bindings: [KeyBinding] = [
        KeyBinding(context: .meter, group: "Tune", keys: digits, actions: (0..<10).map { .bandStep($0, step) },
                   label: "1 … 9 0", help: "raise band 32 Hz … 16 kHz by 0.5 dB (0 is the tenth band, 16 kHz)",
                   bar: ("1…0", "band"), rank: 1),
        KeyBinding(context: .meter, group: "Tune", keys: shiftedDigits, actions: (0..<10).map { .bandStep($0, -step) },
                   label: "⇧1 … ⇧0", help: "lower it by 0.5 dB: ! @ # $ % ^ & * ( ) on a US layout",
                   bar: ("⇧", "down"), rank: 2),
        KeyBinding(context: .meter, group: "Tune", keys: chars("+=-_"), actions: [.preamp(step), .preamp(step), .preamp(-step), .preamp(-step)],
                   label: "+ -", help: "preamp ±0.5 dB (= and _ work too, no Shift needed)", bar: ("+−", "preamp"), rank: 9),
        KeyBinding(context: .meter, group: "Tune", keys: chars("bBtT"), actions: [.bass(step), .bass(-step), .treble(step), .treble(-step)],
                   label: "b B t T", help: "bass / treble shelf +0.5 dB, with Shift −0.5 dB", bar: ("b t", "bass/treble"), rank: 13),
        KeyBinding(context: .meter, group: "Tune", keys: chars("pP") + [.down, .up], actions: [.cyclePreset, .cyclePreset, .cyclePreset, .previousPreset],
                   label: "p ↓ ↑", help: "next preset (p, ↓) / previous one (↑), alphabetically, wrapping round",
                   bar: ("p", "preset"), rank: 10),
        KeyBinding(context: .meter, group: "Tune", keys: chars("cC"), actions: [.cycleComp],
                   label: "c", help: "compressor: off → gentle → night → off", bar: ("c", "comp"), rank: 14),
        KeyBinding(context: .meter, group: "Tune", keys: chars("vV"), actions: [.cycleColour, .colourAmount],
                   label: "v V", help: "colour: off → tape → tube → off, starting at 0.3 / raise the amount by 0.1, from 1 back to 0.1",
                   bar: ("v", "color"), rank: 15),
        KeyBinding(context: .meter, group: "Tune", keys: chars("uU"), actions: [.undo],
                   label: "u", help: "undo the last change made in this session, back to how it started", bar: ("u", "undo"), rank: 11),
        KeyBinding(context: .meter, group: "Tune", keys: chars("sS"), actions: [.startSave],
                   label: "s", help: "save the curve as a preset: type a name, Enter saves, Esc cancels", bar: ("s", "save"), rank: 12),

        KeyBinding(context: .meter, group: "Instruments", keys: chars("zZ"), actions: [.zones],
                   label: "z", help: "the instrument strip, on and off", bar: ("z", "zones"), rank: 3,
                   state: { $0.strip ? "on" : "off" }),
        KeyBinding(context: .meter, group: "Instruments", keys: chars("iI"), actions: [.instruments],
                   label: "i", help: "the instrument table: ranges in Hz, the bands each touches, knob gains", bar: ("i", "instruments"), rank: 4),
        KeyBinding(context: .meter, group: "Instruments", keys: chars("]\t}[{"),
                   actions: [.focusNext, .focusNext, .focusNext, .focusPrevious, .focusPrevious],
                   label: "] Tab [", help: "focus the next / previous instrument", bar: ("[ ]", "focus"), rank: 5),
        KeyBinding(context: .meter, group: "Instruments", keys: [.right] + chars(".>") + [.left] + chars(",<"),
                   actions: [.knob(step), .knob(step), .knob(step), .knob(-step), .knob(-step), .knob(-step)],
                   label: "→ ←", help: "the focused instrument's knob ±0.5 dB (. and , work too, no Shift needed)",
                   bar: ("← →", "knob"), rank: 6, when: { $0.focused }),
        KeyBinding(context: .meter, group: "Instruments", keys: chars("lL"), actions: [.listen],
                   label: "l", help: "listen to the focused instrument alone, and back", bar: ("l", "listen"), rank: 7,
                   state: { $0.listening ? "on" : "off" }, when: { $0.focused }),
        KeyBinding(context: .meter, group: "Instruments", keys: [.esc], actions: [.unfocus],
                   label: "Esc", help: "leave the focus (and stop listening)", bar: ("Esc", "unfocus"), rank: 8, when: { $0.focused }),

        KeyBinding(context: .meter, group: "Screen", keys: chars("mM"), actions: [.mouse],
                   label: "m", help: "mouse on and off, remembered as tui.mouse in eq.json; on, the wheel scrolls these lists",
                   bar: ("m", "mouse"), rank: 16, state: { $0.mouse ? "on" : "off" }),
        KeyBinding(context: .meter, group: "Screen", keys: chars(";") + [.char("\u{10}")], actions: [.palette],
                   label: "; Ctrl-P", help: "the command palette; the key is kept for it, the palette is not here yet"),
        KeyBinding(context: .meter, group: "Screen", keys: chars("?hH"), actions: [.help],
                   label: "? h", help: "the list of every key, over the meter; ?, Esc or q closes it", bar: ("?", "keys")),
        KeyBinding(context: .meter, group: "Screen", keys: chars("qQ"), actions: [.quit],
                   label: "q", help: "quit", bar: ("q", "quit")),

        KeyBinding(context: .help, group: "Keys", keys: [.up, .char("k"), .wheelUp, .down, .char("j"), .wheelDown],
                   actions: [.scrollUp, .scrollUp, .scrollUp, .scrollDown, .scrollDown, .scrollDown],
                   label: "↑ ↓ j k", help: "scroll", bar: ("↑↓", "scroll"), rank: 1),
        KeyBinding(context: .help, group: "Keys", keys: chars("?hHqQ") + [.esc], actions: [.closeModal],
                   label: "? Esc q", help: "close", bar: ("Esc", "close")),

        KeyBinding(context: .instruments, group: "Instruments", keys: [.up, .char("k"), .wheelUp, .down, .char("j"), .wheelDown],
                   actions: [.scrollUp, .scrollUp, .scrollUp, .scrollDown, .scrollDown, .scrollDown],
                   label: "↑ ↓ j k", help: "scroll", bar: ("↑↓", "scroll"), rank: 1),
        KeyBinding(context: .instruments, group: "Instruments", keys: chars("iIqQ") + [.esc], actions: [.closeModal],
                   label: "i Esc q", help: "close", bar: ("Esc", "close")),

        KeyBinding(context: .prompt, group: "Save as", keys: [.char("\n")], actions: [nil],
                   label: "Enter", help: "save", bar: ("Enter", "save")),
        KeyBinding(context: .prompt, group: "Save as", keys: [.esc], actions: [nil],
                   label: "Esc", help: "cancel", bar: ("Esc", "cancel")),

        KeyBinding(context: .global, group: "Screen", keys: [.char("\u{03}")], actions: [.quit],
                   label: "Ctrl-C", help: "quit, from the lists too"),
    ]

    /// Where a Russian twin lands on a key another binding of the same context has on a US
    /// layout, the US meaning wins, on purpose; the test fails on any landing not listed here.
    static let collisions: [(context: KeyContext, key: Key, twinOf: Key, note: String)] = [
        (.meter, .char("?"), .char("&"), "⇧7 types ?, which is the key list: lower 2 kHz from a US layout"),
        (.meter, .char(";"), .char("$"), "⇧4 types ;, the palette: lower 250 Hz from a US layout"),
        (.meter, .char(","), .char("?"), "the ? key types , which turns the knob down: h (р) is the key list"),
    ]

    private static let lookup: [KeyContext: [Key: WatchAction]] = {
        var table: [KeyContext: [Key: WatchAction]] = [:]
        for binding in bindings {
            for (index, key) in binding.keys.enumerated() {
                guard let action = binding.action(at: index) else { continue }
                table[binding.context, default: [:]][key] = action
            }
        }
        for binding in bindings {
            for (index, key) in binding.keys.enumerated() {
                guard let action = binding.action(at: index), let twin = PhysicalKeys.twin(key),
                      table[binding.context]?[twin] == nil else { continue }
                table[binding.context, default: [:]][twin] = action
            }
        }
        return table
    }()

    static func action(for key: Key, in context: KeyContext) -> WatchAction? {
        lookup[context]?[key] ?? lookup[.global]?[key]
    }

    static func bindings(in context: KeyContext) -> [KeyBinding] { bindings.filter { $0.context == context } }

    /// The keys a Russian layout reaches this binding with, where they differ from the US ones.
    static func twins(_ binding: KeyBinding) -> [Key] {
        binding.keys.enumerated().compactMap { index, key in
            guard let twin = PhysicalKeys.twin(key), let action = binding.action(at: index),
                  lookup[binding.context]?[twin] == action else { return nil }
            return twin
        }
    }
}

enum Keybar {
    static let separator = "  "

    /// Entries most useful first; whole entries drop from the right, highest rank first, until
    /// the line fits. The unranked ones (`? keys`, `q quit`, `Esc close`) stay; `compact` keeps
    /// only them.
    static func line(_ context: KeyContext, state: KeyState, width: Int, compact: Bool = false) -> String {
        var entries = KeyTable.bindings(in: context).filter { $0.bar != nil && ($0.when?(state) ?? true) && !(compact && $0.rank > 0) }
        entries.sort { ($0.rank == 0 ? Int.max : $0.rank) < ($1.rank == 0 ? Int.max : $1.rank) }
        func text(_ binding: KeyBinding, painted: Bool) -> String {
            guard let bar = binding.bar else { return "" }
            let words = [bar.text] + (binding.state.map { [$0(state)] } ?? [])
            return (painted ? Paint.ink(.bold, bar.key) : bar.key) + " " + words.joined(separator: " ")
        }
        func plain() -> Int { TerminalText.width(entries.map { text($0, painted: false) }.joined(separator: separator)) }
        while plain() > width, let drop = entries.indices.filter({ entries[$0].rank > 0 }).max(by: { entries[$0].rank < entries[$1].rank }) {
            entries.remove(at: drop)
        }
        while plain() > width, entries.count > 1 { entries.removeFirst() }
        let line = entries.map { text($0, painted: true) }.joined(separator: separator)
        return plain() > width ? TerminalText.prefix(entries.map { text($0, painted: false) }.joined(separator: separator), columns: max(width, 0)) : line
    }
}

/// The full list the help overlay shows, grouped, and the README's key table.
enum KeyHelp {
    static let contexts: [KeyContext] = [.meter, .global]

    static func lines() -> [(key: String, text: String)] {
        var result: [(key: String, text: String)] = []
        var group: String?
        for binding in KeyTable.bindings where contexts.contains(binding.context) {
            if binding.group != group {
                if group != nil { result.append(("", "")) }
                group = binding.group
                result.append((binding.group, ""))
            }
            result.append((binding.label, binding.help))
        }
        result += [("", ""), ("Russian layout", ""), ("", "the same physical keys: й quits, я is zones, х ъ focus")]
        result += KeyTable.collisions.map { ("", $0.note) }
        return result
    }

    /// The Markdown table under README "Keys", generated from the same bindings and checked by a test.
    static func markdown() -> String {
        var rows = ["| Key | Russian | Action |", "| --- | --- | --- |"]
        for binding in KeyTable.bindings where contexts.contains(binding.context) {
            let keys = binding.label.split(separator: " ").map { $0 == "…" ? "…" : "`\($0)`" }.joined(separator: " ")
            let twins = KeyTable.twins(binding).map { "`\($0.name)`" }.joined(separator: " ")
            rows.append("| \(keys) | \(twins) | \(binding.help) |")
        }
        return rows.joined(separator: "\n")
    }
}
