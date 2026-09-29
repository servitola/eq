import EQTerm
import Foundation

/// What the screen looks like: a flag for this run, else `tui.*` in eq.json, else the look's own
/// default; `NO_COLOR` and `TERM=dumb` take the colour away whatever was asked.
struct LookSettings: Equatable {
    var look = Look.studio
    /// nil is `auto`: the look's own palette.
    var palette: PaletteName?
    var depth = ColorDepth.truecolor
    /// nil is `auto`: the look's own meter.
    var meter: MeterStyle?
    /// nil: on in studio, off in console.
    var curve: Bool?
    var scale = true
    var peaks = true
    var paintsGround = false

    var paletteName: PaletteName { palette ?? look.palette }
    var meterStyle: MeterStyle { meter ?? look.meter }
    var showsCurve: Bool { curve ?? (look == .studio) }
    var theme: Theme { Theme(palette: .named(paletteName), depth: depth, paintsGround: paintsGround) }

    static let flagsUsage = "[--look LOOK] [--palette PALETTE] [--colors DEPTH] [--meter STYLE] [--curve|--no-curve] "
        + "[--scale|--no-scale] [--peaks|--no-peaks] [--background GROUND]"

    /// `flags` over `saved` over the defaults; an unknown value in eq.json is left out rather
    /// than refused, so a config written by a later eq still opens.
    static func resolve(flags: TUIOptions, saved: TUIOptions?, env: [String: String]) -> LookSettings {
        func pick<T: RawRepresentable>(_ key: KeyPath<TUIOptions, String?>) -> T? where T.RawValue == String {
            (flags[keyPath: key] ?? saved?[keyPath: key]).flatMap(T.init(rawValue:))
        }
        func flag(_ key: KeyPath<TUIOptions, Bool?>) -> Bool? { flags[keyPath: key] ?? saved?[keyPath: key] }
        var settings = LookSettings()
        settings.look = pick(\.look) ?? .studio
        settings.palette = pick(\.palette)
        settings.meter = pick(\.meter)
        settings.curve = flag(\.curve)
        settings.scale = flag(\.scale) ?? true
        settings.peaks = flag(\.peaks) ?? true
        settings.paintsGround = (flags.background ?? saved?.background) == "theme"
        let detected = ColorDepth.detect(env)
        let asked: ColorDepth? = pick(\.colors)
        settings.depth = detected == .none ? .none : (asked ?? detected)
        return settings
    }

    /// `--look NAME` and `--look=NAME` alike; a wrong value names the right ones.
    static func parseFlags(_ args: [String]) throws -> (options: TUIOptions, rest: [String]) {
        var options = TUIOptions()
        var rest: [String] = []
        var i = 0
        let valued: [String: (WritableKeyPath<TUIOptions, String?>, [String])] = [
            "--look": (\.look, Look.allCases.map(\.rawValue)),
            "--palette": (\.palette, ["auto"] + PaletteName.allCases.map(\.rawValue)),
            "--colors": (\.colors, ["auto"] + ColorDepth.allCases.map(\.rawValue)),
            "--meter": (\.meter, ["auto"] + MeterStyle.allCases.map(\.rawValue)),
            "--background": (\.background, ["terminal", "theme"]),
        ]
        let switches: [String: (WritableKeyPath<TUIOptions, Bool?>, Bool)] = [
            "--curve": (\.curve, true), "--no-curve": (\.curve, false), "--scale": (\.scale, true), "--no-scale": (\.scale, false),
            "--peaks": (\.peaks, true), "--no-peaks": (\.peaks, false),
        ]
        while i < args.count {
            let arg = args[i]
            i += 1
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if let (key, allowed) = valued[parts[0]] {
                let value: String
                if parts.count == 2 {
                    value = parts[1]
                } else {
                    guard i < args.count else { throw CLIError.usage("\(arg) needs one of: \(allowed.joined(separator: ", "))") }
                    value = args[i]
                    i += 1
                }
                guard allowed.contains(value) else {
                    throw CLIError.usage("\(parts[0]) \(value): expected one of \(allowed.joined(separator: ", "))")
                }
                options[keyPath: key] = value
            } else if let (key, on) = switches[arg] {
                options[keyPath: key] = on
            } else {
                rest.append(arg)
            }
        }
        return (options, rest)
    }
}
