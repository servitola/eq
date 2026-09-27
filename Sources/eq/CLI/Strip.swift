import Foundation

/// Instruments drawn over the watch's bars on a log-frequency axis, so a range lands between
/// band columns in proportion to its octaves instead of snapping to whole bands.
enum Strip {
    static let fullNameWidth = (Instruments.all.map(\.name.count).max() ?? 0) + 1
    static let shortNameWidth = 4

    struct Placement: Equatable {
        var start: Int
        var nameWidth: Int
        var full: Bool
    }

    /// Where the band table starts while the strip shows: full names in the centring pad when it
    /// is wide enough, otherwise short names and the whole frame shifted right to make room —
    /// never past the right edge, since the bars matter more than the names.
    static func placement(_ layout: WatchLayout) -> Placement {
        let room = max(layout.width - layout.tableWidth, 0)
        if room / 2 >= fullNameWidth { return Placement(start: room / 2, nameWidth: fullNameWidth, full: true) }
        let start = min(max(room - shortNameWidth, 0) / 2 + shortNameWidth, room)
        return Placement(start: start, nameWidth: shortNameWidth, full: false)
    }

    /// Column of `f` within the table: a band's bar centre is its own frequency, log2 f is
    /// interpolated between neighbouring centres, and past either end the edge octave's slope
    /// carries on. Unclamped, so a caller can tell a range that is off the table altogether.
    static func x(_ f: Double, layout: WatchLayout) -> Double {
        let logs = Config.bandFrequencies.map(log2)
        let l = log2(max(f, 1))
        let k = logs.indices.dropLast().first { l <= logs[$0 + 1] } ?? logs.count - 2
        let a = Double(layout.centre(k)), b = Double(layout.centre(k + 1))
        return a + (b - a) * (l - logs[k]) / (logs[k + 1] - logs[k])
    }

    struct Segment: Equatable {
        var name: String
        var lo: Int
        var hi: Int
        var count: Int { hi - lo + 1 }
    }

    /// Column spans of an instrument's ranges, clamped to the table, one blank column between
    /// neighbours. Voice's F1 and F2 share 900–1000 Hz; a shared column would read as one range,
    /// so an overlap is split down the middle instead of going to whichever range came first.
    static func segments(_ instrument: Instrument, layout: WatchLayout) -> [Segment] {
        let last = layout.tableWidth - 1
        var result: [Segment] = []
        for range in instrument.ranges.sorted(by: { $0.low < $1.low }) {
            let a = x(range.low, layout: layout), b = x(range.high, layout: layout)
            guard b >= 0, a <= Double(last) else { continue }
            var segment = Segment(name: range.name, lo: max(Int(a.rounded()), 0), hi: min(Int(b.rounded()), last))
            if var previous = result.last, segment.lo <= previous.hi + 1 {
                let cut = (previous.hi + segment.lo) / 2
                previous.hi = min(previous.hi, cut - 1)
                segment.lo = max(segment.lo, cut + 1)
                result.removeLast()
                if previous.lo <= previous.hi { result.append(previous) }
            }
            segment.lo = max(segment.lo, (result.last?.hi ?? -2) + 2)
            if segment.lo <= segment.hi { result.append(segment) }
        }
        return result
    }

    typealias Cell = (glyph: Character, ink: Paint.Ink?)

    /// The span's name sits in its middle when a stroke and a space still fit on either side.
    static func labelled(_ segment: Segment, stroke: Character, ends: (Character, Character)? = nil,
                         strokeInk: Paint.Ink?, nameInk: Paint.Ink?) -> [Cell] {
        let n = segment.count
        var cells = [Cell](repeating: (stroke, strokeInk), count: n)
        if let ends {
            if n == 1 { cells[0].glyph = "│" } else { cells[0].glyph = ends.0; cells[n - 1].glyph = ends.1 }
        }
        let name = Array(segment.name)
        guard name.count + 4 <= n else { return cells }
        let at = (n - name.count) / 2
        cells[at - 1] = (" ", nil)
        cells[at + name.count] = (" ", nil)
        for (i, c) in name.enumerated() { cells[at + i] = (c, nameInk) }
        return cells
    }

    /// Consecutive cells of one ink share an escape pair; trailing blanks are dropped.
    static func paint(_ cells: [Cell]) -> String {
        let used = cells.lastIndex { $0.glyph != " " }.map { cells[...$0] } ?? []
        var line = "", run = "", ink: Paint.Ink?
        for cell in used {
            if cell.ink != ink, !run.isEmpty { line += Paint.ink(ink, run, on: Paint.enabled); run = "" }
            ink = cell.ink
            run.append(cell.glyph)
        }
        return line + Paint.ink(ink, run, on: Paint.enabled)
    }

    /// `┌─ F1 ─┐` over each range of the focused instrument, in table columns.
    static func bracket(_ instrument: Instrument, layout: WatchLayout) -> String {
        var cells = [Cell](repeating: (" ", nil), count: layout.tableWidth)
        for segment in segments(instrument, layout: layout) {
            let drawn = labelled(segment, stroke: "─", ends: ("┌", "┐"), strokeInk: .dim, nameInk: nil)
            for (i, cell) in drawn.enumerated() { cells[segment.lo + i] = cell }
        }
        return paint(cells)
    }

    /// One strip row in screen columns: the name in the left margin, then `━` under each range.
    /// The instrument's loudest audible band lends the strokes nearest its bar the bar's ink, so
    /// the eye finds where the instrument is sounding; the rest stays dim unless `highlighted`.
    static func row(_ instrument: Instrument, layout: WatchLayout, levels: [Double], gains: [Double],
                    highlighted: Bool = false) -> String {
        let columns = layout.visibleColumns
        let place = placement(layout)
        let levels = Watch.padded(levels, to: columns, with: Watch.floorDB)
        let gains = Watch.padded(gains, to: columns, with: 0)
        let label = place.full ? instrument.name : instrument.short
        let nameColumn = max(place.start - place.nameWidth, 0)
        let firstFree = nameColumn + label.count + 1
        let touched = instrument.bands.filter { $0 < columns }
        let loudest = touched.max { levels[$0] < levels[$1] }.flatMap { levels[$0] > Watch.floorDB + 0.5 ? $0 : nil }
        func nearest(_ column: Int) -> Int {
            (0..<columns).min { abs(layout.centre($0) - column) < abs(layout.centre($1) - column) } ?? 0
        }

        var cells = [Cell](repeating: (" ", nil), count: place.start + layout.tableWidth)
        for (i, c) in label.enumerated() { cells[nameColumn + i] = (c, highlighted ? .bold : .dim) }
        for segment in segments(instrument, layout: layout) {
            let drawn = labelled(segment, stroke: "━", strokeInk: highlighted ? nil : .dim, nameInk: .dim)
            for (i, var cell) in drawn.enumerated() {
                let column = segment.lo + i
                guard place.start + column >= firstFree else { continue }
                if cell.glyph == "━", let loudest, nearest(column) == loudest {
                    cell.ink = Watch.barInk(gain: gains[loudest], level: levels[loudest])
                }
                cells[place.start + column] = cell
            }
        }
        return paint(cells)
    }
}
