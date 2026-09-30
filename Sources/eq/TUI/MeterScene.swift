import EQTerm
import Foundation

/// Everything one meter screen shows: the daemon's last frame and what the model keeps beside it.
struct MeterScene {
    struct Message: Equatable {
        enum Kind { case plain, ok, warn, error }
        var text: String
        var kind = Kind.plain
    }

    let frame: MeterFrame
    let size: Size
    let gains: [Double]
    let outLevels: [Double]
    let inLevels: [Double]
    var strip = false
    var focus: Instrument?
    var modal: WatchModal?
    /// The band just edited and the frames its chip has left to show it.
    var flash: (band: Int, left: Int)?
    var message: Message?
    /// Frames the message has left; the last `fadeFrames` of them fade it out.
    var messageLeft = Watch.noteFrames
    var header = Watch.Header()
    var prompt: TextField?
    var listening = false
    /// Each band's held peak in dBFS; nil draws no ticks.
    var peaks: [Double]?
    var outputPeak: Double?
    /// The daemon's limiter, held on for a few frames so a one-frame limit is seen.
    var limiting = false
    var settings = LookSettings()
    var curve = CurveCache()
    var chainCurve = ChainCurve()
    /// Set while an overlay covers the meter.
    var fade = 0.0
    var view = TUIView.meter
    /// The meter connection is open: without it the status bar leaves out peak and LIMIT, which
    /// only frames carry.
    var live = true
    /// The row the Instruments view has selected.
    var selected = 0
    var events = EventLog()
    /// The events connection is down and being retried.
    var eventsGone = false
    var goMenu = false
    var palette: CommandPalette?
    var paletteValues: [Completions.Kind: [String]] = [:]
    var child: ChildOutput?
    var filterField: TextField?
    var tune = TuneState()
    var entry: TextField?
    var library = Library()
    var lists = Lists()
    var form: FilterForm?
    var confirm: Confirm?
    var rename: TextField?
    /// The device Tune edits when it is not the one playing.
    var editing: DeviceChoice?
    var previews = PreviewCurves()
    var running: [PlayingApp] = []
    var picker: Picker?
    var search: ListSearch?
    var system = SystemInfo()
    var doctor = DoctorState()
    var versions = HistoryList()
    /// There is a view to go back to.
    var back = false

    static let fadeFrames = 15
    static let flashBlendFrames = 9

    init(frame: MeterFrame, size: Size) {
        self.frame = frame
        self.size = size
        let bands = Config.bandLabels.count
        gains = Watch.padded(frame.gains, to: bands, with: 0).map { min(max($0, -12), 12) }
        outLevels = Watch.padded(frame.out, to: bands, with: Watch.floorDB).map(Self.clampLevel)
        inLevels = Watch.padded(frame.in, to: bands, with: Watch.floorDB).map(Self.clampLevel)
    }

    var theme: Theme {
        var theme = settings.theme
        theme.fade = fade
        return theme
    }

    /// The screen as text, trailing blanks kept: what golden files and tests read.
    func lines() -> [String] {
        var screen = Screen(size)
        draw(into: &screen)
        return screen.lines()
    }

    /// The tab row takes a row once there are 14.
    var tabRows: Int { size.rows >= TabRow.minRows ? 1 : 0 }

    func draw(into screen: inout Screen) {
        let compact = size.cols < 60 || size.rows < 12
        if let modal {
            Overlay(scene: self).draw(modal, into: &screen)
        } else {
            switch view {
            case .meter where settings.look == .console && !compact: ConsoleView(scene: self).draw(into: &screen)
            case .meter: StudioView(scene: self, compact: compact).draw(into: &screen)
            case .tune: TuneView(scene: self).draw(into: &screen)
            case .instruments: InstrumentsView(scene: self).draw(into: &screen)
            case .presets: PresetsView(scene: self).draw(into: &screen)
            case .devices: DevicesView(scene: self).draw(into: &screen)
            case .filters: FiltersView(scene: self).draw(into: &screen)
            case .apps: AppsView(scene: self).draw(into: &screen)
            case .system: SystemView(scene: self).draw(into: &screen)
            case .history: HistoryView(scene: self).draw(into: &screen)
            case .events: EventsView(scene: self).draw(into: &screen)
            }
        }
        if let picker { PickerView(scene: self, picker: picker).draw(into: &screen) }
        if let child, child.shown { OutputPane(scene: self, child: child).draw(into: &screen) }
        if let palette { PaletteView(scene: self, palette: palette).draw(into: &screen) }
        if goMenu { GoMenu.draw(self, keybarY: size.rows - 1, into: &screen) }
        let ground = theme.depth.style(nil, theme.p.bg).bg
        if settings.paintsGround, ground != .none {
            screen.restyle(screen.area) { if $0.bg == .none { $0.bg = ground } }
        }
    }


    var bands: Int { Config.bandLabels.count }
    var inside: Set<Int> { focus.map { Set($0.bands) } ?? Set(0..<bands) }

    static func clampLevel(_ db: Double) -> Double { min(max(db, Watch.floorDB), 0) }

    /// `+4.8`, `-3.1`, and a flat band as `0.0`: signs only where there is a direction.
    static func gainText(_ value: Double, digits: Int = 1) -> String {
        guard value.isFinite else { return "?" }
        let rounded = (value * pow(10, Double(digits))).rounded() / pow(10, Double(digits))
        return rounded == 0 ? String(format: "%.\(digits)f", 0.0) : String(format: "%+.\(digits)f", rounded)
    }

    var keyState: KeyState {
        KeyState(strip: strip, focused: focus != nil, listening: listening, mouse: header.mouse, paused: events.paused != nil,
                 running: child?.status == nil, diff: lists.diff, editing: editing != nil,
                 back: back || (view == .events && !events.filter.isEmpty), following: library.followsApps, driver: system.mode == .driver)
    }

    var keyContext: KeyContext {
        Self.context(prompt: prompt, entry: entry, rename: rename, filter: filterField, confirm: confirm, palette: palette, picker: picker,
                     search: search, go: goMenu, pane: child?.shown == true, modal: modal, form: form, fields: lists.field != nil, view: view)
    }

    /// Searched top-down: the text field or question of the moment, the menus, the output pane,
    /// the overlay, a form or a filter's fields, then the view.
    static func context(prompt: TextField?, entry: TextField? = nil, rename: TextField? = nil, filter: TextField?, confirm: Confirm? = nil,
                        palette: CommandPalette?, picker: Picker? = nil, search: ListSearch? = nil, go: Bool, pane: Bool, modal: WatchModal?,
                        form: FilterForm? = nil, fields: Bool = false, view: TUIView) -> KeyContext {
        if prompt != nil { return .prompt }
        if entry != nil { return .entry }
        if rename != nil { return .rename }
        if filter != nil { return .filter }
        if confirm != nil { return .confirm }
        if palette != nil { return .palette }
        if picker != nil { return .picker }
        if search != nil { return .search }
        if go { return .go }
        if pane { return .pane }
        if let modal { return modal.context }
        if view == .filters, form != nil { return .form }
        if view == .filters, fields { return .fields }
        return view.context
    }
}

extension Screen {
    /// Text whose background, when it has none of its own, is what the cells under it already
    /// had: a label on a chip, a tick over a tint. Stops at `limit` columns or the row's end; a
    /// wide glyph that would straddle it is left out and its column padded.
    @discardableResult
    mutating func ink(_ text: String, x: Int, y: Int, _ style: Style, limit: Int? = nil) -> Int {
        guard y >= 0, y < height else { return 0 }
        let end = min(x + (limit ?? width), width)
        let keep = style.bg == .none
        var column = x
        func cell(_ text: String, _ w: Int) -> Cell {
            var s = style
            if keep, column >= 0 { s.bg = self[column, y].style.bg }
            return Cell(text, width: UInt8(w), style: s)
        }
        for c in text {
            let w = TerminalText.width(of: c)
            if w == 0 { continue }
            if column + w > end {
                while column < end {
                    if column >= 0 { set(column, y, cell(" ", 1)) }
                    column += 1
                }
                break
            }
            if column >= 0 { set(column, y, cell(String(c), w)) }
            column += w
        }
        return column - x
    }

    /// Paints the background of `rect` and keeps what is written in it.
    mutating func paint(_ rect: Rect, _ bg: Color) {
        restyle(rect) { $0.bg = bg }
    }
}

/// Where each part of the meter sits for one terminal size.
struct MeterGeometry {
    /// The boxed panel with scales; below 60 columns or 12 rows, the compact rows instead.
    var boxed: Bool
    var columns: Int
    var cell: Int
    var barWidth: Int
    var x0: Int
    var box: Rect?
    var gutter: Int?
    var axis: Int?
    var side: Rect?
    var bracketY: Int?
    var top: Int
    var rows: Int
    var liveY: Int
    var zoneY: Int
    var zoneRows: Int
    var messageY: Int?
    var keybarY: Int
    var shortLabels: Bool
    /// Where a zone row's instrument name goes, and whether it is the full name.
    var nameX: Int
    var fullNames: Bool

    var tableWidth: Int { columns * cell }
    var table: ClosedRange<Int> { x0...(x0 + max(tableWidth, 1) - 1) }

    /// A boxed bar sits in the middle of its cell; a compact one at its right end, under the
    /// right-aligned label.
    func barX(_ band: Int) -> Int { x0 + band * cell + (boxed ? (cell - barWidth) / 2 : cell - barWidth) }
    func centre(_ band: Int) -> Int { barX(band) + (boxed ? barWidth / 2 : (barWidth - 1) / 2) }
    var centres: [Int] { (0..<columns).map(centre) }

    static let sideWidth = 27

    /// `tabs`: rows the tab row took from `size` above it; they come out of the meter, not the strip.
    static func studio(_ size: Size, zones: Int, focus: Bool, tabs: Int = 0) -> MeterGeometry {
        let (w, h) = (size.cols, size.rows)
        guard w >= 60, h >= 12 else { return compact(size, zones: zones, focus: focus) }
        let sideWidth = w >= 110 ? Self.sideWidth : 0
        let panel = w - sideWidth
        let cell = min(max((panel - 13) / 10, 4), 8)
        let barWidth = cell >= 7 ? 5 : 3
        let boxWidth = 13 + cell * 10
        let px = max((panel - boxWidth) / 2, 0)
        let bracket = focus ? 1 : 0
        let zoneRows = focus ? min(zones, max(h + tabs - 17, 0)) : min(zones, max(h + tabs - 22, 0))
        let rows = max(h - 1 - 2 - bracket - 3 - zoneRows - 2, 1)
        let box = Rect(x: px, y: 1, width: boxWidth, height: rows + 2 + bracket)
        return MeterGeometry(boxed: true, columns: Config.bandLabels.count, cell: cell, barWidth: barWidth, x0: px + 7, box: box,
                             gutter: px + 1, axis: px + 7 + cell * 10, side: sideWidth > 0 ? Rect(x: w - sideWidth, y: 1, width: sideWidth, height: h - 3) : nil,
                             bracketY: focus ? 2 : nil, top: 2 + bracket, rows: rows, liveY: box.bottom, zoneY: box.bottom + 3,
                             zoneRows: zoneRows, messageY: h - 2, keybarY: h - 1, shortLabels: cell < 6, nameX: px + 1, fullNames: false)
    }

    /// The watch's own rows: header, bracket, bars, strip, live, labels, gains, message, keybar,
    /// with `WatchLayout`'s budget.
    static func compact(_ size: Size, zones: Int, focus: Bool) -> MeterGeometry {
        let layout = WatchLayout.fit(cols: size.cols, rows: size.rows, zones: zones, bracket: focus)
        let tableWidth = layout.tableWidth
        let room = max(size.cols - tableWidth, 0)
        let fullName = (Instruments.all.map(\.name.count).max() ?? 0) + 1
        var x0 = room / 2
        var full = true
        if layout.zoneRows > 0, room / 2 < fullName {
            x0 = min(max(room - 4, 0) / 2 + 4, room)
            full = false
        }
        let top = 1 + layout.bracketRows
        let zoneY = top + layout.meterRows
        let liveY = zoneY + layout.zoneRows
        return MeterGeometry(boxed: false, columns: layout.visibleColumns, cell: layout.cell, barWidth: layout.barWidth, x0: x0,
                             box: nil, gutter: nil, axis: nil, side: nil, bracketY: layout.bracketRows > 0 ? 1 : nil, top: top,
                             rows: layout.meterRows, liveY: liveY, zoneY: zoneY, zoneRows: layout.zoneRows,
                             messageY: layout.folded ? nil : size.rows - 2, keybarY: size.rows - 1, shortLabels: layout.shortLabels,
                             nameX: max(x0 - (full ? fullName : 4), 0), fullNames: full)
    }
}
