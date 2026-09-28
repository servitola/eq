import Foundation

/// `eq man`: a man(7) page built from the help table, so it lists exactly what `eq --help` does.
enum ManPage {
    static func command(_ args: [String]) throws -> Output {
        guard args.isEmpty else { throw CLIError.usage("eq man") }
        let page = render(version: Build.version)
        return Output(page, ["page": page])
    }

    /// roff wants ASCII: a hyphen is `\-` so it stays a minus in flags, anything else outside ASCII
    /// is spelled `\[uXXXX]`, and a line may not start with `.` or `'`, which would make it a request.
    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\e"
            case "-": out += "\\-"
            default: out += scalar.isASCII ? String(scalar) : String(format: "\\[u%04X]", scalar.value)
            }
        }
        return out.hasPrefix(".") || out.hasPrefix("'") ? "\\&" + out : out
    }

    static func render(version: String) -> String {
        // A release is CalVer, its own date; a dev build has none, so it takes today's.
        let date = version.range(of: #"^\d{4}\.\d{2}\.\d{2}"#, options: .regularExpression)
            .map { version[$0].replacingOccurrences(of: ".", with: "-") } ?? ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: .withFullDate)
        var lines = [
            ".TH EQ 1 \"\(date)\" \"eq \(escape(version))\" \"General Commands Manual\"",
            ".SH NAME",
            "eq \\- headless per\\-device system equalizer for macOS",
            ".SH SYNOPSIS",
            ".nf",
        ]
        lines += CommandHelp.all.map { escape($0.usage) }
        lines += [
            ".fi",
            ".SH DESCRIPTION",
            escape("eq equalizes all system audio through a Core Audio process tap, with a ten-band curve, parametric filters, "
                + "bass, treble, tilt and instrument knobs per output device. A LaunchAgent runs eq daemon; every other command "
                + "reads or edits the config, which the daemon picks up within a tenth of a second."),
            ".SH COMMANDS",
        ]
        for group in CommandHelp.Group.allCases {
            let members = CommandHelp.all.filter { $0.group == group }
            guard !members.isEmpty else { continue }
            lines.append(".SS \(group.rawValue.capitalized)")
            for entry in members {
                lines += [".TP", ".B", escape(entry.usage), escape(entry.summary)]
                if entry.writes { lines += [".br", escape("Takes --dry-run.")] }
                if !entry.examples.isEmpty {
                    lines += [".RS", ".nf"] + entry.examples.map(escape) + [".fi", ".RE"]
                }
            }
        }
        lines += [".SS Old spellings", escape("Still accepted, and read as the new form:"), ".RS", ".nf"]
        lines += CommandHelp.aliases.map { escape("eq \($0.old)  =  eq \($0.new.joined(separator: " "))") }
        lines += [".fi", ".RE"]
        lines += [
            ".SH OPTIONS",
            ".TP", ".B", escape("--json"), escape("On any command: the answer as one JSON document on stdout; exit codes unchanged."),
            ".TP", ".B", escape("--dry-run"),
            escape("On a command that changes the config or the output: run it against a copy, print the curve before and after "
                + "(with --json, {\"before\": ..., \"after\": ...}) and write nothing: no save, no backup, no history entry."),
            ".TP", ".BR \\-h \", \" \\-\\-help", escape("The help for one command, or all of it."),
            ".PP",
            escape("Bands are \(Config.bandLabels.joined(separator: " ")); gains \(Int(Config.gainRange.lowerBound)) to +\(Int(Config.gainRange.upperBound)) dB. "
                + "DEVICE is any piece of a device's name, matched without regard to case."),
            ".SH ENVIRONMENT",
            ".TP", ".B EQ_CONFIG", escape("The config file instead of ~/.config/eq/eq.json."),
            ".TP", ".B EQ_STATUS", escape("The daemon's status file instead of the default."),
            ".TP", ".B EQ_CACHE", escape("The AutoEq index cache directory instead of ~/.cache/eq."),
            ".TP", ".B NO_COLOR", escape("Set to anything: no colour. Colour is also off when stdout is not a terminal or TERM is dumb."),
            ".SH FILES",
            ".TP", ".I ~/.config/eq/eq.json", escape("Curves per device, presets, hooks. Edited by hand or by eq; the daemon watches it."),
            ".TP", ".I ~/.config/eq/eq.json.1 ... eq.json.10", escape("The previous versions eq undo and eq history walk through."),
            ".TP", ".I ~/.cache/eq", escape("The AutoEq and OPRA indexes eq import searches."),
            ".SH EXIT STATUS",
            escape("0 on success, 1 when something failed (no daemon, a network error, a failing eq doctor), 2 on a usage error."),
            ".SH SEE ALSO",
            escape("https://github.com/servitola/eq"),
        ]
        return lines.joined(separator: "\n")
    }
}
