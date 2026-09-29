import EQTerm
import Foundation

/// One line of `eq events`, as the Events view shows it, and what it changes on the status bar.
struct EventEntry: Equatable {
    enum Tone { case plain, accent, boost, cut, ok, warn, danger, solo }
    enum Effect: Equatable {
        case device(String, rate: Double), rate(Double), enabled(Bool), solo(SoloRange?), profile
    }

    var time: String
    var kind: String
    var text: String
    var tone: Tone
    var effect: Effect?

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func rate(_ hz: Double) -> String { String(format: "%g kHz", hz / 1000) }

    /// nil for anything but an event: an old daemon answers the subscription with meter frames.
    static func decode(_ line: String) -> EventEntry? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let kind = object["event"] as? String else { return nil }
        func string(_ key: String) -> String? { object[key] as? String }
        func number(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        let time = (object["t"] as? NSNumber).map { clock.string(from: Date(timeIntervalSince1970: $0.doubleValue)) } ?? "--:--:--"
        var entry = EventEntry(time: time, kind: kind, text: "", tone: .plain)
        let device = string("device") ?? "?"
        switch kind {
        case "device":
            let hz = number("rate") ?? 0
            entry.text = [device, string("transport"), rate(hz)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            entry.tone = .accent
            entry.effect = .device(device, rate: hz)
        case "rate":
            let hz = number("rate") ?? 0
            entry.text = "\(device) at \(rate(hz))"
            entry.effect = .rate(hz)
        case "profile":
            let preset = string("preset").map { "preset \($0)" } ?? "its own curve"
            entry.text = "\(device) plays \(preset) (\(string("source") ?? "device"))"
            entry.tone = .boost
            entry.effect = .profile
        case "enabled":
            let on = object["enabled"] as? Bool ?? true
            entry.text = on ? "on" : "bypassed"
            entry.tone = on ? .ok : .warn
            entry.effect = .enabled(on)
        case "solo":
            let range = object["solo"] as? [String: Any]
            let solo = range.flatMap { r -> SoloRange? in
                guard let low = (r["low"] as? NSNumber)?.doubleValue, let high = (r["high"] as? NSNumber)?.doubleValue else { return nil }
                return SoloRange(low: low, high: high)
            }
            entry.text = solo.map { "listening to \(InstrumentTable.hz($0.low, gap: " "))–\(InstrumentTable.hz($0.high, gap: " "))" } ?? "off"
            entry.tone = .solo
            entry.effect = .solo(solo)
        case "daemon":
            let state = string("state") ?? "?"
            entry.text = [state, string("version").map { "eq \($0)" }, string("error")].compactMap { $0 }.joined(separator: " · ")
            entry.tone = state == "running" ? .ok : (state == "starting" || state == "bypassed" ? .warn : .danger)
        case "app":
            let name = string("name") ?? string("app") ?? "?"
            entry.text = string("preset").map { "\(name) plays, preset \($0)" } ?? "\(name) stopped"
            entry.tone = .cut
        case "mode":
            entry.text = [string("mode"), string("target").map { "on \($0)" }, string("reason")].compactMap { $0 }.joined(separator: " · ")
            entry.tone = .warn
        case "target":
            entry.text = "the EQ device plays on \(device)"
            entry.tone = .accent
        case "route":
            let name = string("name") ?? string("app") ?? "?"
            entry.text = "\(name) → \(string("targetName") ?? string("target") ?? "the main path") (\(string("reason") ?? "?"))"
        default:
            entry.text = line
        }
        return entry
    }
}

/// The events seen since the TUI started, newest last; paused, the view holds still while they
/// keep arriving.
struct EventLog: Equatable {
    static let limit = 500

    var entries: [EventEntry] = []
    var filter = ""
    /// How many entries the view shows while paused.
    var paused: Int?
    /// Rows up from the newest.
    var scroll = 0

    mutating func append(_ entry: EventEntry) {
        entries.append(entry)
        if entries.count > Self.limit {
            entries.removeFirst()
            paused = paused.map { max($0 - 1, 0) }
        }
    }

    mutating func togglePause() {
        paused = paused == nil ? entries.count : nil
        if paused == nil { scroll = 0 }
    }

    func matches(_ entry: EventEntry) -> Bool {
        filter.isEmpty || entry.kind.localizedCaseInsensitiveContains(filter) || entry.text.localizedCaseInsensitiveContains(filter)
    }

    var shown: [EventEntry] { entries.prefix(paused ?? entries.count).filter(matches) }
    var waiting: Int { paused.map { entries.count - $0 } ?? 0 }

    mutating func scroll(by delta: Int, visible: Int) {
        scroll = min(max(scroll + delta, 0), max(shown.count - visible, 0))
    }
}

/// The log in a panel: time, kind in its colour, what happened; a filter and a pause say so in
/// the panel's title.
struct EventsView {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette
    private var console: Bool { scene.settings.look == .console }

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    static func box(_ size: Size) -> Rect {
        let top = 1 + (size.rows >= TabRow.minRows ? 1 : 0)
        return Rect(x: 1, y: top, width: max(size.cols - 2, 0), height: max(size.rows - 2 - top, 0))
    }

    static func visible(_ size: Size) -> Int { max(box(size).height - 2, 0) }

    func ink(_ tone: EventEntry.Tone) -> Swatch {
        switch tone {
        case .plain: return p.text2
        case .accent: return p.accent
        case .boost: return p.boost
        case .cut: return p.cut
        case .ok: return p.ok
        case .warn: return p.warn
        case .danger: return p.danger
        case .solo: return p.solo
        }
    }

    func draw(into screen: inout Screen) {
        let size = scene.size
        if console { screen.fill(screen.area, with: Cell(" ", style: t.style(nil, p.surface))) }
        if console { StatusBar(scene: scene).console(into: &screen, width: size.cols) } else { StatusBar(scene: scene).studio(into: &screen, width: size.cols) }
        if scene.tabRows > 0 { TabRow.draw(scene, into: &screen) }
        let box = Self.box(size)
        let log = scene.events
        let shown = log.shown
        var state = scene.eventsGone ? "reconnecting" : (log.paused != nil ? "paused · \(log.waiting) new" : "live")
        if !log.filter.isEmpty { state = "“\(log.filter)” · " + state }
        if box.height >= 3, box.width >= 20 {
            Boxes.draw(box, into: &screen, t, border: log.paused != nil ? p.warn : p.border, title: console ? "EVENT LOG" : "events",
                       right: "\(state) · \(shown.count) of \(log.entries.count)")
            let visible = Self.visible(size)
            let end = max(shown.count - log.scroll, 0)
            let rows = shown[max(end - visible, 0)..<end]
            if rows.isEmpty {
                let text = log.entries.isEmpty ? "no events yet: they come as the device, rate, preset, bypass or solo change" : "nothing matches"
                screen.ink(text, x: box.x + 2, y: box.y + 1, t.style(p.text3), limit: box.width - 4)
            }
            // Newest at the bottom, as a terminal scrolls.
            let y0 = box.bottom - 1 - rows.count
            let kindWidth = 8
            for (i, entry) in rows.enumerated() {
                let y = y0 + i
                var x = box.x + 2
                let limit = box.right - 2
                if console {
                    x += screen.ink(" \(entry.time) ", x: x, y: y, t.style(p.lcdFg, p.lcdBg)) + 1
                } else {
                    x += screen.ink(entry.time, x: x, y: y, t.style(p.text3)) + 2
                }
                let kind = (console ? entry.kind.uppercased() : entry.kind).padding(toLength: kindWidth, withPad: " ", startingAt: 0)
                x += screen.ink(kind, x: x, y: y, t.style(ink(entry.tone), nil, .bold)) + 1
                if x < limit { screen.ink(entry.text, x: x, y: y, t.style(p.text), limit: limit - x) }
            }
        }
        ShellRows(scene: scene).draw(messageY: size.rows >= 10 ? size.rows - 2 : nil, keybarY: size.rows - 1, x: 1, widen: false,
                                     into: &screen)
    }
}
