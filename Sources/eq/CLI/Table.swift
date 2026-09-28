import Foundation

enum Table {
    static func gain(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }

    static let width = 6

    static let shortLabels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    /// With a `focus`, labels inside it drop the dim so the focused bands read first.
    static func labelsRow(width: Int = width, short: Bool = false, columns: Int = Config.bandLabels.count,
                          bold: Int? = nil, focus: Set<Int>? = nil) -> String {
        let labels = (short ? shortLabels : Config.bandLabels).prefix(max(columns, 0)).map { $0.leftPadded(to: width) }
        var line = "", run = "", ink: Paint.Ink?
        for (i, label) in labels.enumerated() {
            let next: Paint.Ink? = i == bold ? .bold : (focus?.contains(i) == true ? nil : .dim)
            if next != ink, !run.isEmpty { line += Paint.ink(ink, run, on: Paint.enabled); run = "" }
            ink = next
            run += label
        }
        return line + (run.isEmpty ? "" : Paint.ink(ink, run, on: Paint.enabled))
    }

    /// Below six columns "+12.0" plus a gap no longer fits, so the cell shows whole decibels.
    static func gainsRow(_ bands: [Double], width: Int = width, dimmed: Set<Int> = []) -> String {
        bands.enumerated().map { i, value -> String in
            let text = width >= self.width ? gain(value) : wholeGain(value)
            return Paint.ink(dimmed.contains(i) ? .dim : Paint.gain(value), text.leftPadded(to: width))
        }.joined()
    }

    /// Numbers read from the status file are the daemon's word, not a guarantee: `Int(1e300)` traps.
    static func whole(_ value: Double) -> String {
        value.isFinite ? String(format: "%.0f", value.rounded(.towardZero)) : "?"
    }

    private static func wholeGain(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let whole = Int(min(max(value, -99), 99).rounded())
        return whole > 0 ? "+\(whole)" : "\(whole)"
    }

    typealias PresetMark = (name: String, modified: Bool)

    static func profile(_ profile: Profile, header: String, preset: PresetMark? = nil) -> String {
        let preamp = Paint.ink(Paint.gain(profile.preamp), gain(profile.preamp))
        let painted = preset.map { paintedHeader(header, preset: $0) } ?? paintedHeader(header)
        var rows = ["\(painted)   preamp: \(preamp) dB"]
        // Piped output keeps the v1 three-line shape that scripts already parse.
        if Paint.enabled {
            rows.append(profile.bands.map { Paint.ink(Paint.gain($0), Paint.glyph(for: $0).leftPadded(to: width)) }.joined())
        }
        rows += [labelsRow(), gainsRow(profile.bands)]
        if let layer = profile.preference, !layer.isFlat { rows.append("  preference: " + preference(layer)) }
        if !profile.knobs.isEmpty { rows.append("  boost: " + knobs(profile)) }
        var lines = rows.joined(separator: "\n")
        if !profile.filters.isEmpty {
            lines += "\n" + filters(profile.filters, imported: profile.imported)
        }
        return lines
    }

    static func paintedHeader(_ header: String) -> String {
        let ownSuffix = " (own profile)"
        let defaultSuffix = " (default profile)"
        if header.hasSuffix(ownSuffix) {
            return Paint.ink(.bold, String(header.dropLast(ownSuffix.count))) + Paint.ink(.dim, ownSuffix)
        }
        if header.hasSuffix(defaultSuffix) {
            return Paint.ink(.bold, String(header.dropLast(defaultSuffix.count))) + Paint.ink(.yellow, defaultSuffix)
        }
        return Paint.ink(.bold, header)
    }

    static func presetLabel(_ preset: PresetMark) -> String {
        Paint.ink(.bold, preset.name) + (preset.modified ? Paint.ink(.yellow, "*") : "")
    }

    /// "Name (own profile · favourite*)", or "Name (favourite)" for a bare header.
    private static func paintedHeader(_ header: String, preset: PresetMark) -> String {
        for (suffix, ink) in [("own profile", Paint.Ink.dim), ("default profile", .yellow)] where header.hasSuffix(" (\(suffix))") {
            let base = String(header.dropLast(suffix.count + 3))
            return Paint.ink(.bold, base) + Paint.ink(ink, " (\(suffix) · ") + presetLabel(preset) + Paint.ink(ink, ")")
        }
        return Paint.ink(.bold, header) + Paint.ink(.dim, " (") + presetLabel(preset) + Paint.ink(.dim, ")")
    }

    /// "bass +3.0 dB  tilt -0.5 dB/oct", naming only the parts that are set.
    static func preference(_ layer: Preference) -> String {
        [("bass", layer.bass, "dB"), ("treble", layer.treble, "dB"), ("tilt", layer.tilt, "dB/oct")]
            .filter { $0.1 != 0 }
            .map { "\($0.0) " + Paint.ink(Paint.gain($0.1), gain($0.1)) + " \($0.2)" }
            .joined(separator: "  ")
    }

    /// "voice +3 kick -2", in the instrument table's order.
    static func knobs(_ profile: Profile) -> String {
        profile.knobs.map { "\($0.instrument.name) " + Paint.ink(Paint.gain($0.gain), String(format: "%+g", $0.gain)) }.joined(separator: " ")
    }

    static func compactGains(_ bands: [Double]) -> String {
        bands.map { Paint.ink(Paint.gain($0), gain($0)) }.joined(separator: " ")
    }

    static func filters(_ filters: [Filter], imported: String?) -> String {
        let label = filters.contains { $0.origin == .import }
            ? " (" + Paint.ink(.cyan, "imported: \(imported ?? "yes")") + ")" : ""
        var lines = [
            "  filters\(label):",
            "   #  type       Fc        gain           Q  source",
        ]
        for (index, filter) in filters.enumerated() {
            let type = Paint.ink(.cyan, filter.type.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))
            let fc = Paint.ink(.bold, String(format: "%6.0f Hz", filter.frequency))
            let gainCell = Paint.ink(Paint.gain(filter.gain), String(format: "%+5.1f dB", filter.gain))
            let q = Paint.ink(.dim, String(format: "%5.2f", filter.q))
            let source = filter.origin == .import ? Paint.ink(.cyan, "import") : Paint.ink(.green, "hand")
            lines.append(String(format: "  %2d  ", index + 1) + type + "  " + fc + "  " + gainCell + "  " + q + "  " + source)
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
