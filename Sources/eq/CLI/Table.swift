import Foundation

enum Table {
    static func gain(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }

    static func profile(_ profile: Profile, header: String) -> String {
        let width = 6
        let labels = Config.bandLabels.map { $0.leftPadded(to: width) }.joined()
        let gains = profile.bands.map { gain($0).leftPadded(to: width) }.joined()
        return """
        \(header)   preamp: \(gain(profile.preamp)) dB
        \(labels)
        \(gains)
        """
    }
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
