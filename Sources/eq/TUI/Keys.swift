import EQTerm
import Foundation

/// A key once its escape sequence is decoded. Tab, Enter, Ctrl-C, Ctrl-P and Ctrl-Z are characters.
enum Key: Hashable {
    case char(Character)
    case up, down, right, left, esc
    case shiftUp, shiftDown, altUp, altDown, backTab, delete
    case pageUp, pageDown, home, end
    case wheelUp, wheelDown

    /// The key a context without a binding of its own for this one takes it as.
    var plain: Key? {
        switch self {
        case .shiftUp, .altUp: return .up
        case .shiftDown, .altDown: return .down
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .char("\t"): return "Tab"
        case .char("\n"): return "Enter"
        case .char(" "): return "Space"
        case .char("\u{03}"): return "Ctrl-C"
        case .char("\u{10}"): return "Ctrl-P"
        case .char("\u{1A}"): return "Ctrl-Z"
        case .char("\u{7F}"): return "Backspace"
        case .char(let c): return String(c)
        case .up: return "↑"
        case .down: return "↓"
        case .right: return "→"
        case .left: return "←"
        case .esc: return "Esc"
        case .shiftUp: return "⇧↑"
        case .shiftDown: return "⇧↓"
        case .altUp: return "Alt↑"
        case .altDown: return "Alt↓"
        case .backTab: return "⇧Tab"
        case .delete: return "Del"
        case .pageUp: return "PgUp"
        case .pageDown: return "PgDn"
        case .home: return "Home"
        case .end: return "End"
        case .wheelUp: return "wheel up"
        case .wheelDown: return "wheel down"
        }
    }
}

/// Where a key is looked up: a view, or the modal on top of it. `global` is searched after any
/// of them, so a view's own key shadows it.
enum KeyContext: CaseIterable {
    case meter, tune, instruments, presets, devices, filters, apps, system, history, events
    /// The Filters view while a filter's fields are being changed in place.
    case fields
    case help, prompt, entry, rename, confirm, form, go, palette, pane, filter, picker, search
    case global

    var isView: Bool { [.meter, .tune, .instruments, .presets, .devices, .filters, .fields, .apps, .system, .history, .events].contains(self) }
}

/// What the keybar needs to know to show a key's state, or whether to show it at all.
struct KeyState: Equatable {
    var strip = false
    var focused = false
    var listening = false
    var mouse = false
    var paused = false
    var running = false
    var diff = false
    var editing = false
    /// Esc has a view to go back to, or a filter to clear first.
    var back = false
    /// Apps: the rules are followed. System: eq.json asks for driver mode.
    var following = false
    var driver = false
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
    /// The name the command palette offers the first action under.
    var palette: String? = nil

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

/// The one table of keys: it drives what a key does, the keybar, the help overlay, the command
/// palette's named actions and the README's key table.
enum KeyTable {
    static let step = 0.5
    static let coarse = 3.0
    static let fine = 0.1
    private static let digits = "1234567890".map { Key.char($0) }
    private static let shiftedDigits = "!@#$%^&*()".map { Key.char($0) }
    private static func chars(_ text: String) -> [Key] { text.map { Key.char($0) } }
    private static let up: [Key] = [.up, .char("k"), .wheelUp]
    private static let down: [Key] = [.down, .char("j"), .wheelDown]
    private static let scroll = Array(repeating: WatchAction.scrollUp, count: 3) + Array(repeating: WatchAction.scrollDown, count: 3)
    private static let typing = chars("=0123456789.-")
    private static let typed = typing.map { key -> WatchAction? in
        guard case .char(let c) = key else { return nil }
        return .fieldEntry(c == "=" ? "" : String(c))
    }

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
                   label: "b B t T", help: "bass / treble shelf +0.5 dB, with Shift −0.5 dB", bar: ("b t", "bass/treble"), rank: 14),
        KeyBinding(context: .meter, group: "Tune", keys: chars("pP") + [.down, .up], actions: [.cyclePreset, .cyclePreset, .cyclePreset, .previousPreset],
                   label: "p ↓ ↑", help: "next preset (p, ↓) / previous one (↑), alphabetically, wrapping round",
                   bar: ("p", "preset"), rank: 10),
        KeyBinding(context: .meter, group: "Tune", keys: chars("cC"), actions: [.cycleComp],
                   label: "c", help: "compressor: off → gentle → night → off", bar: ("c", "comp"), rank: 15),
        KeyBinding(context: .meter, group: "Tune", keys: chars("vV"), actions: [.cycleColour, .colourAmount],
                   label: "v V", help: "colour: off → tape → tube → off, starting at 0.3 / raise the amount by 0.1, from 1 back to 0.1",
                   bar: ("v", "color"), rank: 16),
        KeyBinding(context: .meter, group: "Tune", keys: chars("sS"), actions: [.startSave],
                   label: "s", help: "save the curve as a preset: type a name, Enter saves, Esc cancels", bar: ("s", "save"), rank: 12),

        KeyBinding(context: .meter, group: "Instruments", keys: chars("zZ"), actions: [.zones],
                   label: "z", help: "the instrument strip, on and off", bar: ("z", "zones"), rank: 3,
                   state: { $0.strip ? "on" : "off" }, palette: "zones"),
        KeyBinding(context: .meter, group: "Instruments", keys: chars("iI"), actions: [.go(.instruments)],
                   label: "i", help: "the Instruments view: ranges in Hz, the bands each touches, knob gains, levels; Esc comes back",
                   bar: ("i", "instruments"), rank: 4),
        KeyBinding(context: .meter, group: "Instruments", keys: chars("]\t}[{"),
                   actions: [.focusNext, .focusNext, .focusNext, .focusPrevious, .focusPrevious],
                   label: "] Tab [", help: "focus the next / previous instrument", bar: ("[ ]", "focus"), rank: 5),
        KeyBinding(context: .meter, group: "Instruments", keys: [.right] + chars(".>") + [.left] + chars(",<"),
                   actions: [.knob(step), .knob(step), .knob(step), .knob(-step), .knob(-step), .knob(-step)],
                   label: "→ ←", help: "the focused instrument's knob ±0.5 dB (. and , work too, no Shift needed)",
                   bar: ("← →", "knob"), rank: 6, when: { $0.focused }),
        KeyBinding(context: .meter, group: "Instruments", keys: chars("lL"), actions: [.listen],
                   label: "l", help: "listen to the focused instrument alone, and back", bar: ("l", "listen"), rank: 7,
                   state: { $0.listening ? "on" : "off" }, when: { $0.focused }, palette: "listen"),
        KeyBinding(context: .meter, group: "Instruments", keys: [.esc], actions: [.unfocus],
                   label: "Esc", help: "leave the focus (and stop listening); with no focus, back to the view before",
                   bar: ("Esc", "unfocus"), rank: 8, when: { $0.focused }),

        KeyBinding(context: .tune, group: "Tune view", keys: [.left, .right], actions: [.tuneSelect(-1), .tuneSelect(1)],
                   label: "← →", help: "select the band, or the preamp, bass, treble, tilt, compressor, colour and its amount after them",
                   bar: ("← →", "select"), rank: 1),
        KeyBinding(context: .tune, group: "Tune view", keys: up + down, actions: [.nudge(step), .nudge(step), .nudge(step), .nudge(-step), .nudge(-step), .nudge(-step)],
                   label: "↑ ↓ k j", help: "the selected control ±0.5 dB (tilt ±0.1 dB/octave, amount ±0.1, a mode the next one); lowers a band on any layout",
                   bar: ("↑ ↓", "±0.5"), rank: 2),
        KeyBinding(context: .tune, group: "Tune view", keys: [.shiftUp, .pageUp, .shiftDown, .pageDown],
                   actions: [.nudge(coarse), .nudge(coarse), .nudge(-coarse), .nudge(-coarse)],
                   label: "⇧↑ ⇧↓ PgUp PgDn", help: "±3 dB (tilt ±0.5, amount ±0.3)", bar: ("⇧↑↓", "±3"), rank: 3),
        KeyBinding(context: .tune, group: "Tune view", keys: [.altUp, .altDown], actions: [.nudge(fine), .nudge(-fine)],
                   label: "Alt↑ Alt↓", help: "±0.1 dB (tilt ±0.05, amount ±0.05)", bar: ("Alt↑↓", "±0.1"), rank: 7),
        KeyBinding(context: .tune, group: "Tune view", keys: [.char("\n")], actions: [.tuneEntry],
                   label: "Enter", help: "type the selected control's value in the message row: -3, 2.5, night, tape", bar: ("Enter", "exact"), rank: 4),
        KeyBinding(context: .tune, group: "Tune view", keys: [.char("0"), .char("\u{7F}"), .delete], actions: [.tuneReset],
                   label: "0 Backspace Del", help: "the selected control back to 0, a mode or the colour off", bar: ("0 Del", "reset"), rank: 5),
        KeyBinding(context: .tune, group: "Tune view", keys: [.char("\t"), .backTab], actions: [.tuneGroup(1), .tuneGroup(-1)],
                   label: "Tab ⇧Tab", help: "the next / previous group: bands, chain (preamp, tone, tilt), dynamics; each keeps its selection",
                   bar: ("Tab", "group"), rank: 6),
        KeyBinding(context: .tune, group: "Tune view", keys: Array(digits.prefix(9)), actions: (0..<9).map { .bandStep($0, step) },
                   label: "1 … 9", help: "raise band 32 Hz … 8 kHz by 0.5 dB, as on the meter; 0 resets here, so 16 kHz goes up with ↑"),
        KeyBinding(context: .tune, group: "Tune view", keys: shiftedDigits, actions: (0..<10).map { .bandStep($0, -step) },
                   label: "⇧1 … ⇧0", help: "lower band 32 Hz … 16 kHz by 0.5 dB, as on the meter"),
        KeyBinding(context: .tune, group: "Tune view", keys: chars("sS"), actions: [.startSave],
                   label: "s", help: "save the curve as a preset", bar: ("s", "save"), rank: 9),
        KeyBinding(context: .tune, group: "Tune view", keys: chars("dD"), actions: [.otherDevice(1), .otherDevice(-1)],
                   label: "d D", help: "edit the next / previous device's curve, playing or not; the playing one comes first",
                   bar: ("d", "device"), rank: 10),
        KeyBinding(context: .tune, group: "Tune view", keys: [.esc], actions: [.back],
                   label: "Esc", help: "back to the view before", bar: ("Esc", "back"), rank: 8, when: { $0.back }),

        KeyBinding(context: .instruments, group: "Instruments view", keys: up + down, actions: scroll,
                   label: "↑ ↓ j k", help: "move between the instruments", bar: ("↑↓", "move"), rank: 1),
        KeyBinding(context: .instruments, group: "Instruments view", keys: [.home, .pageUp, .end, .pageDown],
                   actions: [.top, .top, .bottom, .bottom], label: "Home End", help: "the first / the last instrument"),
        KeyBinding(context: .instruments, group: "Instruments view", keys: [.char("\n")], actions: [.focusInMeter],
                   label: "Enter", help: "focus the instrument on the meter", bar: ("Enter", "focus"), rank: 2),
        KeyBinding(context: .instruments, group: "Instruments view", keys: [.right] + chars(".>") + [.left] + chars(",<"),
                   actions: [.knob(step), .knob(step), .knob(step), .knob(-step), .knob(-step), .knob(-step)],
                   label: "→ ←", help: "its knob ±0.5 dB (. and , work too)", bar: ("← →", "knob"), rank: 3),
        KeyBinding(context: .instruments, group: "Instruments view", keys: chars("lL"), actions: [.listen],
                   label: "l", help: "listen to it alone, and back; it becomes the meter's focus", bar: ("l", "listen"), rank: 4,
                   state: { $0.listening ? "on" : "off" }),
        KeyBinding(context: .instruments, group: "Instruments view", keys: [.esc], actions: [.back],
                   label: "Esc", help: "back to the view before", bar: ("Esc", "back"), rank: 5, when: { $0.back }),

        KeyBinding(context: .presets, group: "Presets view", keys: up + down, actions: scroll,
                   label: "↑ ↓ j k", help: "move between the presets", bar: ("↑↓", "move"), rank: 1),
        KeyBinding(context: .presets, group: "Presets view", keys: [.pageUp, .pageDown, .home, .end],
                   actions: [.pageUp, .pageDown, .top, .bottom], label: "PgUp PgDn Home End", help: "a page up / down, the first / the last"),
        KeyBinding(context: .presets, group: "Presets view", keys: [.char("\n")], actions: [.primary],
                   label: "Enter", help: "play it on the current device, as eq preset use does", bar: ("Enter", "apply"), rank: 2),
        KeyBinding(context: .presets, group: "Presets view", keys: chars("sS"), actions: [.startSave],
                   label: "s", help: "save the current device's curve as a preset: type its name in the message row, Enter saves",
                   bar: ("s", "save as"), rank: 3),
        KeyBinding(context: .presets, group: "Presets view", keys: chars("rR"), actions: [.startRename],
                   label: "r", help: "rename it; devices and app rules that name it follow", bar: ("r", "rename"), rank: 4),
        KeyBinding(context: .presets, group: "Presets view", keys: chars("dD"), actions: [.startDelete],
                   label: "d", help: "delete it once y answers the question in the message row; devices that used it keep the curve",
                   bar: ("d", "delete"), rank: 5),
        KeyBinding(context: .presets, group: "Presets view", keys: chars("vV"), actions: [.toggleDiff],
                   label: "v", help: "compare it with the current device's curve: both drawn, and what differs listed", bar: ("v", "diff"),
                   rank: 6, state: { $0.diff ? "on" : "off" }),
        KeyBinding(context: .presets, group: "Presets view", keys: chars("/"), actions: [.search],
                   label: "/", help: "jump to the first preset whose name has what you type", bar: ("/", "search"), rank: 7),
        KeyBinding(context: .presets, group: "Presets view", keys: [.esc], actions: [.back],
                   label: "Esc", help: "back to the view before", bar: ("Esc", "back"), rank: 8, when: { $0.back }),

        KeyBinding(context: .devices, group: "Devices view", keys: up + down, actions: scroll,
                   label: "↑ ↓ j k", help: "move between the outputs and the profiles of devices not connected", bar: ("↑↓", "move"), rank: 1),
        KeyBinding(context: .devices, group: "Devices view", keys: [.pageUp, .pageDown, .home, .end],
                   actions: [.pageUp, .pageDown, .top, .bottom], label: "PgUp PgDn Home End", help: "a page up / down, the first / the last"),
        KeyBinding(context: .devices, group: "Devices view", keys: [.char("\n")], actions: [.primary],
                   label: "Enter", help: "make it the system's output, as eq device use does; in driver mode the EQ device plays on it instead",
                   bar: ("Enter", "use"), rank: 2),
        KeyBinding(context: .devices, group: "Devices view", keys: chars("cC"), actions: [.copyHere],
                   label: "c", help: "copy the current device's curve to it, as eq device copy --to does", bar: ("c", "copy here"), rank: 3),
        KeyBinding(context: .devices, group: "Devices view", keys: chars("eE"), actions: [.editInTune],
                   label: "e", help: "edit its curve in Tune, whether it plays or not", bar: ("e", "edit"), rank: 4),
        KeyBinding(context: .devices, group: "Devices view", keys: chars("/"), actions: [.search],
                   label: "/", help: "jump to the first device whose name has what you type", bar: ("/", "search"), rank: 5),
        KeyBinding(context: .devices, group: "Devices view", keys: [.esc], actions: [.back],
                   label: "Esc", help: "back to the view before", bar: ("Esc", "back"), rank: 6, when: { $0.back }),

        KeyBinding(context: .filters, group: "Filters view", keys: up + down, actions: scroll,
                   label: "↑ ↓ j k", help: "move between the filters", bar: ("↑↓", "move"), rank: 1),
        KeyBinding(context: .filters, group: "Filters view", keys: [.pageUp, .pageDown, .home, .end],
                   actions: [.pageUp, .pageDown, .top, .bottom], label: "PgUp PgDn Home End", help: "a page up / down, the first / the last"),
        KeyBinding(context: .filters, group: "Filters view", keys: [.char("\n"), .right], actions: [.editFields],
                   label: "Enter →", help: "change the filter in place: ← → pick its type, frequency, gain or Q, ↑ ↓ change it",
                   bar: ("Enter", "edit"), rank: 2),
        KeyBinding(context: .filters, group: "Filters view", keys: chars("aA"), actions: [.startAdd],
                   label: "a", help: "add a filter: a row under the others to set its type, frequency, gain and Q, Enter adds it",
                   bar: ("a", "add"), rank: 3, palette: "add filter"),
        KeyBinding(context: .filters, group: "Filters view", keys: chars("dD"), actions: [.startDelete],
                   label: "d", help: "remove it once y answers the question in the message row", bar: ("d", "delete"), rank: 4),
        KeyBinding(context: .filters, group: "Filters view", keys: [.esc], actions: [.back],
                   label: "Esc", help: "back to the view before", bar: ("Esc", "back"), rank: 5, when: { $0.back }),

        KeyBinding(context: .fields, group: "A filter's fields", keys: [.left, .right], actions: [.field(-1), .field(1)],
                   label: "← →", help: "the type, the frequency, the gain or Q", bar: ("← →", "field"), rank: 1),
        KeyBinding(context: .fields, group: "A filter's fields", keys: up + down,
                   actions: [.nudge(step), .nudge(step), .nudge(step), .nudge(-step), .nudge(-step), .nudge(-step)],
                   label: "↑ ↓ k j", help: "change it, saved at once: the next type, a sixth of an octave, 0.5 dB, Q 0.1",
                   bar: ("↑ ↓", "change"), rank: 2),
        KeyBinding(context: .fields, group: "A filter's fields", keys: [.shiftUp, .pageUp, .shiftDown, .pageDown],
                   actions: [.nudge(coarse), .nudge(coarse), .nudge(-coarse), .nudge(-coarse)],
                   label: "⇧↑ ⇧↓ PgUp PgDn", help: "an octave, 3 dB, Q 1", bar: ("⇧↑↓", "coarse"), rank: 4),
        KeyBinding(context: .fields, group: "A filter's fields", keys: [.altUp, .altDown], actions: [.nudge(fine), .nudge(-fine)],
                   label: "Alt↑ Alt↓", help: "a 24th of an octave, 0.1 dB, Q 0.01", bar: ("Alt↑↓", "fine"), rank: 5),
        KeyBinding(context: .fields, group: "A filter's fields", keys: [.char("\n"), .esc], actions: [.editFields],
                   label: "Enter Esc", help: "done: ↑ ↓ move between the filters again", bar: ("Esc", "done"), rank: 3),
        KeyBinding(context: .fields, group: "A filter's fields", keys: typing, actions: typed,
                   label: "= 0 … 9", help: "type the field's value in the message row, as eq filter set takes it: 3k, -2.5, 0.7, lowshelf; Enter sets it",
                   bar: ("=", "type"), rank: 6),

        KeyBinding(context: .form, group: "New filter", keys: [.left, .right, .char("\t"), .backTab],
                   actions: [.field(-1), .field(1), .field(1), .field(-1)],
                   label: "← → Tab", help: "the type, the frequency, the gain or Q", bar: ("← →", "field"), rank: 1),
        KeyBinding(context: .form, group: "New filter", keys: up + down,
                   actions: [.nudge(step), .nudge(step), .nudge(step), .nudge(-step), .nudge(-step), .nudge(-step)],
                   label: "↑ ↓ k j", help: "change it: the next type, a sixth of an octave, 0.5 dB, Q 0.1", bar: ("↑ ↓", "change"), rank: 2),
        KeyBinding(context: .form, group: "New filter", keys: [.shiftUp, .pageUp, .shiftDown, .pageDown, .altUp, .altDown],
                   actions: [.nudge(coarse), .nudge(coarse), .nudge(-coarse), .nudge(-coarse), .nudge(fine), .nudge(-fine)],
                   label: "⇧↑ ⇧↓ Alt↑ Alt↓", help: "coarse: an octave, 3 dB, Q 1; fine: a 24th of an octave, 0.1 dB, Q 0.01"),
        KeyBinding(context: .form, group: "New filter", keys: typing, actions: typed,
                   label: "= 0 … 9", help: "type the field's value: 3k, -2.5, 0.7, lowshelf", bar: ("=", "type"), rank: 3),
        KeyBinding(context: .form, group: "New filter", keys: [.char("\n")], actions: [.primary],
                   label: "Enter", help: "add it, as eq filter add does", bar: ("Enter", "add")),
        KeyBinding(context: .form, group: "New filter", keys: [.esc], actions: [.closeModal],
                   label: "Esc", help: "cancel", bar: ("Esc", "cancel")),

        KeyBinding(context: .apps, group: "Apps view", keys: up + down, actions: scroll,
                   label: "↑ ↓ j k", help: "move between the app rules", bar: ("↑↓", "move"), rank: 1),
        KeyBinding(context: .apps, group: "Apps view", keys: [.pageUp, .pageDown, .home, .end],
                   actions: [.pageUp, .pageDown, .top, .bottom], label: "PgUp PgDn Home End", help: "a page up / down, the first / the last"),
        KeyBinding(context: .apps, group: "Apps view", keys: [.char("\n")], actions: [.primary],
                   label: "Enter", help: "give the app another preset: pick one, Enter sets it, as eq app set does", bar: ("Enter", "preset"), rank: 2),
        KeyBinding(context: .apps, group: "Apps view", keys: chars("aA"), actions: [.startAdd],
                   label: "a", help: "add a rule: pick an app with audio open, or type its bundle ID or an installed app's name, then its preset",
                   bar: ("a", "add"), rank: 3),
        KeyBinding(context: .apps, group: "Apps view", keys: chars("dD"), actions: [.startDelete],
                   label: "d", help: "remove the rule once y answers the question in the message row, as eq app rm does", bar: ("d", "delete"), rank: 4),
        KeyBinding(context: .apps, group: "Apps view", keys: chars("oO"), actions: [.toggleApps],
                   label: "o", help: "follow the rules or not, as eq app on and eq app off do (experimental)", bar: ("o", "follow"), rank: 5,
                   state: { $0.following ? "on" : "off" }),
        KeyBinding(context: .apps, group: "Apps view", keys: chars("/"), actions: [.search],
                   label: "/", help: "jump to the first rule whose app or preset has what you type", bar: ("/", "search"), rank: 6),
        KeyBinding(context: .apps, group: "Apps view", keys: [.esc], actions: [.back],
                   label: "Esc", help: "back to the view before", bar: ("Esc", "back"), rank: 7, when: { $0.back }),

        KeyBinding(context: .system, group: "System view", keys: up + down, actions: scroll,
                   label: "↑ ↓ j k", help: "move between the doctor's checks; the chosen one's whole text shows under them", bar: ("↑↓", "move"), rank: 1),
        KeyBinding(context: .system, group: "System view", keys: [.pageUp, .pageDown, .home, .end],
                   actions: [.pageUp, .pageDown, .top, .bottom], label: "PgUp PgDn Home End", help: "a page up / down, the first / the last"),
        KeyBinding(context: .system, group: "System view", keys: chars("rR"), actions: [.refresh],
                   label: "r", help: "read the daemon's status again and run eq doctor again, beside the screen", bar: ("r", "refresh"), rank: 2),
        KeyBinding(context: .system, group: "System view", keys: chars("oO"), actions: [.switchMode],
                   label: "o", help: "switch to the other mode, as eq mode tap or eq mode driver does, once y answers what a dry run says; a switch that must install the driver first is left to a shell, where its password prompt belongs",
                   bar: ("o", "mode"), rank: 3, state: { $0.driver ? "→ tap" : "→ driver" }),
        KeyBinding(context: .system, group: "System view", keys: chars("/"), actions: [.search],
                   label: "/", help: "jump to the first check whose name or text has what you type", bar: ("/", "search"), rank: 4),
        KeyBinding(context: .system, group: "System view", keys: [.esc], actions: [.back],
                   label: "Esc", help: "back to the view before", bar: ("Esc", "back"), rank: 5, when: { $0.back }),

        KeyBinding(context: .history, group: "History view", keys: up + down, actions: scroll,
                   label: "↑ ↓ j k", help: "move between the saved versions, newest first", bar: ("↑↓", "move"), rank: 1),
        KeyBinding(context: .history, group: "History view", keys: [.pageUp, .pageDown, .home, .end],
                   actions: [.pageUp, .pageDown, .top, .bottom], label: "PgUp PgDn Home End", help: "a page up / down, the newest / the oldest"),
        KeyBinding(context: .history, group: "History view", keys: [.char("\n")], actions: [.primary],
                   label: "Enter", help: "make it the live config: eq undo or eq redo as many times as it takes, so nothing is lost and → comes back",
                   bar: ("Enter", "restore"), rank: 2),
        KeyBinding(context: .history, group: "History view", keys: [.left, .right], actions: [.historyStep(1), .historyStep(-1)],
                   label: "← →", help: "one version older / newer, as eq undo / eq redo do", bar: ("← →", "undo/redo"), rank: 3),
        KeyBinding(context: .history, group: "History view", keys: [.esc], actions: [.back],
                   label: "Esc", help: "back to the view before", bar: ("Esc", "back"), rank: 4, when: { $0.back }),

        KeyBinding(context: .events, group: "Events view", keys: up + down, actions: scroll,
                   label: "↑ ↓ j k", help: "scroll the log", bar: ("↑↓", "scroll"), rank: 1),
        KeyBinding(context: .events, group: "Events view", keys: [.pageUp, .pageDown, .home, .end],
                   actions: [.pageUp, .pageDown, .top, .bottom], label: "PgUp PgDn Home End",
                   help: "a page up / down, the oldest / the newest"),
        KeyBinding(context: .events, group: "Events view", keys: [.char(" ")], actions: [.pause],
                   label: "Space", help: "pause the log and go on; events keep arriving underneath, the panel counts them",
                   bar: ("Space", "pause"), rank: 2),
        KeyBinding(context: .events, group: "Events view", keys: chars("/"), actions: [.filter],
                   label: "/", help: "show only events whose kind or text has what you type", bar: ("/", "filter"), rank: 3),
        KeyBinding(context: .events, group: "Events view", keys: [.esc], actions: [.back],
                   label: "Esc", help: "clear the filter, then back to the view before", bar: ("Esc", "back"), rank: 4, when: { $0.back }),

        KeyBinding(context: .global, group: "Every view", keys: chars("gG"), actions: [.goMenu],
                   label: "g", help: "go to a view: m meter, t tune, i instruments, p presets, d devices, f filters, a apps, s system, h history, e events; a menu lists them",
                   bar: ("g", "go"), rank: 18),
        KeyBinding(context: .global, group: "Every view", keys: chars(";") + [.char("\u{10}")], actions: [.palette],
                   label: "; Ctrl-P", help: "the command palette: any eq command, run beside the screen", bar: (";", "cmd"), rank: 19),
        KeyBinding(context: .global, group: "Every view", keys: chars("uU"), actions: [.undo],
                   label: "u", help: "undo the last change made in this session, back to how it started", bar: ("u", "undo"), rank: 11,
                   palette: "undo in this session"),
        KeyBinding(context: .global, group: "Every view", keys: chars("mM"), actions: [.mouse],
                   label: "m", help: "mouse on and off, remembered as tui.mouse in eq.json; on, a click on a tab opens it, a click on a band or a control in Tune or on a list's row selects it, and the wheel scrolls a list or steps what it is over",
                   bar: ("m", "mouse"), rank: 17, state: { $0.mouse ? "on" : "off" }, palette: "mouse"),
        KeyBinding(context: .global, group: "Every view", keys: chars("?hH"), actions: [.help],
                   label: "? h", help: "the list of every key; ?, Esc or q closes it", bar: ("?", "keys"), palette: "keys"),
        KeyBinding(context: .global, group: "Every view", keys: chars("qQ"), actions: [.quit],
                   label: "q", help: "quit", bar: ("q", "quit"), palette: "quit"),
        KeyBinding(context: .global, group: "Every view", keys: [.char("\u{03}")], actions: [.quit],
                   label: "Ctrl-C", help: "quit, from the lists too"),
        KeyBinding(context: .global, group: "Every view", keys: [.char("\u{1A}")], actions: [.suspend],
                   label: "Ctrl-Z", help: "suspend to the shell; fg brings the screen back as it was"),
        KeyBinding(context: .global, group: "Look", keys: chars("yY"), actions: [.nextLook, .nextPalette],
                   label: "y Y", help: "next look: studio → console / next palette: ink → paper → brass; saved as tui.look and tui.palette",
                   bar: ("y", "look"), rank: 13, palette: "look"),

        KeyBinding(context: .go, group: "Go to", keys: chars("m"), actions: [.go(.meter)], label: "g m",
                   help: "the meter", bar: ("m", "meter"), rank: 1, palette: "go meter"),
        KeyBinding(context: .go, group: "Go to", keys: chars("t"), actions: [.go(.tune)], label: "g t",
                   help: "the curve to edit: bands as sliders, preamp, tone, dynamics", bar: ("t", "tune"), rank: 2, palette: "go tune"),
        KeyBinding(context: .go, group: "Go to", keys: chars("i"), actions: [.go(.instruments)], label: "g i",
                   help: "the instruments, their knobs and levels", bar: ("i", "instruments"), rank: 3, palette: "go instruments"),
        KeyBinding(context: .go, group: "Go to", keys: chars("p"), actions: [.go(.presets)], label: "g p",
                   help: "the presets: apply, save as, rename, delete, compare", bar: ("p", "presets"), rank: 4, palette: "go presets"),
        KeyBinding(context: .go, group: "Go to", keys: chars("d"), actions: [.go(.devices)], label: "g d",
                   help: "the outputs and their curves: use one, copy the curve to one, edit one", bar: ("d", "devices"), rank: 5,
                   palette: "go devices"),
        KeyBinding(context: .go, group: "Go to", keys: chars("f"), actions: [.go(.filters)], label: "g f",
                   help: "the current device's parametric filters: add, change, remove", bar: ("f", "filters"), rank: 6, palette: "go filters"),
        KeyBinding(context: .go, group: "Go to", keys: chars("a"), actions: [.go(.apps)], label: "g a",
                   help: "the app rules: which preset plays while an app does, and the routes", bar: ("a", "apps"), rank: 7, palette: "go apps"),
        KeyBinding(context: .go, group: "Go to", keys: chars("s"), actions: [.go(.system)], label: "g s",
                   help: "the daemon, the mode and the driver's health, and eq doctor", bar: ("s", "system"), rank: 8, palette: "go system"),
        KeyBinding(context: .go, group: "Go to", keys: chars("h"), actions: [.go(.history)], label: "g h",
                   help: "the saved versions of eq.json: restore one, step with undo and redo", bar: ("h", "history"), rank: 9,
                   palette: "go history"),
        KeyBinding(context: .go, group: "Go to", keys: chars("e"), actions: [.go(.events)], label: "g e",
                   help: "the daemon's events as they happen", bar: ("e", "events"), rank: 10, palette: "go events"),
        KeyBinding(context: .go, group: "Go to", keys: [.esc], actions: [.closeModal], label: "Esc",
                   help: "stay; any other key does too", bar: ("Esc", "cancel")),

        KeyBinding(context: .palette, group: "Command palette", keys: [.char("\n")], actions: [nil],
                   label: "Enter", help: "run the chosen line: an eq command as a child process, or a screen action", bar: ("Enter", "run")),
        KeyBinding(context: .palette, group: "Command palette", keys: [.char("\t")], actions: [nil],
                   label: "Tab", help: "take the chosen suggestion into the line", bar: ("Tab", "complete"), rank: 1),
        KeyBinding(context: .palette, group: "Command palette", keys: [.up, .down], actions: [nil],
                   label: "↑ ↓", help: "choose a suggestion; with the line empty, the last commands run come first",
                   bar: ("↑↓", "choose"), rank: 2),
        KeyBinding(context: .palette, group: "Command palette", keys: [.esc], actions: [nil],
                   label: "Esc", help: "close it", bar: ("Esc", "close")),

        KeyBinding(context: .pane, group: "Command output", keys: up + down, actions: scroll,
                   label: "↑ ↓ j k", help: "scroll", bar: ("↑↓", "scroll"), rank: 1),
        KeyBinding(context: .pane, group: "Command output", keys: [.char("\u{03}")], actions: [.stop],
                   label: "Ctrl-C", help: "stop the command", bar: ("Ctrl-C", "stop"), rank: 2, when: { $0.running }),
        KeyBinding(context: .pane, group: "Command output", keys: chars("qQ") + [.esc], actions: [.closeModal],
                   label: "Esc q", help: "close it; a command still running is stopped", bar: ("Esc", "close")),

        KeyBinding(context: .help, group: "Keys", keys: up + down, actions: scroll,
                   label: "↑ ↓ j k", help: "scroll", bar: ("↑↓", "scroll"), rank: 1),
        KeyBinding(context: .help, group: "Keys", keys: chars("/"), actions: [.filter],
                   label: "/", help: "show only the keys whose name or text has what you type", bar: ("/", "filter"), rank: 2),
        KeyBinding(context: .help, group: "Keys", keys: chars("?hHqQ") + [.esc], actions: [.closeModal],
                   label: "? Esc q", help: "close", bar: ("Esc", "close")),

        KeyBinding(context: .prompt, group: "Save as", keys: [.char("\n")], actions: [nil],
                   label: "Enter", help: "save", bar: ("Enter", "save")),
        KeyBinding(context: .prompt, group: "Save as", keys: [.esc], actions: [nil],
                   label: "Esc", help: "cancel", bar: ("Esc", "cancel")),

        KeyBinding(context: .rename, group: "Rename", keys: [.char("\n")], actions: [nil],
                   label: "Enter", help: "rename", bar: ("Enter", "rename")),
        KeyBinding(context: .rename, group: "Rename", keys: [.esc], actions: [nil],
                   label: "Esc", help: "cancel", bar: ("Esc", "cancel")),

        KeyBinding(context: .confirm, group: "Are you sure", keys: [.char("y"), .char("Y"), .char("\n")], actions: [nil],
                   label: "y Enter", help: "yes, do it", bar: ("y", "yes")),
        KeyBinding(context: .confirm, group: "Are you sure", keys: [.char("n"), .esc], actions: [nil],
                   label: "n Esc", help: "no; any other key keeps it too", bar: ("n", "no")),

        KeyBinding(context: .entry, group: "Value", keys: [.char("\n")], actions: [nil],
                   label: "Enter", help: "set it", bar: ("Enter", "set")),
        KeyBinding(context: .entry, group: "Value", keys: [.esc], actions: [nil],
                   label: "Esc", help: "cancel", bar: ("Esc", "cancel")),

        KeyBinding(context: .picker, group: "Pick", keys: [.char("\n")], actions: [nil],
                   label: "Enter", help: "take the chosen one; letters typed narrow the list, and an app not in it is taken as typed", bar: ("Enter", "pick")),
        KeyBinding(context: .picker, group: "Pick", keys: [.up, .down], actions: [nil],
                   label: "↑ ↓", help: "choose", bar: ("↑↓", "choose"), rank: 1),
        KeyBinding(context: .picker, group: "Pick", keys: [.esc], actions: [nil],
                   label: "Esc", help: "cancel", bar: ("Esc", "cancel")),

        KeyBinding(context: .search, group: "Search", keys: [.char("\n")], actions: [nil],
                   label: "Enter", help: "stay on the row found", bar: ("Enter", "stay")),
        KeyBinding(context: .search, group: "Search", keys: [.esc], actions: [nil],
                   label: "Esc", help: "back to the row before", bar: ("Esc", "back")),

        KeyBinding(context: .filter, group: "Filter", keys: [.char("\n")], actions: [nil],
                   label: "Enter", help: "keep the filter", bar: ("Enter", "keep")),
        KeyBinding(context: .filter, group: "Filter", keys: [.esc], actions: [nil],
                   label: "Esc", help: "drop it", bar: ("Esc", "clear")),
    ]

    /// Where a Russian twin lands on a key another binding of the same view (or of every view)
    /// has on a US layout, the US meaning wins, on purpose; the test fails on any landing not listed.
    static let collisions: [(context: KeyContext, key: Key, twinOf: Key, note: String)] = [
        (.meter, .char("?"), .char("&"), "⇧7 types ?, which is the key list: lower 2 kHz from a US layout"),
        (.meter, .char(";"), .char("$"), "⇧4 types ;, the palette: lower 250 Hz from a US layout"),
        (.meter, .char(","), .char("?"), "the ? key types , which turns the knob down: h (р) is the key list"),
        (.instruments, .char(","), .char("?"), "on the Instruments view that , turns the selected knob down too"),
        (.tune, .char("?"), .char("&"), "on the Tune view too ⇧7 is the key list: select 2 kHz and press ↓"),
        (.tune, .char(";"), .char("$"), "and ⇧4 the palette: select 250 Hz and press ↓"),
    ]

    private static let lookup: [KeyContext: [Key: WatchAction]] = {
        var direct: [KeyContext: [Key: WatchAction]] = [:]
        for binding in bindings {
            for (index, key) in binding.keys.enumerated() {
                guard let action = binding.action(at: index) else { continue }
                direct[binding.context, default: [:]][key] = action
            }
        }
        // A twin never takes a key its own context or every view has on a US layout.
        var table = direct
        for binding in bindings {
            for (index, key) in binding.keys.enumerated() {
                guard let action = binding.action(at: index), let twin = PhysicalKeys.twin(key),
                      table[binding.context]?[twin] == nil,
                      binding.context == .global || direct[.global]?[twin] == nil else { continue }
                table[binding.context, default: [:]][twin] = action
            }
        }
        return table
    }()

    static func action(for key: Key, in context: KeyContext) -> WatchAction? {
        lookup[context]?[key] ?? lookup[.global]?[key] ?? key.plain.flatMap { action(for: $0, in: context) }
    }

    static func bindings(in context: KeyContext) -> [KeyBinding] { bindings.filter { $0.context == context } }

    /// A view's own bindings, then those of every view whose keys it does not all take; worked
    /// out once, since the keybar asks every frame.
    static func effective(_ context: KeyContext) -> [KeyBinding] { effectiveTable[context] ?? [] }

    private static let effectiveTable: [KeyContext: [KeyBinding]] = Dictionary(uniqueKeysWithValues: KeyContext.allCases.map { context in
        let own = bindings(in: context)
        guard context.isView else { return (context, own) }
        let taken = Set(own.flatMap(\.keys))
        return (context, own + bindings(in: .global).filter { !Set($0.keys).isSubset(of: taken) })
    })

    /// The keys a Russian layout reaches this binding with, where they differ from the US ones.
    static func twins(_ binding: KeyBinding) -> [Key] {
        binding.keys.enumerated().compactMap { index, key in
            guard let twin = PhysicalKeys.twin(key), let action = binding.action(at: index),
                  lookup[binding.context]?[twin] == action else { return nil }
            // Every view's twin only where no view takes the key for itself.
            if binding.context == .global, KeyContext.allCases.contains(where: { $0.isView && lookup[$0]?[twin] != nil }) { return nil }
            return twin
        }
    }

    /// The screen actions the command palette offers by name.
    static var named: [(name: String, action: WatchAction, help: String)] {
        bindings.compactMap { binding in
            guard let name = binding.palette, let action = binding.action(at: 0) else { return nil }
            return (name, action, binding.help)
        }
    }
}

enum Keybar {
    static let separator = EQTerm.Keybar.separator
    /// A key drawn as a keycap takes a blank on either side of it.
    static let keycapPadding = 2

    /// The bindings on the bar in this context and state, a view's with those of every view
    /// (lazygit's rule), fitted by `EQTerm.Keybar`: `? keys`, `q quit`, `Esc close` stay;
    /// `compact` keeps only them.
    static func entries(_ context: KeyContext, state: KeyState, width: Int, compact: Bool = false, extra: Int = 0) -> [EQTerm.Keybar.Entry] {
        let entries = KeyTable.effective(context).compactMap { binding -> EQTerm.Keybar.Entry? in
            guard let bar = binding.bar, binding.when?(state) ?? true, !(compact && binding.rank > 0) else { return nil }
            let words = [bar.text] + (binding.state.map { [$0(state)] } ?? [])
            return EQTerm.Keybar.Entry(key: bar.key, text: words.joined(separator: " "), rank: binding.rank)
        }
        return EQTerm.Keybar.fit(entries, width: width, extra: extra)
    }

    static func line(_ context: KeyContext, state: KeyState, width: Int, compact: Bool = false) -> String {
        let shown = entries(context, state: state, width: width, compact: compact)
        let plain = shown.map(\.plain).joined(separator: separator)
        guard TerminalText.width(plain) <= width else { return TerminalText.prefix(plain, columns: max(width, 0)) }
        return plain
    }
}

/// The key list the help overlay shows for a view, grouped, and the README's key table.
enum KeyHelp {
    /// The README's order: every view first, then each view, then the menus.
    static let contexts: [KeyContext] = [.global, .meter, .tune, .instruments, .presets, .devices, .filters, .fields, .form, .apps, .picker,
                                         .system, .history, .events, .go, .palette, .pane, .help]

    /// A view's own keys and those of the rows and forms it opens.
    static func contexts(for view: KeyContext) -> [KeyContext] {
        let own: [KeyContext]
        switch view {
        case .presets: own = [.presets, .rename, .confirm, .search]
        case .filters, .fields: own = [.filters, .fields, .form, .confirm]
        case .apps: own = [.apps, .picker, .confirm, .search]
        case .system: own = [.system, .confirm, .search]
        case .devices: own = [.devices, .search]
        default: own = [view]
        }
        return own + [.global, .go, .palette, .pane, .help]
    }

    /// With a `filter`, only the keys whose keys, text or group have it, under their groups.
    static func lines(view: KeyContext = .meter, filter: String = "") -> [(key: String, text: String)] {
        func matches(_ texts: String...) -> Bool { filter.isEmpty || texts.contains { $0.localizedCaseInsensitiveContains(filter) } }
        var result: [(key: String, text: String)] = []
        var group: String?
        let shown = contexts(for: view)
        for context in shown {
            for binding in KeyTable.bindings(in: context) where matches(binding.label, binding.help, binding.group) {
                if binding.group != group {
                    if group != nil { result.append(("", "")) }
                    group = binding.group
                    result.append((binding.group, ""))
                }
                result.append((binding.label, binding.help))
            }
        }
        let layout = ["the same physical keys: й quits, я is zones, х ъ focus, ж the palette"]
            + KeyTable.collisions.filter { shown.contains($0.context) }.map(\.note)
        let notes = layout.filter { matches("Russian layout", $0) }
        if !notes.isEmpty { result += [("", ""), ("Russian layout", "")] + notes.map { ("", $0) } }
        return result
    }

    static func place(_ context: KeyContext) -> String {
        switch context {
        case .global: return "every view"
        case .meter: return "Meter"
        case .tune: return "Tune"
        case .instruments: return "Instruments"
        case .presets: return "Presets"
        case .devices: return "Devices"
        case .filters: return "Filters"
        case .fields: return "a filter's fields"
        case .form: return "new filter"
        case .apps: return "Apps"
        case .picker: return "an app or preset to pick"
        case .system: return "System"
        case .history: return "History"
        case .events: return "Events"
        case .help: return "the key list"
        case .go: return "after g"
        case .palette: return "palette"
        case .pane: return "command output"
        default: return ""
        }
    }

    /// The Markdown table under README "Keys", generated from the same bindings and checked by a test.
    static func markdown() -> String {
        var rows = ["| Key | Russian | Where | Action |", "| --- | --- | --- | --- |"]
        for context in contexts {
            for binding in KeyTable.bindings(in: context) {
                let keys = binding.label.split(separator: " ").map { $0 == "…" ? "…" : "`\($0)`" }.joined(separator: " ")
                let twins = KeyTable.twins(binding).map { "`\($0.name)`" }.joined(separator: " ")
                rows.append("| \(keys) | \(twins) | \(place(context)) | \(binding.help) |")
            }
        }
        return rows.joined(separator: "\n")
    }
}
