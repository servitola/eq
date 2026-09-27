import Foundation

enum Table {
    static func gain(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }

    static func profile(_ profile: Profile, header: String) -> String {
        let width = 6
        let labels = Config.bandLabels.map { $0.leftPadded(to: width) }.joined()
        let gains = profile.bands.map { gain($0).leftPadded(to: width) }.joined()
        var lines = """
        \(header)   preamp: \(gain(profile.preamp)) dB
        \(labels)
        \(gains)
        """
        if !profile.filters.isEmpty {
            lines += "\n" + filters(profile.filters, imported: profile.imported)
        }
        return lines
    }

    private static func filters(_ filters: [Filter], imported: String?) -> String {
        var lines = [
            "  filters (imported: \(imported ?? "yes")):",
            "   #  type       Fc        gain     Q",
        ]
        for (index, filter) in filters.enumerated() {
            let type = filter.type.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            let rest = String(format: "%6.0f Hz  %+5.1f dB  %.2f", filter.frequency, filter.gain, filter.q)
            lines.append(String(format: "  %2d  ", index + 1) + type + "  " + rest)
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
