import Foundation

/// Shell completion scripts built from the help table. The structure (commands, subcommands, flags,
/// which operand is which) is baked in; device names, presets, instruments and formats come from
/// `eq __complete <kind>` at completion time, which reads the config and Core Audio but never the daemon.
enum Completions {
    enum Shell: String, CaseIterable { case zsh, bash, fish }

    /// What an operand or a flag's value completes to.
    enum Kind: String {
        case devices, outputs, presets, instruments, formats, apps, bands, types, sources, files, none

        var words: [String] {
            switch self {
            case .bands: return Config.bandLabels.map { $0.lowercased() }
            case .types: return FilterType.allCases.map { $0.rawValue.lowercased() }
            case .sources: return ["opra"]
            default: return []
            }
        }

        static func of(_ placeholder: String, in path: [String]) -> Kind {
            switch placeholder {
            case "DEVICE" where path == ["device", "use"]: return .outputs
            case "DEVICE": return .devices
            case "FORMAT": return .formats
            case "FILE", "<file|url|name>": return .files
            case "SOURCE": return .sources
            case "<band>": return .bands
            case "<instrument>": return .instruments
            case "<type>": return .types
            case "<name>" where path.first == "preset", "<old>" where path.first == "preset", "<preset>": return .presets
            case "<app>": return .apps
            default: return .none
            }
        }
    }

    /// Everything one command path (`set`, `preset save`) completes: forms sharing a path pool
    /// their flags, and the first one with operands names them.
    struct Spec {
        var key: String
        var flags: [String]
        var operands: [Kind]
        var repeats: Bool
    }

    static var forms: [CommandHelp.Form] { CommandHelp.all.flatMap(\.forms).filter { !$0.path.isEmpty } }

    static var commands: [(name: String, summary: String)] {
        var seen: [String] = []
        for form in forms where !seen.contains(form.path[0]) { seen.append(form.path[0]) }
        return seen.map { name in
            let subs = subcommands(of: name)
            if !subs.isEmpty { return (name, subs.joined(separator: ", ")) }
            let summary = CommandHelp.all.first { $0.forms.contains { $0.path.first == name } }?.summary ?? ""
            let clause = summary.split(whereSeparator: { ";:(".contains($0) }).first.map(String.init) ?? summary
            return (name, clause.trimmingCharacters(in: .whitespaces))
        }
    }

    static func subcommands(of command: String) -> [String] {
        var subs: [String] = []
        for form in forms where form.path.count > 1 && form.path[0] == command && !subs.contains(form.path[1]) { subs.append(form.path[1]) }
        return subs
    }

    static var specs: [Spec] {
        var keys: [String] = []
        for form in forms where !keys.contains(form.path.joined(separator: " ")) { keys.append(form.path.joined(separator: " ")) }
        return keys.map { key in
            let members = forms.filter { $0.path.joined(separator: " ") == key }
            var flags: [String] = []
            for flag in members.flatMap(\.flags) where !flags.contains(flag.name) { flags.append(flag.name) }
            if members.contains(where: \.writes) { flags.append("--dry-run") }
            let operands = members.first { !$0.operands.isEmpty }
            return Spec(key: key, flags: flags, operands: operands.map { form in form.operands.map { Kind.of($0, in: form.path) } } ?? [],
                        repeats: operands?.repeats ?? false)
        }
    }

    /// Flags that take a value, grouped by what the value completes to.
    static var valueFlags: [(kind: Kind, flags: [String])] {
        var grouped: [(kind: Kind, flags: [String])] = []
        for form in forms {
            for flag in form.flags {
                guard let value = flag.value else { continue }
                let kind = Kind.of(value, in: form.path)
                if let at = grouped.firstIndex(where: { $0.kind == kind }) {
                    if !grouped[at].flags.contains(flag.name) { grouped[at].flags.append(flag.name) }
                } else {
                    grouped.append((kind, [flag.name]))
                }
            }
        }
        return grouped
    }

    static let globalFlags = ["--help", "--json"]

    static func command(_ args: [String]) throws -> Output {
        guard args.count == 1, let shell = Shell(rawValue: args[0]) else { throw CLIError.usage("eq completions zsh|bash|fish") }
        let text = script(shell)
        return Output(text, ["shell": shell.rawValue, "script": text])
    }

    static func script(_ shell: Shell) -> String {
        switch shell {
        case .zsh: return zsh()
        case .bash: return bash()
        case .fish: return fish()
        }
    }

    static func list(_ args: [String], _ ctx: CLIContext) -> Output {
        let config = try? CLI.loadConfig(ctx)
        let names: [String]
        switch args.first.flatMap(Kind.init(rawValue:)) {
        case .devices?:
            let known = ctx.connectedDevices().map(\.name) + (config?.devices.values.compactMap(\.name) ?? [])
            names = Set(known).sorted { $0.lowercased() < $1.lowercased() }
        case .outputs?: names = Set(ctx.connectedDevices().map(\.name)).sorted { $0.lowercased() < $1.lowercased() }
        case .presets?: names = (config?.presets ?? [:]).keys.sorted { $0.lowercased() < $1.lowercased() }
        case .instruments?: names = Instruments.all.map(\.name)
        case .formats?: names = ExportFormat.allCases.map(\.rawValue)
        case .apps?:
            let ids = ctx.audioApps().map(\.id) + (config?.apps ?? []).map(\.app)
            names = Set(ids).sorted { $0.lowercased() < $1.lowercased() }
        default: names = []
        }
        return Output(names.joined(separator: "\n"), names)
    }

    // MARK: - Shared pieces

    private static let header = "eq completions for %@, printed by `eq completions %@`; values come from `eq __complete`."

    /// A single-quoted word for zsh and bash.
    private static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func fishQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private static var skipping: [String] { valueFlags.flatMap(\.flags) }

    private static func aliasLines(_ indent: String, _ rewrite: (String, [String]) -> String) -> [String] {
        CommandHelp.aliases.map { indent + rewrite($0.old, $0.new) }
    }

    // MARK: - zsh

    private static func zsh() -> String {
        var lines = ["#compdef eq", "# " + String(format: header, "zsh", "zsh"), ""]
        lines += ["_eq_value() {", "  local -a values", "  case $1 in"]
        for kind in [Kind.devices, .outputs, .presets, .instruments, .formats, .apps] {
            lines.append("    (\(kind.rawValue)) values=(\"${(@f)$(eq __complete \(kind.rawValue) 2>/dev/null)}\") ;;")
        }
        for kind in [Kind.bands, .types, .sources] { lines.append("    (\(kind.rawValue)) values=(\(kind.words.joined(separator: " "))) ;;") }
        lines += ["    (files) _files; return ;;", "    (*) return 1 ;;", "  esac", "  values=(${values:#})", "  compadd -a values", "}", ""]

        lines += ["_eq_spec() {", "  flags=() operands=() repeats=0", "  case $1 in"]
        for spec in specs {
            lines.append("    (\(quoted(spec.key))) flags=(\(spec.flags.joined(separator: " "))); operands=(\(spec.operands.map(\.rawValue).joined(separator: " "))); repeats=\(spec.repeats ? 1 : 0) ;;")
        }
        lines += ["  esac", "}", ""]

        lines += ["_eq() {", "  local cur=${words[CURRENT]} w key used=1 skip=0 index repeats", "  local -a positional flags operands subs commands", ""]
        lines.append("  case ${words[CURRENT-1]} in")
        for group in valueFlags {
            lines.append("    (\(group.flags.joined(separator: "|"))) " + (group.kind == .none ? "return 0 ;;" : "_eq_value \(group.kind.rawValue); return ;;"))
        }
        lines += ["  esac", "  for w in \"${(@)words[2,CURRENT-1]}\"; do", "    if (( skip )); then skip=0; continue; fi", "    case $w in",
                  "      (\(skipping.joined(separator: "|"))) skip=1 ;;", "      (-[0-9.]*) positional+=(\"$w\") ;;", "      (-*) ;;",
                  "      (*) positional+=(\"$w\") ;;", "    esac", "  done", ""]
        lines += ["  if (( ! $#positional )); then", "    if [[ $cur == -* ]]; then compadd -- \(globalFlags.joined(separator: " ")); return; fi", "    commands=("]
        for command in commands { lines.append("      " + quoted(command.name + ":" + command.summary.replacingOccurrences(of: ":", with: "\\:"))) }
        lines += ["    )", "    _describe -t commands 'eq command' commands", "    return", "  fi", ""]
        lines.append("  case $positional[1] in")
        lines += aliasLines("    ") { old, new in "(\(old)) positional=(\(new.joined(separator: " ")) \"${(@)positional[2,-1]}\") ;;" }
        lines += ["  esac", "  case $positional[1] in"]
        for command in commands.map(\.name) where !subcommands(of: command).isEmpty {
            lines.append("    (\(command)) subs=(\(subcommands(of: command).joined(separator: " "))) ;;")
        }
        lines += ["  esac", "  key=$positional[1]", "  if (( $#subs )); then", "    if (( $#positional == 1 )); then", "      _eq_spec $key",
                  "      if [[ $cur == -* ]]; then compadd -a flags; compadd -- \(globalFlags.joined(separator: " ")); else compadd -a subs; fi",
                  "      return", "    fi", "    if (( ${subs[(Ie)$positional[2]]} )); then key=\"$key $positional[2]\"; used=2; fi", "  fi",
                  "  _eq_spec $key", "  if [[ $cur == -* ]]; then compadd -a flags; compadd -- \(globalFlags.joined(separator: " ")); return; fi",
                  "  index=$(( $#positional - used ))", "  (( repeats && $#operands )) && index=$(( index % $#operands ))",
                  "  (( index < $#operands )) && _eq_value $operands[index+1]", "}", ""]
        lines += ["if [[ $zsh_eval_context[-1] == loadautofunc ]]; then", "  _eq \"$@\"", "else", "  compdef _eq eq", "fi"]
        return lines.joined(separator: "\n")
    }

    // MARK: - bash

    private static func bash() -> String {
        var lines = ["# " + String(format: header, "bash", "bash"), ""]
        lines += ["# Candidates arrive one per line and go back shell-quoted, so names with spaces survive.", "_eq_add() {",
                  "  local word=${cur//\\\\/} line quoted", "  word=${word#[\\\"\\']}", "  while IFS= read -r line; do",
                  "    [[ -n $line && $line == \"$word\"* ]] || continue", "    printf -v quoted '%q' \"$line\"", "    COMPREPLY+=(\"$quoted\")",
                  "  done", "}", ""]
        lines += ["_eq_value() {", "  case $1 in"]
        for kind in [Kind.devices, .outputs, .presets, .instruments, .formats, .apps] {
            lines.append("    \(kind.rawValue)) _eq_add <<< \"$(eq __complete \(kind.rawValue) 2>/dev/null)\" ;;")
        }
        for kind in [Kind.bands, .types, .sources] {
            lines.append("    \(kind.rawValue)) _eq_add <<< \"$(printf '%s\\n' \(kind.words.joined(separator: " ")))\" ;;")
        }
        lines += ["    files) local line; while IFS= read -r line; do COMPREPLY+=(\"$line\"); done < <(compgen -f -- \"$cur\"); compopt -o filenames 2>/dev/null ;;", "  esac", "}", ""]

        lines += ["_eq_spec() {", "  flags=() operands=() repeats=0", "  case $1 in"]
        for spec in specs {
            lines.append("    \(quoted(spec.key))) flags=(\(spec.flags.joined(separator: " "))); operands=(\(spec.operands.map(\.rawValue).joined(separator: " "))); repeats=\(spec.repeats ? 1 : 0) ;;")
        }
        lines += ["  esac", "}", ""]

        lines += ["_eq() {", "  local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]} w key used=1 skip=0 index repeats=0 i",
                  "  local -a positional flags operands subs", "  positional=() subs=()", "  COMPREPLY=()", "  case $prev in"]
        for group in valueFlags {
            lines.append("    \(group.flags.joined(separator: "|"))) " + (group.kind == .none ? "return 0 ;;" : "_eq_value \(group.kind.rawValue); return 0 ;;"))
        }
        lines += ["  esac", "  for (( i = 1; i < COMP_CWORD; i++ )); do", "    w=${COMP_WORDS[i]}", "    if (( skip )); then skip=0; continue; fi",
                  "    case $w in", "      \(skipping.joined(separator: "|"))) skip=1 ;;", "      -[0-9.]*) positional+=(\"$w\") ;;", "      -*) ;;",
                  "      *) positional+=(\"$w\") ;;", "    esac", "  done", ""]
        lines += ["  if (( ${#positional[@]} == 0 )); then", "    if [[ $cur == -* ]]; then COMPREPLY=($(compgen -W '\(globalFlags.joined(separator: " "))' -- \"$cur\")); return 0; fi",
                  "    COMPREPLY=($(compgen -W '\(commands.map(\.name).joined(separator: " "))' -- \"$cur\"))", "    return 0", "  fi", ""]
        lines.append("  case ${positional[0]} in")
        lines += aliasLines("    ") { old, new in "\(old)) positional=(\(new.joined(separator: " ")) \"${positional[@]:1}\") ;;" }
        lines += ["  esac", "  case ${positional[0]} in"]
        for command in commands.map(\.name) where !subcommands(of: command).isEmpty {
            lines.append("    \(command)) subs=(\(subcommands(of: command).joined(separator: " "))) ;;")
        }
        lines += ["  esac", "  key=${positional[0]}", "  if (( ${#subs[@]} )); then", "    if (( ${#positional[@]} == 1 )); then", "      _eq_spec \"$key\"",
                  "      if [[ $cur == -* ]]; then COMPREPLY=($(compgen -W \"${flags[*]} \(globalFlags.joined(separator: " "))\" -- \"$cur\"))",
                  "      else COMPREPLY=($(compgen -W \"${subs[*]}\" -- \"$cur\")); fi", "      return 0", "    fi",
                  "    for w in \"${subs[@]}\"; do [[ $w == \"${positional[1]}\" ]] && { key=\"$key $w\"; used=2; }; done", "  fi",
                  "  _eq_spec \"$key\"",
                  "  if [[ $cur == -* ]]; then COMPREPLY=($(compgen -W \"${flags[*]} \(globalFlags.joined(separator: " "))\" -- \"$cur\")); return 0; fi",
                  "  index=$(( ${#positional[@]} - used ))", "  (( repeats && ${#operands[@]} )) && index=$(( index % ${#operands[@]} ))",
                  "  (( index < ${#operands[@]} )) && _eq_value \"${operands[index]}\"", "  return 0", "}", "", "complete -F _eq eq"]
        return lines.joined(separator: "\n")
    }

    // MARK: - fish

    private static func fish() -> String {
        var lines = ["# " + String(format: header, "fish", "fish"), ""]
        lines += ["function __eq_value", "    switch $argv[1]"]
        for kind in [Kind.devices, .outputs, .presets, .instruments, .formats, .apps] {
            lines += ["        case \(kind.rawValue)", "            eq __complete \(kind.rawValue) 2>/dev/null"]
        }
        for kind in [Kind.bands, .types, .sources] {
            lines += ["        case \(kind.rawValue)", "            printf '%s\\n' \(kind.words.joined(separator: " "))"]
        }
        lines += ["        case files", "            __fish_complete_path (commandline -ct)", "    end", "end", ""]

        lines += ["function __eq_spec", "    set -g __eq_flags", "    set -g __eq_operands", "    set -g __eq_repeats 0", "    switch $argv[1]"]
        for spec in specs {
            lines.append("        case \(fishQuoted(spec.key))")
            if !spec.flags.isEmpty { lines.append("            set __eq_flags \(spec.flags.joined(separator: " "))") }
            if !spec.operands.isEmpty { lines.append("            set __eq_operands \(spec.operands.map(\.rawValue).joined(separator: " "))") }
            if spec.repeats { lines.append("            set __eq_repeats 1") }
        }
        lines += ["    end", "end", ""]

        // `switch` would read a word like `--device` as its own option, so flags go through `contains`.
        lines += ["function __eq_complete", "    set -l words (commandline -opc)", "    set -e words[1]", "    set -l cur (commandline -ct)",
                  "    if set -q words[1]"]
        for group in valueFlags {
            lines += ["        if contains -- $words[-1] \(group.flags.joined(separator: " "))",
                      group.kind == .none ? "            return" : "            __eq_value \(group.kind.rawValue); return", "        end"]
        }
        lines += ["    end", "    set -l positional", "    set -l skip 0", "    for w in $words", "        if test $skip -eq 1", "            set skip 0",
                  "            continue", "        end", "        if contains -- $w \(skipping.joined(separator: " "))", "            set skip 1",
                  "        else if string match -qr -- '^-[0-9.]' $w; or not string match -q -- '-*' $w", "            set -a positional $w", "        end",
                  "    end", "    if not set -q positional[1]", "        if string match -q -- '-*' $cur",
                  "            printf '%s\\n' \(globalFlags.joined(separator: " "))", "        else"]
        for command in commands { lines.append("            printf '%s\\t%s\\n' \(fishQuoted(command.name)) \(fishQuoted(command.summary))") }
        lines += ["        end", "        return", "    end", "    switch $positional[1]"]
        for alias in CommandHelp.aliases {
            lines += ["        case \(alias.old)", "            set positional[1] \(alias.new.dropFirst().joined(separator: " "))",
                      "            set positional \(alias.new[0]) $positional"]
        }
        lines += ["    end", "    set -l subs", "    switch $positional[1]"]
        for command in commands.map(\.name) where !subcommands(of: command).isEmpty {
            lines += ["        case \(command)", "            set subs \(subcommands(of: command).joined(separator: " "))"]
        }
        lines += ["    end", "    set -l key $positional[1]", "    set -l used 1", "    if set -q subs[1]", "        if test (count $positional) -eq 1",
                  "            __eq_spec $key", "            if string match -q -- '-*' $cur",
                  "                printf '%s\\n' $__eq_flags \(globalFlags.joined(separator: " "))", "            else", "                printf '%s\\n' $subs",
                  "            end", "            return", "        end", "        if contains -- $positional[2] $subs", "            set key \"$key $positional[2]\"",
                  "            set used 2", "        end", "    end", "    __eq_spec $key", "    if string match -q -- '-*' $cur",
                  "        printf '%s\\n' $__eq_flags \(globalFlags.joined(separator: " "))", "        return", "    end",
                  "    set -l index (math (count $positional) - $used)", "    set -l n (count $__eq_operands)",
                  "    if test $__eq_repeats -eq 1 -a $n -gt 0", "        set index (math $index % $n)", "    end", "    if test $index -lt $n",
                  "        __eq_value $__eq_operands[(math $index + 1)]", "    end", "end", "", "complete -c eq -f -a '(__eq_complete)'"]
        return lines.joined(separator: "\n")
    }
}
