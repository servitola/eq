import Foundation

/// One EQ preset from OPRA (github.com/opra-project/OPRA), named like AutoEq names its entries
/// so both databases go through the same matcher.
struct OPRAEntry: Headphone {
    struct Band: Hashable {
        var type: String
        var frequency: Double
        var gainDb: Double?
        var q: Double?
        var slope: Double?
    }

    var id: String
    var name: String
    var author: String
    var details: String?
    var preamp: Double
    var bands: [Band]

    var source: String { "OPRA" }
    var credit: String { details.map { "\(author) (\($0))" } ?? author }
}

enum OPRA {
    /// Roon Labs' Cloudflare mirror of the repo's `dist/`; OPRA's CONSUMING.md asks
    /// non-commercial clients to read this rather than GitHub.
    static let databaseURL = URL(string: "https://opra.roonlabs.net/database_v1.jsonl")!
    static let repository = "https://github.com/opra-project/OPRA"
    static let license = "CC BY-SA 4.0"

    /// JSONSerialization rather than Decodable: a third of the time on the 12 MB file, which
    /// is parsed on every lookup that reaches OPRA.
    static func parse(_ data: Data) -> [OPRAEntry] {
        var vendors: [String: String] = [:]
        var products: [String: (vendor: String, name: String)] = [:]
        var presets: [(id: String, data: [String: Any])] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = object["type"] as? String, let id = object["id"] as? String,
                  let payload = object["data"] as? [String: Any] else { continue }
            switch type {
            case "vendor": vendors[id] = payload["name"] as? String
            case "product":
                if let name = payload["name"] as? String { products[id] = (payload["vendor_id"] as? String ?? "", name) }
            case "eq" where (payload["type"] as? String ?? "parametric_eq") == "parametric_eq": presets.append((id, payload))
            default: continue
            }
        }
        // OPRA files some measurements twice, as a tagged product and as a plain product with
        // the tag in the credit; after lifting the tag they are the same row.
        struct Seen: Hashable { var name: String; var author: String; var details: String?; var preamp: Double; var bands: [OPRAEntry.Band] }
        var seen = Set<Seen>()
        return presets.compactMap { preset -> OPRAEntry? in
            guard let productID = preset.data["product_id"] as? String, let product = products[productID],
                  let parameters = preset.data["parameters"] as? [String: Any],
                  let rawBands = parameters["bands"] as? [[String: Any]] else { return nil }
            let bands = rawBands.compactMap { band -> OPRAEntry.Band? in
                guard let type = band["type"] as? String, let frequency = band["frequency"] as? Double else { return nil }
                return OPRAEntry.Band(type: type, frequency: frequency, gainDb: band["gain_db"] as? Double,
                                      q: band["q"] as? Double, slope: band["slope"] as? Double)
            }
            guard !bands.isEmpty else { return nil }
            var name = fullName(vendor: vendors[product.vendor], product: product.name)
            var details = preset.data["details"] as? String
            // Some presets carry the device state in the credit — `Measured by crinacle (ANC
            // mode)` under a plain `AirPods Pro 2` — where the matcher would miss it.
            if let credit = details, let tag = HeadphoneName(credit).variant, HeadphoneName(name).variant == nil,
               credit.hasPrefix("Measured by ") {
                name += " (\(tag))"
                details = HeadphoneName(credit).model
            }
            let entry = OPRAEntry(
                id: preset.id,
                name: name,
                author: preset.data["author"] as? String ?? "unknown",
                details: details,
                preamp: parameters["gain_db"] as? Double ?? 0,
                bands: bands)
            let key = Seen(name: HeadphoneMatch.tokens(name).joined(separator: " "), author: entry.author, details: details,
                           preamp: entry.preamp, bands: bands)
            return seen.insert(key).inserted ? entry : nil
        }
    }

    /// OPRA keeps the brand apart (`Sony` + `WH-1000XM4`) but a few products repeat it
    /// (`Moondrop x Crinacle DUSK`), so the vendor is prefixed only when missing.
    static func fullName(vendor: String?, product: String) -> String {
        guard let vendor, !vendor.isEmpty else { return product }
        let vendorTokens = HeadphoneMatch.tokens(vendor)
        return HeadphoneMatch.tokens(product).starts(with: vendorTokens) ? product : "\(vendor) \(product)"
    }

    /// Hand-made presets first — the plain one before its `• graphic EQ` / `• octave band EQ`
    /// reductions — then AutoEq runs in the same reviewer order as the AutoEq index.
    static func rank(_ entry: OPRAEntry) -> Int {
        if entry.author.lowercased() == "oratory1990" { return entry.details?.contains("•") == true ? 1 : 0 }
        guard entry.author == "AutoEQ", let details = entry.details, details.hasPrefix("Measured by ") else {
            return AutoEqIndex.preferredSources.count + 3
        }
        let reviewer = String(details.dropFirst("Measured by ".count)).lowercased()
        return 2 + (AutoEqIndex.preferredSources.firstIndex { $0.lowercased() == reviewer } ?? AutoEqIndex.preferredSources.count)
    }

    static let slopeRange = 1...96

    /// Why a band from the remote database cannot become a filter, or `nil` if it can. Checked
    /// before any arithmetic: `Int(1e300)` traps, and the config would reject it anyway.
    static func invalidReason(_ band: OPRAEntry.Band) -> String? {
        func text(_ value: Double) -> String { String(format: "%g", value) }
        guard band.frequency.isFinite, Config.filterFrequencyRange.contains(band.frequency) else {
            return "frequency \(text(band.frequency)) Hz is outside 10–24000 Hz"
        }
        if let gain = band.gainDb, !(gain.isFinite && Config.filterGainRange.contains(gain)) {
            return "gain \(text(gain)) dB is outside ±30 dB"
        }
        if let q = band.q, !(q.isFinite && Config.filterQRange.contains(q)) {
            return "Q \(text(q)) is outside 0.1–30"
        }
        if ["low_pass", "high_pass"].contains(band.type), let slope = band.slope,
           !(slope.isFinite && slope.rounded() == slope && Double(slopeRange.lowerBound)...Double(slopeRange.upperBound) ~= slope) {
            return "slope \(text(slope)) dB/oct is not a whole number from \(slopeRange.lowerBound) to \(slopeRange.upperBound)"
        }
        return nil
    }

    static func result(_ entry: OPRAEntry) -> ImportResult {
        var warnings: [String] = []
        var filters: [Filter] = []
        for band in entry.bands {
            if let reason = invalidReason(band) {
                warnings.append("Skipped a \(band.type) band in OPRA preset \u{201C}\(entry.id)\u{201D}: \(reason).")
                continue
            }
            let q = band.q ?? 0.707
            let gain = band.gainDb ?? 0
            switch band.type {
            case "peak_dip": filters.append(Filter(type: .peak, frequency: band.frequency, gain: gain, q: q))
            case "low_shelf": filters.append(Filter(type: .lowShelf, frequency: band.frequency, gain: gain, q: q))
            case "high_shelf": filters.append(Filter(type: .highShelf, frequency: band.frequency, gain: gain, q: q))
            case "band_pass": filters.append(Filter(type: .bandPass, frequency: band.frequency, gain: 0, q: q))
            case "band_stop": filters.append(Filter(type: .notch, frequency: band.frequency, gain: 0, q: q))
            case "low_pass", "high_pass":
                let slope = band.slope ?? 12
                if slope != 12 {
                    warnings.append(String(format: "%@ at %g Hz has a %g dB/oct slope; applied as 12 dB/oct.", band.type, band.frequency, slope))
                }
                filters.append(Filter(type: band.type == "low_pass" ? .lowPass : .highPass, frequency: band.frequency, gain: 0, q: 0.707))
            default:
                warnings.append("Skipped unknown filter type \u{201C}\(band.type)\u{201D}.")
            }
        }
        // OPRA lists bands by priority and tells players with fewer slots to drop the tail.
        if filters.count > Config.maxFilters {
            warnings.append("OPRA preset has \(filters.count) filters; kept the first \(Config.maxFilters).")
            filters = Array(filters.prefix(Config.maxFilters))
        }
        return ImportResult(filters: filters, bands: nil, preamp: entry.preamp, format: "OPRA parametric", warnings: warnings)
    }

    static func attribution(_ entry: OPRAEntry) -> String {
        "preset by \(entry.credit) · via OPRA (\(repository)), \(license)"
    }
}

struct OPRACache {
    var directory: URL

    func load(fetch: (URL) throws -> Data, refresh: Bool, now: Date = Date()) throws -> [OPRAEntry] {
        try CachedDownload(file: directory.appendingPathComponent("database_v1.jsonl"), url: OPRA.databaseURL, maxAge: AutoEqIndex.cacheMaxAge)
            .load(fetch: fetch, refresh: refresh, now: now, parse: OPRA.parse)
    }
}

/// An entry from either database, so one match and one search span both.
enum CatalogueEntry: Headphone {
    case autoEq(AutoEqEntry)
    case opra(OPRAEntry)

    var name: String {
        switch self {
        case .autoEq(let entry): return entry.name
        case .opra(let entry): return entry.name
        }
    }

    var source: String {
        switch self {
        case .autoEq(let entry): return entry.source
        case .opra(let entry): return entry.source
        }
    }

    var database: String {
        switch self {
        case .autoEq: return "AutoEq"
        case .opra: return "OPRA"
        }
    }

    var credit: String? {
        if case .opra(let entry) = self { return entry.credit }
        return nil
    }

    /// AutoEq first: it is the source the user already knows from every earlier import.
    static func rank(_ entry: CatalogueEntry) -> Int {
        switch entry {
        case .autoEq(let e): return AutoEqIndex.rank(e)
        case .opra(let e): return AutoEqIndex.preferredSources.count + 1 + OPRA.rank(e)
        }
    }
}
