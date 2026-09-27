import Foundation

enum Table {
    static func gain(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }

    static let width = 6

    static let shortLabels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    static func labelsRow(width: Int = width, short: Bool = false, columns: Int = Config.bandLabels.count) -> String {
        let labels = (short ? shortLabels : Config.bandLabels).prefix(max(columns, 0))
        return Paint.ink(.dim, labels.map { $0.leftPadded(to: width) }.joined())
    }

    /// Below six columns "+12.0" plus a gap no longer fits, so the cell shows whole decibels.
    static func gainsRow(_ bands: [Double], width: Int = width) -> String {
        bands.map { value -> String in
            let text = width >= self.width ? gain(value) : wholeGain(value)
            return Paint.ink(Paint.gain(value), text.leftPadded(to: width))
        }.joined()
    }

    private static func wholeGain(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let whole = Int(min(max(value, -99), 99).rounded())
        return whole > 0 ? "+\(whole)" : "\(whole)"
    }

    static func profile(_ profile: Profile, header: String) -> String {
        let preamp = Paint.ink(Paint.gain(profile.preamp), gain(profile.preamp))
        var rows = ["\(paintedHeader(header))   preamp: \(preamp) dB"]
        // Piped output keeps the v1 three-line shape that scripts already parse.
        if Paint.enabled {
            rows.append(profile.bands.map { Paint.ink(Paint.gain($0), Paint.glyph(for: $0).leftPadded(to: width)) }.joined())
        }
        rows += [labelsRow(), gainsRow(profile.bands)]
        var lines = rows.joined(separator: "\n")
        if !profile.filters.isEmpty {
            lines += "\n" + filters(profile.filters, imported: profile.imported)
        }
        return lines
    }

    private static func paintedHeader(_ header: String) -> String {
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

    private static func filters(_ filters: [Filter], imported: String?) -> String {
        var lines = [
            "  filters (\(Paint.ink(.cyan, "imported: \(imported ?? "yes")"))):",
            "   #  type       Fc        gain     Q",
        ]
        for (index, filter) in filters.enumerated() {
            let type = Paint.ink(.cyan, filter.type.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))
            let fc = Paint.ink(.bold, String(format: "%6.0f Hz", filter.frequency))
            let gainCell = Paint.ink(Paint.gain(filter.gain), String(format: "%+5.1f dB", filter.gain))
            let q = Paint.ink(.dim, String(format: "%.2f", filter.q))
            lines.append(String(format: "  %2d  ", index + 1) + type + "  " + fc + "  " + gainCell + "  " + q)
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
