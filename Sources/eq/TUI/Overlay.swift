import EQTerm
import Foundation

/// The key list of the view on screen, drawn over it, faded behind.
struct Overlay {
    let scene: MeterScene

    private let t: Theme
    private let p: Palette

    init(scene: MeterScene) {
        self.scene = scene
        t = scene.theme
        p = t.p
    }

    static let fade = 0.68

    /// Where a box over a view goes: under the status bar and the tabs, down to the message row.
    static func area(_ size: Size) -> Rect {
        let tabs = size.rows >= TabRow.minRows ? 1 : 0
        return Rect(x: 0, y: 1 + tabs, width: size.cols, height: max(size.rows - 3 - tabs, 0))
    }

    /// Rows of content and how many show at once, for scrolling to stop where the last one shows.
    static func metrics(_ modal: WatchModal, size: Size, view: KeyContext) -> (rows: Int, visible: Int) {
        let box = self.box(modal, size: size)
        return (HelpLayout(width: box.width, view: view).rows.count, max(box.height - 3, 1))
    }

    static func box(_ modal: WatchModal, size: Size) -> Rect {
        let area = self.area(size)
        let width = min(area.width - (area.width >= 46 ? 6 : 0), 112)
        return Rect(x: area.x + (area.width - width) / 2, y: area.y, width: width, height: area.height)
    }

    func draw(_ modal: WatchModal, into screen: inout Screen) {
        let size = scene.size
        var faded = scene
        faded.fade = Self.fade
        faded.modal = nil
        faded.draw(into: &screen)
        let bottom = Rect(x: 0, y: max(size.rows - 2, 0), width: size.cols, height: min(2, size.rows))
        screen.fill(bottom, with: t.blank)
        ShellRows(scene: scene).draw(messageY: size.rows >= 10 ? size.rows - 2 : nil, keybarY: size.rows - 1, x: 1, widen: false,
                                     into: &screen)
        let box = Self.box(modal, size: size)
        guard box.height >= 3, box.width >= 16 else { return }
        let (rows, visible) = Self.metrics(modal, size: size, view: scene.view.context)
        let start = min(max(modal.scroll, 0), max(rows - visible, 0))
        let position = rows > visible ? " \(start + 1)–\(start + visible) of \(rows) " : nil
        Boxes.draw(box, into: &screen, t, border: p.borderHi, title: "keys", right: scene.view.title.lowercased() + " view",
                   titleInk: p.title, fill: p.surface)
        help(box, start: start, visible: visible, into: &screen)
        if let position, box.width >= position.count + 4 {
            screen.ink(position, x: box.x + (box.width - position.count) / 2, y: box.bottom - 1, t.style(p.text3, p.surface))
        }
    }

    private func help(_ box: Rect, start: Int, visible: Int, into screen: inout Screen) {
        let layout = HelpLayout(width: box.width, view: scene.view.context)
        for (i, row) in layout.rows.dropFirst(start).prefix(visible).enumerated() {
            let y = box.y + 2 + i
            for (column, item) in row.enumerated() {
                guard let item else { continue }
                let x = box.x + 3 + column * (layout.columnWidth + 2)
                switch item {
                case .title(let title):
                    let used = screen.ink(title, x: x, y: y, t.style(p.accent, p.surface, .bold))
                    let rule = max(layout.columnWidth - used - 1, 0)
                    screen.ink(String(repeating: "─", count: rule), x: x + used + 1, y: y, t.style(p.border, p.surface))
                case .key(let key, let text):
                    screen.ink(" " + key + " ", x: x, y: y, t.style(p.keyFg, p.keyBg, .bold))
                    screen.ink(text, x: x + layout.keyWidth + 3, y: y, t.style(p.text2, p.surface))
                case .more(let text):
                    screen.ink(text, x: x + layout.keyWidth + 3, y: y, t.style(p.text2, p.surface))
                case .note(let text):
                    screen.ink(text, x: x, y: y, t.style(p.text3, p.surface))
                }
            }
        }
    }
}

/// The key list in groups, as one column or two side by side; a long description wraps under
/// itself.
struct HelpLayout {
    enum Item: Equatable {
        case title(String), key(String, String), more(String), note(String)
    }

    let columnWidth: Int
    let keyWidth: Int
    let rows: [[Item?]]

    init(width: Int, view: KeyContext = .meter) {
        let entries = KeyHelp.lines(view: view)
        keyWidth = entries.filter { !$0.text.isEmpty }.map { TerminalText.width($0.key) }.max() ?? 0
        let inner = width - 6
        let two = inner >= 2 * 44
        columnWidth = two ? (inner - 2) / 2 : max(inner, 0)
        let textWidth = max(columnWidth - keyWidth - 3, 8)
        var groups: [[Item]] = []
        for entry in entries where !(entry.key.isEmpty && entry.text.isEmpty) {
            if entry.text.isEmpty {
                groups.append([.title(entry.key)])
            } else if entry.key.isEmpty {
                groups[groups.count - 1] += Self.wrap(entry.text, width: max(columnWidth, 8)).map(Item.note)
            } else {
                let lines = Self.wrap(entry.text, width: textWidth)
                groups[groups.count - 1] += [.key(entry.key, lines[0])] + lines.dropFirst().map(Item.more)
            }
        }
        func stacked(_ groups: ArraySlice<[Item]>) -> [Item?] {
            groups.enumerated().flatMap { i, group in (i > 0 ? [nil] : []) + group.map(Optional.some) }
        }
        guard two, groups.count > 1 else {
            rows = stacked(groups[...]).map { [$0] }
            return
        }
        let split = (1..<groups.count).min { a, b in
            max(stacked(groups[..<a]).count, stacked(groups[a...]).count) < max(stacked(groups[..<b]).count, stacked(groups[b...]).count)
        } ?? 1
        let left = stacked(groups[..<split]), right = stacked(groups[split...])
        rows = (0..<max(left.count, right.count)).map { i in [i < left.count ? left[i] : nil, i < right.count ? right[i] : nil] }
    }

    /// Words onto lines of at most `width` columns; a word longer than that is cut.
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            let candidate = line.isEmpty ? String(word) : line + " " + word
            if TerminalText.width(candidate) <= width || line.isEmpty {
                line = TerminalText.width(candidate) <= width ? candidate : TerminalText.truncated(candidate, columns: width)
            } else {
                lines.append(line)
                line = TerminalText.width(String(word)) <= width ? String(word) : TerminalText.truncated(String(word), columns: width)
            }
        }
        return lines + [line]
    }
}
