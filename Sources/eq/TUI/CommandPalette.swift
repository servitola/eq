import EQTerm
import Foundation

/// The palette's line and what it suggests: every `eq` command form from `CommandHelp.all`, the
/// screen's named actions from the key table, and, once a command is typed, its operands from the
/// same `Completions.Kind` values the shells complete with.
struct CommandPalette: Equatable {
    struct Entry: Equatable {
        /// What goes into the line: `preset use favourite`, `go events`, or a form's template.
        var text: String
        var summary: String
        /// Runs as it stands; a template (`preset use <name>`) first takes its words into the line.
        var runnable: Bool
        var action: WatchAction?
        /// Columns of `text` the typed letters matched, for drawing them in the accent.
        var matched: [Int] = []
    }

    struct Suggestions: Equatable {
        var title: String
        var items: [Entry]
        /// The operand being typed, whose values the model has to fetch first.
        var kind: Completions.Kind?
        /// Enter takes the first item unless another was chosen; off where a new name is the point.
        var prefersFirst = true
    }

    var field = TextField()
    /// nil: the line as typed.
    var chosen: Int? = 0
    var history: [String] = []

    static let historyLimit = 100
    /// Commands that stream until Ctrl-C: the screen already is what they print.
    static let streaming: [String: String] = [
        "watch": "it is the Meter view here — g m", "tui": "it is this screen", "stream": "its numbers are the Meter view — g m",
        "events": "it is the Events view here — g e", "daemon": "the daemon runs under launchd",
    ]

    /// A template's words up to its first placeholder: `preset use <name>` → `preset use `.
    static func stem(_ template: String) -> String {
        var words: [Substring] = []
        for word in template.split(separator: " ") {
            if word.hasPrefix("<") || word.allSatisfy({ $0.isUppercase }) { return words.joined(separator: " ") + " " }
            words.append(word)
        }
        return words.joined(separator: " ")
    }

    /// Each command form once, as its words, its required flags and its operands; runnable when
    /// every operand is optional.
    static let commands: [Entry] = {
        var seen = Set<String>()
        var result: [Entry] = []
        for help in CommandHelp.all {
            for form in help.forms where !form.path.isEmpty {
                let flags = form.flags.filter(\.required).reduce(into: [CommandHelp.Flag]()) { list, flag in
                    if !list.contains(where: { $0.group == flag.group }) { list.append(flag) }
                }
                let words = form.path + flags.flatMap { [$0.name] + ($0.value.map { [$0] } ?? []) } + form.operands
                let text = words.joined(separator: " ")
                guard seen.insert(text).inserted else { continue }
                let optional = form.operands.first.map { help.usage.contains("[" + $0) } ?? true
                result.append(Entry(text: text, summary: help.summary, runnable: flags.allSatisfy { $0.value == nil } && optional))
            }
        }
        return result
    }()

    static var actions: [Entry] {
        KeyTable.named.map { Entry(text: $0.name, summary: $0.help, runnable: true, action: $0.action) }
    }

    /// Words as a shell splits them: blanks apart, quotes keep them together.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        var quote: Character?
        var started = false
        for c in text {
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
                started = true
            } else if c == " " {
                if started || !word.isEmpty { result.append(word) }
                word = ""
                started = false
            } else {
                word.append(c)
            }
        }
        if started || !word.isEmpty { result.append(word) }
        return result
    }

    static func quoted(_ word: String) -> String {
        word.contains(" ") || word.isEmpty ? "\"" + word + "\"" : word
    }

    /// The letters of `query` in order in `text`, nil when they are not all there. Higher is
    /// better: a start of the text or of a word, and runs of letters, count most; shorter texts
    /// win ties.
    static func fuzzy(_ query: String, _ text: String) -> (score: Int, matched: [Int])? {
        let q = Array(query.lowercased()), s = Array(text.lowercased())
        guard !q.isEmpty else { return (0, []) }
        var matched: [Int] = []
        var score = 0
        var j = 0
        for (i, c) in s.enumerated() where j < q.count && c == q[j] {
            var points = 1
            if i == 0 { points += 8 } else if s[i - 1] == " " || s[i - 1] == "-" { points += 5 }
            if let last = matched.last, last == i - 1 { points += 4 }
            score += points
            matched.append(i)
            j += 1
        }
        guard j == q.count else { return nil }
        return (score * 100 - s.count, matched)
    }

    /// What the line suggests now; `values` are the operand values fetched so far.
    func suggestions(values: [Completions.Kind: [String]]) -> Suggestions {
        // `eq …` names the command: the screen's actions step aside.
        let command = field.text.hasPrefix("eq ")
        let text = command ? String(field.text.dropFirst(3)) : field.text
        let typed = Self.words(text)
        let partial = text.hasSuffix(" ") || text.isEmpty ? "" : (typed.last ?? "")
        let done = partial.isEmpty ? typed : Array(typed.dropLast())
        if let operand = Self.operand(after: done), operand.kind != .none, operand.kind != .files {
            let words = operand.kind.words.isEmpty ? (values[operand.kind] ?? []) : operand.kind.words
            let head = done.map(Self.quoted).joined(separator: " ")
            let items = words.compactMap { word -> (Int, Entry)? in
                guard let match = Self.fuzzy(partial, word) else { return nil }
                let line = head + " " + Self.quoted(word)
                let offset = head.count + 1
                return (match.score, Entry(text: line, summary: "", runnable: true, matched: match.matched.map { $0 + offset }))
            }.sorted { $0.0 > $1.0 }.map(\.1)
            return Suggestions(title: operand.kind.rawValue, items: items, kind: operand.kind,
                               prefersFirst: !(operand.path == ["preset", "save"] || operand.path == ["preset", "rename"]))
        }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            let named = Self.actions
            let recent = history.map { line in Entry(text: line, summary: "run before", runnable: true, action: named.first { $0.text == line }?.action) }
            return Suggestions(title: "commands", items: recent + Self.actions + Self.commands)
        }
        let items = ((command ? [] : Self.actions) + Self.commands).compactMap { entry -> (Int, Entry)? in
            guard let match = Self.fuzzy(text.trimmingCharacters(in: .whitespaces), entry.text) else { return nil }
            var entry = entry
            entry.matched = match.matched
            return (match.score, entry)
        }.sorted { $0.0 > $1.0 }.map(\.1)
        return Suggestions(title: "commands", items: items)
    }

    /// The operand the next word is, once a command's words are all typed: its kind, from the
    /// placeholder, or the flag it is the value of.
    static func operand(after words: [String]) -> (path: [String], kind: Completions.Kind)? {
        let lower = CommandHelp.canonical(words).map { $0.lowercased() }
        let forms = CommandHelp.all.flatMap(\.forms).filter { !$0.path.isEmpty && lower.starts(with: $0.path) }
        guard let longest = forms.map(\.path.count).max() else { return nil }
        let candidates = forms.filter { $0.path.count == longest }
        let form = candidates.first { !$0.operands.isEmpty } ?? candidates[0]
        let rest = Array(lower.dropFirst(longest))
        if let last = rest.last, let flag = form.flags.first(where: { $0.name == last }), let value = flag.value {
            return (form.path, Completions.Kind.of(value, in: form.path))
        }
        var positional = 0
        var skip = false
        for word in rest {
            if skip { skip = false } else if let flag = form.flags.first(where: { $0.name == word }) { skip = flag.value != nil } else { positional += 1 }
        }
        guard !form.operands.isEmpty, positional < form.operands.count || form.repeats else { return nil }
        let placeholder = form.operands[min(positional, form.operands.count - 1)]
        return (form.path, Completions.Kind.of(placeholder, in: form.path))
    }
}

/// A command the palette ran: what it printed so far, colours kept, and how it ended.
struct ChildOutput: Equatable {
    var command: String
    var lines: [String] = []
    /// nil while it runs.
    var status: Int32?
    /// The pane is up: more than one line came, which the message row cannot hold.
    var shown = false
    /// Rows up from the last line; the pane follows the output until scrolled.
    var scroll = 0

    static let limit = 5000

    static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}

/// The suggestions over the message row, the chosen one marked, the typed letters in the accent.
struct PaletteView {
    let scene: MeterScene
    let palette: CommandPalette

    static let maxRows = 12

    func draw(into screen: inout Screen) {
        let t = scene.theme, p = t.p
        let size = scene.size
        let messageY = size.rows - 2
        let top = 1 + scene.tabRows
        let suggestions = palette.suggestions(values: scene.paletteValues)
        let rows = min(max(suggestions.items.count, 1), Self.maxRows, messageY - top - 2)
        guard rows > 0 else { return }
        let width = min(size.cols - 2, 100)
        let box = Rect(x: 1, y: messageY - rows - 2, width: width, height: rows + 2)
        let count = suggestions.items.count
        Boxes.draw(box, into: &screen, t, border: p.borderHi, title: suggestions.title,
                   right: count == 0 ? nil : "\(count)", titleInk: p.title, fill: p.surface)
        guard count > 0 else {
            let text = suggestions.kind.map { _ in "Enter runs the line as typed" } ?? "no command matches; Enter runs the line as typed"
            screen.ink(text, x: box.x + 2, y: box.y + 1, t.style(p.text3, p.surface), limit: box.width - 4)
            return
        }
        let chosen = palette.chosen ?? -1
        let offset = chosen < rows ? 0 : chosen - rows + 1
        let textWidth = min(max(suggestions.items.map { TerminalText.width($0.text) }.max() ?? 0, 16), box.width / 2)
        for (i, entry) in suggestions.items.dropFirst(offset).prefix(rows).enumerated() {
            let y = box.y + 1 + i
            let selected = offset + i == chosen
            let bg = selected ? p.sel : p.surface
            if selected {
                screen.fill(Rect(x: box.x + 1, y: y, width: box.width - 2, height: 1), with: Cell(" ", style: t.style(nil, bg)))
                screen.ink("▸", x: box.x + 1, y: y, t.style(p.accent, bg, .bold))
            }
            var x = box.x + 3
            let limit = box.x + 3 + textWidth
            for (k, c) in entry.text.enumerated() {
                guard x < limit else { break }
                let hit = entry.matched.contains(k)
                let ink = hit ? p.accent : (entry.action != nil ? p.title : p.text)
                x += screen.ink(String(c), x: x, y: y, t.style(ink, bg, hit || selected ? .bold : []))
            }
            if !entry.summary.isEmpty, limit + 2 < box.right - 2 {
                screen.ink(entry.summary, x: limit + 2, y: y, t.style(p.text3, bg), limit: box.right - 2 - limit - 2)
            }
        }
    }
}

/// What a command printed, in a panel over the view, its colours kept.
struct OutputPane {
    let scene: MeterScene
    let child: ChildOutput

    static func box(_ size: Size) -> Rect {
        let area = Overlay.area(size)
        return Rect(x: area.x + 1, y: area.y, width: max(area.width - 2, 0), height: area.height)
    }

    /// The width a command's output is laid out for: the pane's inside.
    static func columns(_ size: Size) -> Int { max(box(size).width - 4, 20) }
    static func visible(_ size: Size) -> Int { max(box(size).height - 2, 0) }

    func draw(into screen: inout Screen) {
        let t = scene.theme, p = t.p
        let box = Self.box(scene.size)
        guard box.height >= 3, box.width >= 16 else { return }
        let status: String
        switch child.status {
        case nil: status = "running"
        case 0?: status = "done"
        case let code?: status = "exit \(code)"
        }
        Boxes.draw(box, into: &screen, t, border: child.status.map { $0 == 0 ? p.borderHi : p.danger } ?? p.accent,
                   title: "eq " + child.command, right: "\(status) · \(child.lines.count) lines", titleInk: p.title, fill: p.surface)
        let visible = Self.visible(scene.size)
        let end = max(child.lines.count - child.scroll, 0)
        let base = t.style(p.text, p.surface)
        for (i, line) in child.lines[max(end - visible, 0)..<end].enumerated() {
            AnsiText.draw(line, into: &screen, x: box.x + 2, y: box.y + 1 + i, limit: box.width - 4, base: base)
        }
    }
}
