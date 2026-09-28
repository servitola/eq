import Foundation

enum ExportFormat: String, CaseIterable {
    case apo, graphiceq, eqmac, camilla, json
}

enum ExportError: Error, Equatable, CustomStringConvertible {
    case eqMacNeedsBandsOnly(filters: Int, preference: Bool)

    var description: String {
        switch self {
        case .eqMacNeedsBandsOnly(let filters, let preference):
            var extras: [String] = []
            if filters > 0 { extras.append("\(filters) parametric filter" + (filters == 1 ? "" : "s")) }
            if preference { extras.append("bass/treble/tilt") }
            return "eqMac's preset holds ten band gains and a preamp, nothing else; this curve also has "
                + extras.joined(separator: " and ") + " — export --format apo, or drop them first"
        }
    }
}

/// Writes a profile the way other tools read it. Every format is built from `Profile.engineBands`,
/// the same list the render thread runs, so what is exported is what is heard.
enum Exporter {
    struct Header {
        var device: String
        var date: String

        /// A device name is whatever Core Audio reports; a line break in it would end the comment.
        var comment: String {
            "# Exported by eq for \(device.components(separatedBy: .newlines).joined(separator: " ")), \(date)"
        }
    }

    static func render(_ profile: Profile, as format: ExportFormat, header: Header) throws -> String {
        switch format {
        case .apo: return apo(profile, header: header)
        case .graphiceq: return graphicEQ(profile)
        case .eqmac: return try eqMac(profile, name: profile.preset ?? header.device)
        case .camilla: return camilla(profile, header: header)
        case .json: return CLI.encode(profile)
        }
    }

    /// Shortest text that reads back as the same Double, so an exported file re-imports exactly;
    /// whole numbers lose the ".0" nobody writes by hand.
    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return "\(value)"
    }

    // MARK: - Equalizer APO

    /// `LSC`/`HSC … Q` and `LPQ`/`HPQ` because APO reads exactly those as a centre frequency with
    /// the given Q, which is how our RBJ biquads are defined; plain `LS`/`HS` would move the
    /// frequency to a corner and `LP`/`HP` would drop the Q.
    static func apoLine(_ band: EQBand) -> String {
        let fc = "Fc \(number(band.frequency)) Hz"
        let q = "Q \(number(band.q))"
        let gain = "Gain \(number(band.gain)) dB"
        switch band.type {
        case .peak: return "PK \(fc) \(gain) \(q)"
        case .lowShelf: return "LSC \(fc) \(gain) \(q)"
        case .highShelf: return "HSC \(fc) \(gain) \(q)"
        case .lowPass: return "LPQ \(fc) \(q)"
        case .highPass: return "HPQ \(fc) \(q)"
        case .bandPass: return "BP \(fc) \(q)"
        case .notch: return "NO \(fc) \(q)"
        }
    }

    static func apo(_ profile: Profile, header: Header) -> String {
        var lines = [header.comment, "Preamp: \(number(profile.preamp)) dB"]
        for (index, band) in profile.engineBands.enumerated() {
            lines.append("Filter \(index + 1): ON \(apoLine(band))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - GraphicEQ

    /// AutoEq's own grid (`f = 20·1.0563^n`, truncated, deduplicated, 20–19871 Hz); Wavelet
    /// refuses a GraphicEQ.txt on any other.
    static let graphicEQFrequencies: [Int] = {
        var grid: [Int] = []
        var f = 20.0
        while f < 20000 {
            if grid.last != Int(f) { grid.append(Int(f)) }
            f *= 1.0563
        }
        return grid
    }()

    /// The whole cascade in dB, preamp included, at the rate the stability check uses.
    static func response(_ profile: Profile, at frequency: Double, sampleRate: Double = Config.stabilityCheckRate) -> Double {
        profile.engineBands.reduce(profile.preamp) { total, band in
            total + BiquadCoefficients.make(type: band.type, frequency: band.frequency, gainDB: band.gain, q: band.q, sampleRate: sampleRate)
                .magnitudeDB(at: frequency, sampleRate: sampleRate)
        }
    }

    /// No `Preamp:` line: GraphicEQ.txt carries the preamp in the curve, as AutoEq writes it.
    static func graphicEQ(_ profile: Profile) -> String {
        let points = graphicEQFrequencies.map { f -> String in
            let gain = (response(profile, at: Double(f)) * 10).rounded() / 10
            return "\(f) \(String(format: "%.1f", gain == 0 ? 0 : gain))"
        }
        return "GraphicEQ: " + points.joined(separator: "; ")
    }

    // MARK: - eqMac

    /// The shape autoEqMac writes and eqMac imports; its ten bands sit at our ten centres.
    struct EqMacPreset: Codable, Equatable {
        struct Gains: Codable, Equatable { var global: Double; var bands: [Double] }
        var id: String
        var name: String
        var isDefault: Bool
        var gains: Gains
    }

    static func eqMac(_ profile: Profile, name: String) throws -> String {
        let hasPreference = !(profile.preference?.isFlat ?? true)
        guard profile.filters.isEmpty, !hasPreference else {
            throw ExportError.eqMacNeedsBandsOnly(filters: profile.filters.count, preference: hasPreference)
        }
        return CLI.encode(EqMacPreset(id: UUID().uuidString, name: name, isDefault: false,
                                      gains: .init(global: profile.preamp, bands: profile.bands)))
    }

    // MARK: - CamillaDSP

    static func camillaParameters(_ band: EQBand) -> [(String, String)] {
        let type: String
        switch band.type {
        case .peak: type = "Peaking"
        case .lowShelf: type = "Lowshelf"
        case .highShelf: type = "Highshelf"
        case .lowPass: type = "Lowpass"
        case .highPass: type = "Highpass"
        case .notch: type = "Notch"
        case .bandPass: type = "Bandpass"
        }
        let takesGain = [.peak, .lowShelf, .highShelf].contains(band.type)
        return [("type", type), ("freq", number(band.frequency))]
            + (takesGain ? [("gain", number(band.gain))] : [])
            + [("q", number(band.q))]
    }

    /// Names say what each filter is in `eq`'s own terms, so the pasted block reads back.
    static func camillaNames(_ profile: Profile) -> [String] {
        let graphic = min(Config.bandFrequencies.count, profile.bands.count)
        let layer = profile.preference?.engineBands.map(\.label) ?? []
        var tilt = 0
        return profile.engineBands.indices.map { index in
            if index < graphic { return "eq_band_\(Config.bandLabels[index].lowercased())" }
            if index < graphic + profile.filters.count { return "eq_filter_\(index - graphic + 1)" }
            let label = layer[index - graphic - profile.filters.count]
            guard label == "tilt" else { return "eq_" + label.replacingOccurrences(of: " ", with: "_") }
            tilt += 1
            return "eq_tilt_\(tilt)"
        }
    }

    static func camilla(_ profile: Profile, header: Header) -> String {
        var lines = [header.comment,
                     "# Merge filters: into your config's filters: and the step into its pipeline:.",
                     "# CamillaDSP 3 and later; for 2.x, split the step into one with channel: 0 and one with channel: 1.",
                     "filters:"]
        var names: [String] = []
        if profile.preamp != 0 {
            names.append("eq_preamp")
            lines += ["  eq_preamp:", "    type: Gain", "    parameters:", "      gain: \(number(profile.preamp))"]
        }
        for (name, band) in zip(camillaNames(profile), profile.engineBands) {
            names.append(name)
            lines += ["  \(name):", "    type: Biquad", "    parameters:"]
            lines += camillaParameters(band).map { "      \($0.0): \($0.1)" }
        }
        // CamillaDSP 3.0 replaced a step's `channel: n` with a `channels:` list; 4.x keeps the list.
        lines += ["pipeline:", "  - type: Filter", "    channels: [0, 1]", "    names:"]
        lines += names.map { "      - \($0)" }
        return lines.joined(separator: "\n")
    }
}
