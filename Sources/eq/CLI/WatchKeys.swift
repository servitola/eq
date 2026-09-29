import EQTerm
import Foundation

enum WatchAction: Equatable {
    case bandStep(Int, Double)
    case preamp(Double)
    case bass(Double), treble(Double)
    case cyclePreset, previousPreset, undo
    case savePreset(String)
    case startSave, zones, help, quit
    case focusNext, focusPrevious, unfocus, listen
    /// A key's step for the focused instrument's knob; `boost` is that step once the focus names it.
    case knob(Double), boost(String, Double)
    case cycleComp, cycleColour, colourAmount
    case mouse, palette
    /// `y` and `Y`; saved as `setLook` and `setPalette` once the model has picked the next one.
    case nextLook, nextPalette
    case setLook(String), setPalette(String)
    case closeModal, scrollUp, scrollDown, pageUp, pageDown, top, bottom
    /// `g`, then a view's letter; `back` is Esc with nothing left to cancel.
    case goMenu, go(TUIView), back
    /// Enter on the Instruments view: the selected instrument, focused on the meter.
    case focusInMeter
    case pause, filter
    /// Ctrl-C in a command's output: stop the command, keep what it printed.
    case stop
    /// Ctrl-Z: the runtime suspends before the key reaches the table; listed for the help and README.
    case suspend
    /// The Tune view's keys: move the selection, jump a group, step the selected control by a
    /// band's ±0.1, ±0.5 or ±3 dB, set it to 0 or off, type its value.
    case tuneSelect(Int), tuneGroup(Int), nudge(Double), tuneReset, tuneEntry
    /// A control moved by a step in its own units, or set outright.
    case adjust(TuneControl, Double), assign(TuneControl, Double)
}

enum WatchKeys {
    static let step = KeyTable.step

    /// What one typed character does on the meter; `KeyTable` holds both layouts.
    static func action(for key: String) -> WatchAction? {
        guard key.count == 1, let c = key.first else { return nil }
        return KeyTable.action(for: c == "\u{1B}" ? .esc : .char(c), in: .meter)
    }

    static func actions(for keys: String, in context: KeyContext = .meter) -> [WatchAction] {
        self.keys(in: keys).compactMap { KeyTable.action(for: $0, in: context) }
    }

    /// Complete input as `KeyBuffer` hands it over, as the keys the table knows.
    static func keys(in keys: String) -> [Key] {
        InputParser.events(in: keys).compactMap(Key.init)
    }
}

extension Key {
    /// Shift and Alt on ↑ and ↓ are keys of their own where a context binds them, and plain
    /// arrows elsewhere, as every modifier on an arrow always was; an Alt-letter, a function key
    /// or a mouse click matches nothing yet.
    init?(_ event: InputEvent) {
        switch event {
        case .key(let press):
            switch press.code {
            case .char("\r") where press.modifiers.isEmpty: self = .char("\n")
            case .char("\u{08}") where press.modifiers.isEmpty: self = .char("\u{7F}")
            case .char(let c) where press.modifiers.isEmpty: self = .char(c)
            case .esc: self = .esc
            case .up: self = press.modifiers.contains(.shift) ? .shiftUp : (press.modifiers.contains(.alt) ? .altUp : .up)
            case .down: self = press.modifiers.contains(.shift) ? .shiftDown : (press.modifiers.contains(.alt) ? .altDown : .down)
            case .left: self = .left
            case .right: self = .right
            case .backTab: self = .backTab
            case .delete: self = .delete
            case .pageUp: self = .pageUp
            case .pageDown: self = .pageDown
            case .home: self = .home
            case .end: self = .end
            default: return nil
            }
        case .mouse(let mouse):
            switch mouse.action {
            case .wheelUp: self = .wheelUp
            case .wheelDown: self = .wheelDown
            default: return nil
            }
        default:
            return nil
        }
    }
}
