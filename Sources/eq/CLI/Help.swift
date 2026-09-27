import Foundation

struct CommandHelp {
    enum Group: String, CaseIterable { case look, tune, setup }

    enum Token: Equatable {
        case word(String), flag(String), placeholder(String), punctuation(String)

        var text: String {
            switch self {
            case .word(let s), .flag(let s), .placeholder(let s), .punctuation(let s): return s
            }
        }

        var ink: Paint.Ink? {
            switch self {
            case .word(let s): return s == "eq" ? nil : .bold
            case .flag: return .cyan
            case .placeholder: return .yellow
            case .punctuation: return .dim
            }
        }
    }

    var group: Group
    /// One inner array per space-separated word, so `[--device` stays one unbreakable unit.
    var invocation: [[Token]]
    var summary: String
    var examples: [String] = []

    init(_ group: Group, _ invocation: String, _ summary: String, examples: [String] = []) {
        self.group = group
        self.invocation = invocation.split(separator: " ").map { Self.tokens(String($0)) }
        self.summary = summary
        self.examples = examples
    }

    /// The command words that name this block: `set` in `eq set …`, `on` and `off` in `eq on | eq off`.
    var commands: [String] {
        let words = invocation.map { $0.map(\.text).joined() }
        if words == ["eq"] { return ["show"] }
        return words.indices.dropLast().filter { words[$0] == "eq" }.map { words[$0 + 1] }
    }

    static func tokens(_ word: String) -> [Token] {
        var result: [Token] = []
        var core = Substring(word)
        var tail: [Token] = []
        while let first = core.first, "[".contains(first) { result.append(.punctuation(String(first))); core.removeFirst() }
        while let last = core.last, "]".contains(last) { tail.insert(.punctuation(String(last)), at: 0); core.removeLast() }
        if core.hasPrefix("<") {
            result.append(.placeholder(String(core)))
        } else if core.hasPrefix("-") {
            result.append(.flag(String(core)))
        } else if core == "|" || core == "…" {
            result.append(.punctuation(String(core)))
        } else if !core.isEmpty && core.allSatisfy(\.isUppercase) {
            result.append(.placeholder(String(core)))
        } else {
            let parts = core.split(separator: "|", omittingEmptySubsequences: false)
            for (index, part) in parts.enumerated() {
                if index > 0 { result.append(.punctuation("|")) }
                result.append(.word(String(part)))
            }
        }
        return result + tail
    }

    static let all: [CommandHelp] = [
        CommandHelp(.look, "eq", "show the current device's curve"),
        CommandHelp(.look, "eq devices", "known profiles and connected outputs; the current one marked *"),
        CommandHelp(.look, "eq status", "is the daemon alive, on which device, at what rate"),
        CommandHelp(.look, "eq watch [--zones]", "the live equalizer; tune with 1…0, h for keys, q to quit"),
        CommandHelp(.look, "eq zones", "instrument frequency ranges and the bands they touch"),
        CommandHelp(.look, "eq stream", "meter frames as JSON lines, 30 per second, until Ctrl-C"),
        CommandHelp(.tune, "eq set [--device DEVICE] <band> <gain> …", "change bands on the current device, or on DEVICE",
                    examples: ["eq set 64hz +4 1khz -3", "eq set --device JBL 16khz +1"]),
        CommandHelp(.tune, "eq preamp [--device DEVICE] <gain>", "the preamp of the curve", examples: ["eq preamp -1.5"]),
        CommandHelp(.tune, "eq flat [--device DEVICE]", "everything to 0, dropping the preset, filters and any import"),
        CommandHelp(.tune, "eq copy --to DEVICE", "copy the current device's curve onto DEVICE", examples: ["eq copy --to AirPods"]),
        CommandHelp(.tune, "eq preset", "list presets; the current device's one marked *"),
        CommandHelp(.tune, "eq preset save|use <name> [--device DEVICE]", "save the curve as <name> / apply <name>",
                    examples: ["eq preset save night", "eq preset use favourite"]),
        CommandHelp(.tune, "eq preset show|rm <name>", "show / delete a preset"),
        CommandHelp(.tune, "eq preset rename <old> <new>", "rename a preset; devices using it follow"),
        CommandHelp(.tune, "eq import <file|url|name> [--device DEVICE] [--source SOURCE] [--keep-bands] [--refresh]",
                    "apply an AutoEq correction by headphone name, or from a file or URL",
                    examples: ["eq import \"WH-1000XM4\"", "eq import file.txt"]),
        CommandHelp(.tune, "eq import --clear [--device DEVICE]", "drop the imported correction, keep hand-tuned bands"),
        CommandHelp(.tune, "eq undo [--list]", "restore the config before the last change (twice = redo); --list shows the backups"),
        CommandHelp(.tune, "eq on | eq off", "enable / bypass"),
        CommandHelp(.setup, "eq init", "write the default config if none exists"),
        CommandHelp(.setup, "eq doctor", "diagnose config, daemon, permission and audio"),
        CommandHelp(.setup, "eq daemon", "run the audio engine (used by the LaunchAgent)"),
    ]

    static func entries(for command: String) -> [CommandHelp] {
        all.filter { $0.commands.contains(command) }
    }
}

/// Lays the help out at a given width. Everything is measured on the plain text first and painted
/// last, so escapes never count towards a line's length.
enum HelpRenderer {
    private typealias Run = (text: String, ink: Paint.Ink?)
    private typealias Word = [Run]

    static let narrow = 60

    static func render(width: Int, paint: Bool, entries: [CommandHelp] = CommandHelp.all, footer: Bool = true) -> String {
        let width = max(width, 20)
        let column = invocationColumn(entries, width: width)
        var lines: [String] = []
        let grouped = entries.count == CommandHelp.all.count
        for group in CommandHelp.Group.allCases {
            let members = entries.filter { $0.group == group }
            guard !members.isEmpty else { continue }
            if grouped {
                if !lines.isEmpty { lines.append("") }
                lines.append(Paint.ink(.dim, group.rawValue, on: paint))
            }
            for entry in members {
                lines += block(entry, width: width, column: column).map { line($0, paint: paint) }
            }
        }
        if footer {
            lines.append("")
            lines += footerLines(width: width).map { line($0, paint: paint) }
        }
        return lines.joined(separator: "\n")
    }

    static func plain(width: Int = 80) -> String { render(width: width, paint: false) }

    private static func invocationColumn(_ entries: [CommandHelp], width: Int) -> Int {
        let cap = (width - 6) * 45 / 100
        let lengths = entries.map { length(words($0.invocation)) }
        return max(lengths.filter { $0 <= cap }.max() ?? cap, 1)
    }

    /// A line is a list of words at an indent; `nil` for an empty line.
    private typealias Line = (indent: Int, words: [Word])

    private static func block(_ entry: CommandHelp, width: Int, column: Int) -> [Line] {
        let invocation = words(entry.invocation)
        let summary = entry.summary.split(separator: " ").map { [Run(String($0), nil)] as Word }
        let examples = entry.examples.map { example in example.split(separator: " ").map { [Run(String($0), .dim)] as Word } }
        if width < narrow {
            var lines = wrap(invocation, width: width - 2, hang: 2).map { Line(2 + $0.indent, $0.words) }
            lines += wrap(summary, width: width - 4, hang: 0).map { Line(4 + $0.indent, $0.words) }
            for example in examples { lines += wrap(example, width: width - 6, hang: 2).map { Line(6 + $0.indent, $0.words) } }
            return lines
        }
        let descriptionStart = 2 + column + 2
        let left = wrap(invocation, width: column, hang: 2)
        var right = wrap(summary, width: width - descriptionStart, hang: 0)
        for example in examples {
            right += wrap(example, width: width - descriptionStart - 2, hang: 2).map { Line($0.indent + 2, $0.words) }
        }
        return (0..<max(left.count, right.count)).map { row -> Line in
            var words: [Word] = []
            var indent = 2
            if row < left.count {
                indent += left[row].indent
                words = left[row].words
            }
            if row < right.count {
                let used = row < left.count ? 2 + left[row].indent + length(left[row].words) : 2
                let gap = descriptionStart + right[row].indent - used
                if words.isEmpty {
                    indent = descriptionStart + right[row].indent
                } else {
                    words.append([Run(String(repeating: " ", count: max(gap - 2, 0)), nil)])
                }
                words += right[row].words
            }
            return Line(indent, words)
        }
    }

    private static func footerLines(width: Int) -> [Line] {
        let bands = [[Run("bands:", .dim)]] + Config.bandLabels.map { [Run($0, .yellow)] as Word }
        let range = "\(Int(Config.gainRange.lowerBound))…+\(Int(Config.gainRange.upperBound))"
        let gains: [Word] = [[Run("gains:", .dim)], [Run(range, .yellow)], [Run("dB", nil)]]
        let json: [Word] = [[Run("--json", .cyan)]] + "on any command: the answer as JSON".split(separator: " ").map { [Run(String($0), nil)] }
        let one: [Word] = [[Run("eq", nil)], [Run("<command>", .yellow)], [Run("--help", .cyan)]]
            + "for one command".split(separator: " ").map { [Run(String($0), nil)] }
        return [bands, gains, json, one].flatMap { wrap($0, width: width, hang: 2) }
    }

    private static func words(_ invocation: [[CommandHelp.Token]]) -> [Word] {
        invocation.map { word in word.map { Run($0.text, $0.ink) } }
    }

    private static func length(_ word: Word) -> Int { word.reduce(0) { $0 + $1.text.count } }

    private static func length(_ words: [Word]) -> Int {
        words.isEmpty ? 0 : words.reduce(0) { $0 + length($1) } + words.count - 1
    }

    /// Greedy word wrap; continuation lines hang by `hang`. A word wider than the room is cut, so
    /// no line ever exceeds `width` however narrow the terminal.
    private static func wrap(_ words: [Word], width: Int, hang: Int) -> [Line] {
        let width = max(width, 1)
        let hang = width > hang + 1 ? hang : 0
        var lines: [Line] = []
        var current: [Word] = []
        var used = 0
        func room() -> Int { width - (lines.isEmpty ? 0 : hang) }
        func flush() { lines.append(Line(lines.isEmpty ? 0 : hang, current)); current = []; used = 0 }
        for word in words.flatMap({ split($0, width - hang) }) {
            let needed = length(word) + (current.isEmpty ? 0 : 1)
            if !current.isEmpty && used + needed > room() { flush() }
            used += length(word) + (current.isEmpty ? 0 : 1)
            current.append(word)
        }
        if !current.isEmpty || lines.isEmpty { flush() }
        return lines
    }

    private static func split(_ word: Word, _ limit: Int) -> [Word] {
        let limit = max(limit, 1)
        guard length(word) > limit else { return [word] }
        var pieces: [Word] = []
        var piece: Word = []
        var count = 0
        for run in word {
            for character in run.text {
                if count == limit { pieces.append(piece); piece = []; count = 0 }
                if let last = piece.last, last.ink == run.ink {
                    piece[piece.count - 1].text.append(character)
                } else {
                    piece.append(Run(String(character), run.ink))
                }
                count += 1
            }
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces
    }

    private static func line(_ line: Line, paint: Bool) -> String {
        let body = line.words.map { word in word.map { Paint.ink($0.ink, $0.text, on: paint) }.joined() }.joined(separator: " ")
        return String(repeating: " ", count: max(line.indent, 0)) + body
    }
}
