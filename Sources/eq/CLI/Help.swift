import Foundation

struct CommandHelp {
    enum Group: String, CaseIterable { case look, tune, device, preset, app, filter, `import`, setup }

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
    var usage: String
    /// One inner array per space-separated word, so `[--device` stays one unbreakable unit.
    var invocation: [[Token]]
    var summary: String
    /// Changes the config (or the system output), so it takes `--dry-run`.
    var writes: Bool
    var examples: [String] = []

    init(_ group: Group, _ invocation: String, _ summary: String, writes: Bool = false, examples: [String] = []) {
        self.group = group
        self.usage = invocation
        self.invocation = invocation.split(separator: " ").map { Self.tokens(String($0)) }
        self.summary = summary
        self.writes = writes
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
        CommandHelp(.look, "eq status", "is the daemon alive, on which device, at what rate"),
        CommandHelp(.look, "eq watch [--zones]", "the live equalizer; tune with 1…0, h for keys, q to quit"),
        CommandHelp(.look, "eq zones", "instrument frequency ranges and the bands they touch"),
        CommandHelp(.look, "eq export [--format FORMAT] [--device DEVICE] [--out FILE] [--force]",
                    "write the curve for another tool: apo (default, Equalizer APO / Peace / SoundSource text), graphiceq (AutoEq's 127 points, for Wavelet), eqmac (bands only), camilla (CamillaDSP YAML), json (eq's own profile); to stdout, or atomically to FILE, which must not exist unless --force",
                    examples: ["eq export > config.txt", "eq export --format graphiceq --out GraphicEQ.txt", "eq export --format camilla --device JBL"]),
        CommandHelp(.look, "eq stream", "meter frames as JSON lines, 30 per second, until Ctrl-C"),
        CommandHelp(.look, "eq events", "state changes as JSON lines until Ctrl-C: device, rate, profile, enabled, solo, daemon, app, mode, target; never meter ticks",
                    examples: ["eq events | jq -r 'select(.event == \"device\") | .device'"]),
        CommandHelp(.tune, "eq set [--device DEVICE] <band> <gain> …", "change bands on the current device, or on DEVICE", writes: true,
                    examples: ["eq set 64hz +4 1khz -3", "eq set --device JBL 16khz +1"]),
        CommandHelp(.tune, "eq preamp [--device DEVICE] <gain>", "the preamp of the curve", writes: true, examples: ["eq preamp -1.5"]),
        CommandHelp(.tune, "eq bass [--device DEVICE] <gain>", "bass boost on top of the curve: AutoEq's low shelf at 105 Hz, Q 0.7; 0 removes it",
                    writes: true, examples: ["eq bass +3"]),
        CommandHelp(.tune, "eq treble [--device DEVICE] <gain>", "treble boost on top of the curve: AutoEq's high shelf at 10 kHz, Q 0.7",
                    writes: true, examples: ["eq treble -2"]),
        CommandHelp(.tune, "eq tilt [--device DEVICE] <slope>", "tilt the whole curve by <slope> dB per octave around 632 Hz, -1.2…+1.2; positive is brighter",
                    writes: true, examples: ["eq tilt -0.5"]),
        CommandHelp(.tune, "eq boost [<instrument> <gain>] [--device DEVICE]",
                    "turn an instrument up or down: one peak over its character range (voice 2–5 kHz, kick 50–100 Hz, …), -12…+12 dB; 0 removes it, alone it lists every instrument's range and gain",
                    writes: true, examples: ["eq boost voice +3", "eq boost kick -2", "eq boost"]),
        CommandHelp(.tune, "eq comp gentle|night|off|none [--device DEVICE]",
                    "light compression after the EQ, as loud as before: gentle is 2:1 from -18 dBFS and glues music; night is 4:1 from -30 dBFS and brings quiet dialogue up and explosions down; off or none removes it; any case",
                    writes: true, examples: ["eq comp night"]),
        CommandHelp(.tune, "eq color tape|tube <amount> [--device DEVICE] | eq color off [--device DEVICE]",
                    "saturation after the compressor, as loud as before: tape is a symmetric soft clip, tube also adds even harmonics; <amount> 0…1 is the drive, 0 or off removes it",
                    writes: true, examples: ["eq color tape 0.3"]),
        CommandHelp(.tune, "eq flat [--device DEVICE]", "everything to 0, dropping the preset, filters, bass/treble/tilt, boosts, compression, color and any import", writes: true),
        CommandHelp(.tune, "eq on | eq off", "enable / bypass", writes: true),
        CommandHelp(.tune, "eq undo [--list]", "step the config back one saved version; repeat to go further back; --list is now eq history", writes: true),
        CommandHelp(.tune, "eq redo", "step forward again after eq undo", writes: true),
        CommandHelp(.tune, "eq history", "list saved versions with their time and curve, marking the current one",
                    examples: ["eq undo --list"]),
        CommandHelp(.device, "eq device [list]", "known profiles and connected outputs; the current one marked *"),
        CommandHelp(.device, "eq device use DEVICE", "make DEVICE the system output; its curve follows it", writes: true,
                    examples: ["eq device use AirPods"]),
        CommandHelp(.device, "eq device copy --to|--device DEVICE", "copy the current device's curve onto DEVICE", writes: true,
                    examples: ["eq device copy --to AirPods"]),
        CommandHelp(.preset, "eq preset [list]", "list presets; the current device's one marked *"),
        CommandHelp(.preset, "eq preset save|use <name> [--device DEVICE]", "save the curve as <name> / apply <name>", writes: true,
                    examples: ["eq preset save night", "eq preset use favourite"]),
        CommandHelp(.preset, "eq preset show <name>", "show a preset"),
        CommandHelp(.preset, "eq preset rm <name>", "delete a preset", writes: true),
        CommandHelp(.preset, "eq preset rename <old> <new>", "rename a preset; devices using it follow", writes: true),
        CommandHelp(.app, "eq app [list]", "app rules, experimental: while an app plays, its preset is heard instead of the device's curve; the one heard now marked *"),
        CommandHelp(.app, "eq app set <app> <preset>", "while <app>, a bundle ID or an app's name, plays, hear <preset>; the first rule wins when two play at once",
                    writes: true, examples: ["eq app set Spotify favourite", "eq app set com.google.Chrome flat"]),
        CommandHelp(.app, "eq app rm <app>", "remove the rule for <app>", writes: true),
        CommandHelp(.app, "eq app on|off", "follow playing apps, or stop; off by default", writes: true),
        CommandHelp(.filter, "eq filter [list] [--device DEVICE]", "list the parametric filters, numbered as eq shows them"),
        CommandHelp(.filter, "eq filter add <type> <freq> <gain> [<q>] [--device DEVICE]",
                    "add a filter: peak lowshelf highshelf lowpass highpass notch bandpass; Q defaults to 1.41 for peak, notch and bandpass, 0.707 otherwise",
                    writes: true, examples: ["eq filter add peak 3k -2 2", "eq filter add highpass 30 0"]),
        CommandHelp(.filter, "eq filter set <n> <key>=<value> … [--device DEVICE]", "change filter <n>: freq, gain, q or type", writes: true,
                    examples: ["eq filter set 2 gain=-3 q=4"]),
        CommandHelp(.filter, "eq filter rm <n>|all [--device DEVICE]", "remove filter <n>, or every filter", writes: true),
        CommandHelp(.import, "eq import <file|url|name> [--device DEVICE] [--source SOURCE] [--variant VARIANT] [--keep-bands] [--refresh]",
                    "apply a correction by headphone name (AutoEq, then OPRA), or from a file or URL; VARIANT picks a state like anc-on, --source opra asks OPRA only",
                    writes: true,
                    examples: ["eq import \"WH-1000XM4\"", "eq import \"airpods pro 2\" --variant anc-on", "eq import \"HD 600\" --source opra", "eq import file.txt"]),
        CommandHelp(.import, "eq import --search <name> [--source SOURCE] [--refresh]",
                    "list the headphones a name matches in AutoEq and OPRA, with source and variant, without importing",
                    examples: ["eq import --search wh1000xm4"]),
        CommandHelp(.import, "eq import --clear [--device DEVICE]", "drop the imported correction, keep hand-tuned bands and filters", writes: true),
        CommandHelp(.setup, "eq init", "write the default config now (optional: the first change writes it)", writes: true),
        CommandHelp(.setup, "eq doctor", "diagnose config, daemon, permission and audio"),
        CommandHelp(.setup, "eq mode", "which path carries the EQ, tap or driver, and whether the EQ driver is installed"),
        CommandHelp(.setup, "eq mode driver|tap",
                    "driver (experimental): play through the EQ device, which needs no recording permission and shows no Privacy indicator; the first time, and after an update, it installs the driver EQ.app carries with one administrator prompt; tap: the process tap, the default; eq mode tap is also the way back if sound goes",
                    writes: true, examples: ["eq mode driver", "eq mode tap"]),
        CommandHelp(.setup, "eq driver uninstall",
                    "switch to tap, then remove the EQ driver from /Library/Audio/Plug-Ins/HAL and restart coreaudiod, with one administrator prompt; brew uninstall eq runs it",
                    writes: true),
        CommandHelp(.setup, "eq completions zsh|bash|fish", "print the shell completion script; the Homebrew cask installs all three",
                    examples: ["eq completions zsh > ~/.zfunc/_eq"]),
        CommandHelp(.setup, "eq man", "print the man page (roff)", examples: ["eq man | mandoc -a"]),
        CommandHelp(.setup, "eq daemon", "run the audio engine (used by the LaunchAgent)"),
    ]

    /// Spellings from before the noun groups, rewritten to the new shape before dispatch.
    static let aliases: [(old: String, new: [String])] = [("devices", ["device", "list"]), ("copy", ["device", "copy"])]

    static func canonical(_ args: [String]) -> [String] {
        guard let first = args.first, let alias = aliases.first(where: { $0.old == first }) else { return args }
        return alias.new + args.dropFirst()
    }

    static func entries(for command: String) -> [CommandHelp] {
        let command = canonical([command]).first ?? command
        return all.filter { $0.commands.contains(command) }
    }
}

/// The grammar the help table spells out, read back for completions, the man page and `--dry-run`.
extension CommandHelp {
    struct Flag: Equatable {
        var name: String
        /// The upper-case placeholder that follows, `DEVICE` in `--device DEVICE`; lower-case `<name>` after
        /// a flag is an operand, as in `--search <name>`.
        var value: String?
        var required: Bool
        /// Flags spelled together, `--to|--device`, share a group: either one satisfies it.
        var group: Int
    }

    struct Form: Equatable {
        var path: [String]
        var flags: [Flag]
        var operands: [String]
        /// The operands repeat, as the `…` in `eq set <band> <gain> …` says.
        var repeats: Bool
        var writes: Bool
    }

    var forms: [Form] {
        usage.components(separatedBy: " | ").flatMap { Self.forms(of: $0, writes: writes) }
    }

    private static func isCommandWord(_ core: Substring) -> Bool {
        !core.isEmpty && core.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "|" || $0 == "-" } && !core.hasPrefix("-")
    }

    private static func forms(of usage: String, writes: Bool) -> [Form] {
        let words = usage.split(separator: " ").dropFirst().map(Substring.init)
        var paths: [[String]] = [[]]
        var flags: [Flag] = []
        var operands: [String] = []
        var repeats = false
        var inPath = true
        var index = 0
        func core(_ word: Substring) -> Substring { word.drop { $0 == "[" }.reversed().drop { $0 == "]" }.reversed().reduce(into: "") { $0.append($1) } }
        while index < words.count {
            let word = words[index]
            let bare = core(word)
            index += 1
            if inPath, isCommandWord(bare) {
                let alternatives = bare.split(separator: "|").map(String.init)
                let extended = paths.flatMap { path in alternatives.map { path + [$0] } }
                paths = word.hasPrefix("[") ? paths + extended : extended
                continue
            }
            inPath = false
            if bare.hasPrefix("-") {
                var value: String?
                if index < words.count, case let next = core(words[index]), !next.isEmpty, next.allSatisfy(\.isUppercase) {
                    value = String(next)
                    index += 1
                }
                for name in bare.split(separator: "|") {
                    flags.append(Flag(name: String(name), value: value, required: !word.hasPrefix("["), group: index))
                }
            } else if bare == "…" {
                repeats = true
            } else if bare.hasPrefix("<") || (!bare.isEmpty && bare.allSatisfy(\.isUppercase)) {
                operands.append(String(bare))
            }
        }
        return paths.map { Form(path: $0, flags: flags, operands: operands, repeats: repeats, writes: writes) }
    }

    /// The form an argument list is an instance of: the longest path it starts with, among those whose
    /// required flags it has and whose flags cover every flag it uses. Old spellings are read as new.
    static func form(matching args: [String]) -> Form? {
        let args = canonical(args)
        // Only `--` flags: a lone dash starts a negative gain.
        let used = Set(args.filter { $0.hasPrefix("--") })
        let forms = all.flatMap(\.forms)
        let takesValue = Set(forms.flatMap { $0.flags.filter { $0.value != nil }.map(\.name) })
        var positional: [String] = []
        var skip = false
        for arg in args {
            if skip { skip = false } else if arg.hasPrefix("--") { skip = takesValue.contains(arg) } else { positional.append(arg) }
        }
        let candidates = forms.filter { form in
            guard positional.map({ $0.lowercased() }).starts(with: form.path), !form.path.isEmpty || positional.isEmpty, used.isSubset(of: Set(form.flags.map(\.name))) else { return false }
            let required = Set(form.flags.filter(\.required).map(\.group))
            return required.allSatisfy { group in form.flags.contains { $0.group == group && used.contains($0.name) } }
        }
        return candidates.max { $0.path.count < $1.path.count }
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
        func prose(_ text: String) -> [Word] { text.split(separator: " ").map { [Run(String($0), nil)] } }
        let json: [Word] = [[Run("--json", .cyan)]] + prose("on any command: the answer as JSON")
        let dryRun: [Word] = [[Run("--dry-run", .cyan)]] + prose("on a command that changes something: before → after, nothing written")
        let old: [Word] = [[Run("old spellings:", .dim)]] + CommandHelp.aliases.enumerated().flatMap { index, alias -> [Word] in
            [[Run("eq", nil)], [Run(alias.old, .bold), Run(index < CommandHelp.aliases.count - 1 ? "," : "", nil)]]
        } + prose("still work")
        let one: [Word] = [[Run("eq", nil)], [Run("<command>", .yellow)], [Run("--help", .cyan)]] + prose("for one command")
        return [bands, gains, json, dryRun, old, one].flatMap { wrap($0, width: width, hang: 4) }
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
