import EQTerm
import Foundation

struct WatchLayout: Equatable {
    var columns: Int
    var cellWidth: Int
    var meterRows: Int
    var shortLabels: Bool
    var width: Int
    var zoneRows = 0
    var bracketRows = 0
    /// The message row and the keybar share the bottom row.
    var folded = false

    /// Six rows are fixed: header, live row, labels, gains, the message row and the keybar, so
    /// the frame never scrolls the alternate screen. Below ten rows the meter's four-row floor
    /// and those six do not fit, so the message row folds into the keybar and the meter takes
    /// what is left, down to one row.
    /// Four columns is the floor: at three, neighbouring labels and numbers run together.
    /// The focus bracket and the zone strip take their room from the meter down to its four-row
    /// floor — the bracket first, since it names what the dimmed bars mean — then strip rows drop
    /// from the bottom.
    static func fit(cols: Int, rows: Int, zones: Int = 0, bracket: Bool = false) -> WatchLayout {
        let cellWidth = min(max((cols - 2) / 10, 4), 8)
        let folded = rows < 10
        let bracketRows = bracket && rows >= 11 ? 1 : 0
        let zoneRows = folded ? 0 : min(max(zones, 0), max(rows - 10 - bracketRows, 0))
        return WatchLayout(columns: min(Config.bandLabels.count, max(1, (cols - 2) / cellWidth)),
                           cellWidth: cellWidth,
                           meterRows: folded ? max(1, rows - 5) : max(4, rows - 6 - zoneRows - bracketRows),
                           shortLabels: cellWidth < 6, width: cols, zoneRows: zoneRows, bracketRows: bracketRows, folded: folded)
    }

    var visibleColumns: Int { min(max(columns, 1), Config.bandLabels.count) }
    var cell: Int { max(cellWidth, 1) }
    var tableWidth: Int { visibleColumns * cell }
    var barWidth: Int { cell >= 7 ? 3 : (cell >= 5 ? 2 : 1) }
}

enum Watch {
    static let floorDB = -60.0
    static let partials = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    static func requireTerminal(isTTY: Bool, command: String = "watch") throws {
        guard isTTY else { throw CLIError.usage("eq \(command) needs a terminal") }
    }

    /// Truncates or pads to `n` so a daemon/CLI version skew (a shorter array on the wire)
    /// can't index out of bounds and trap — a trap bypasses every terminal-restore path.
    /// Also sanitizes non-finite elements to `fill`, for the same reason.
    static func padded(_ a: [Double], to n: Int, with fill: Double) -> [Double] {
        let clean = a.map { $0.isFinite ? $0 : fill }
        return clean.count >= n ? Array(clean.prefix(n)) : clean + Array(repeating: fill, count: n - clean.count)
    }

    static let promptLabel = "save as: "

    /// Frame counts at the daemon's 30 frames a second.
    static let flashFrames = 15
    static let noteFrames = 60
    static let markFrames = 30

    /// The line `l` sends over the meter socket; `nil` asks the daemon to stop soloing.
    static func soloRequest(_ range: HzRange?) -> String {
        guard let range else { return #"{"solo":null}"# }
        func number(_ v: Double) -> String { v.rounded() == v && abs(v) < 1e15 ? String(Int(v)) : String(v) }
        return #"{"solo":{"low":\#(number(range.low)),"high":\#(number(range.high))}}"#
    }

    static func outsideNote(_ instrument: Instrument) -> String { "outside \(instrument.name) — Esc to unfocus" }
    static let listenNeedsFocus = "focus an instrument first — [ ] or Tab"
    static func cannotListen(_ instrument: Instrument) -> String { "can't listen to \(instrument.name) at this rate" }
    static let listenFailed = "listen: the daemon did not take the request"
    static let reconnecting = "daemon gone — reconnecting"

    /// What the header shows of the current device's profile beside the meters.
    struct Header {
        var preset: Table.PresetMark?
        var preference: Preference?
        var knobs: [String: Double]?
        var dynamics: Dynamics?
        var mouse = false
        /// The whole curve, for the Tune view to show and step exactly.
        var profile: Profile?
    }
}

/// An output by its UID, with the name it is shown by.
struct DeviceChoice: Equatable {
    var uid: String
    var name: String
}

/// The key list, drawn over the view until it is closed.
enum WatchModal: Equatable {
    /// `filter`: only the keys that have it, typed after `/`.
    case help(scroll: Int, filter: String = "")

    var context: KeyContext { .help }

    var scroll: Int {
        switch self {
        case .help(let scroll, _): return scroll
        }
    }

    var filter: String {
        switch self {
        case .help(_, let filter): return filter
        }
    }

    /// Stops where the last line comes into view, so ↑ answers at once after too many ↓.
    func scrolled(by delta: Int, size: Size, view: KeyContext) -> WatchModal {
        let (rows, visible) = Overlay.metrics(self, size: size, view: view)
        return .help(scroll: min(max(scroll + delta, 0), max(rows - visible, 0)), filter: filter)
    }
}
