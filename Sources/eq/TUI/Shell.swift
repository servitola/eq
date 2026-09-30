import EQTerm
import Foundation

/// The views the TUI switches between; each is reached by `g` and its letter, a click on its
/// tab, or `go …` in the palette.
enum TUIView: String, CaseIterable {
    case meter, tune, instruments, presets, devices, filters, events

    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var letter: Character { rawValue.first! }

    var context: KeyContext {
        switch self {
        case .meter: return .meter
        case .tune: return .tune
        case .instruments: return .instruments
        case .presets: return .presets
        case .devices: return .devices
        case .filters: return .filters
        case .events: return .events
        }
    }

    /// The meter connection is held only while a view that draws levels is on screen: the
    /// daemon's meter work stops while nobody watches.
    var showsLevels: Bool { [.meter, .tune, .instruments].contains(self) }
}

/// The top and bottom of every view but the meter: the console's surface, the status bar, the
/// tabs; the message row and the keybar.
enum Chrome {
    static func top(_ scene: MeterScene, into screen: inout Screen) {
        let t = scene.theme
        if scene.settings.look == .console {
            screen.fill(screen.area, with: Cell(" ", style: t.style(nil, t.p.surface)))
            StatusBar(scene: scene).console(into: &screen, width: scene.size.cols)
        } else {
            StatusBar(scene: scene).studio(into: &screen, width: scene.size.cols)
        }
        if scene.tabRows > 0 { TabRow.draw(scene, into: &screen) }
    }

    static func bottom(_ scene: MeterScene, into screen: inout Screen) {
        let rows = scene.size.rows
        ShellRows(scene: scene).draw(messageY: rows >= 10 ? rows - 2 : nil, keybarY: rows - 1, x: 1, widen: false, into: &screen)
    }

    /// Under the status bar and the tabs, down to the message row.
    static func body(_ size: Size) -> Rect {
        let top = 1 + (size.rows >= TabRow.minRows ? 1 : 0)
        return Rect(x: 1, y: top, width: max(size.cols - 2, 0), height: max(size.rows - 2 - top, 0))
    }
}

/// Row 1 under the status bar: the views as tabs, the current one a solid chip, the others with
/// their go-to letter underlined; `g go  ; cmd` at the right. Below 60 columns only the current one.
enum TabRow {
    static let hint = "g go  ; cmd"
    static let minRows = 14

    /// Where each tab sits, for drawing and for a click.
    static func layout(width: Int, current: TUIView) -> [(view: TUIView, columns: Range<Int>)] {
        let views = width < 60 ? [current] : TUIView.allCases
        var x = 1
        var result: [(TUIView, Range<Int>)] = []
        for view in views {
            let w = view.title.count + 2
            guard x + w <= width else { break }
            result.append((view, x..<(x + w)))
            x += w + 1
        }
        return result
    }

    static func view(at column: Int, width: Int, current: TUIView) -> TUIView? {
        layout(width: width, current: current).first { $0.columns.contains(column) }?.view
    }

    static func draw(_ scene: MeterScene, y: Int = 1, into screen: inout Screen) {
        let t = scene.theme, p = t.p
        let width = scene.size.cols
        let console = scene.settings.look == .console
        let tabs = layout(width: width, current: scene.view)
        for (view, columns) in tabs {
            let title = console ? view.title.uppercased() : view.title
            if view == scene.view {
                screen.ink(" " + title + " ", x: columns.lowerBound, y: y, t.style(p.onChip, p.accent, .bold, solid: true))
            } else {
                let bg: Swatch? = console ? p.keyBg : nil
                screen.ink(" ", x: columns.lowerBound, y: y, t.style(nil, bg))
                screen.ink(String(title.prefix(1)), x: columns.lowerBound + 1, y: y, t.style(p.accent, bg, .underline))
                screen.ink(String(title.dropFirst()) + " ", x: columns.lowerBound + 2, y: y, t.style(console ? p.text2 : p.text3, bg))
            }
        }
        let end = tabs.last?.columns.upperBound ?? 0
        let hint = width < 60 ? "g go" : hint
        let hx = width - hint.count - 1
        guard hx > end + 2 else { return }
        screen.ink("g", x: hx, y: y, t.style(p.accent, nil, .bold))
        screen.ink(" go", x: hx + 1, y: y, t.style(p.text3))
        if hint.count > 4 {
            screen.ink(";", x: hx + 6, y: y, t.style(p.accent, nil, .bold))
            screen.ink(" cmd", x: hx + 7, y: y, t.style(p.text3))
        }
    }
}

/// The which-key menu `g` opens over the keybar: each view's letter and name.
enum GoMenu {
    static func draw(_ scene: MeterScene, keybarY: Int, into screen: inout Screen) {
        let t = scene.theme, p = t.p
        let height = TUIView.allCases.count + 2
        let width = 26
        let box = Rect(x: 1, y: keybarY - height, width: min(width, scene.size.cols - 2), height: height)
        guard box.y >= 1, box.width >= 16 else { return }
        Boxes.draw(box, into: &screen, t, border: p.borderHi, title: "go to", titleInk: p.title, fill: p.surface)
        for (i, view) in TUIView.allCases.enumerated() {
            let y = box.y + 1 + i
            screen.ink(" \(view.letter) ", x: box.x + 2, y: y, t.style(p.keyFg, p.keyBg, .bold))
            let here = view == scene.view
            screen.ink(view.title, x: box.x + 6, y: y, t.style(here ? p.title : p.text2, p.surface, here ? .bold : []))
            if here { screen.ink("here", x: box.right - 7, y: y, t.style(p.text3, p.surface)) }
        }
    }
}

extension MeterGeometry {
    /// The same layout one row lower: the tab row sits between the status bar and it.
    func lowered(by rows: Int) -> MeterGeometry {
        guard rows > 0 else { return self }
        var g = self
        g.box = box.map { Rect(x: $0.x, y: $0.y + rows, width: $0.width, height: $0.height) }
        g.side = side.map { Rect(x: $0.x, y: $0.y + rows, width: $0.width, height: $0.height) }
        g.bracketY = bracketY.map { $0 + rows }
        g.top += rows
        g.liveY += rows
        g.zoneY += rows
        g.messageY = messageY.map { $0 + rows }
        g.keybarY += rows
        return g
    }
}
