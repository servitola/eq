import Foundation

protocol Headphone: Equatable {
    var name: String { get }
    var source: String { get }
}

/// A headphone name split into the model and its trailing device-state tag, the way AutoEq
/// writes them: `Sony WH-1000XM4 (ANC on)`, `Moondrop Aria (sample 2)`.
struct HeadphoneName: Equatable {
    var model: String
    var variant: String?

    init(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") {
            let tag = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            let model = trimmed[..<open].trimmingCharacters(in: .whitespaces)
            if !tag.isEmpty, !model.isEmpty {
                self.model = model
                self.variant = tag
                return
            }
        }
        model = trimmed
        variant = nil
    }

    var variantKey: String? { variant.map(HeadphoneMatch.variantKey) }
}

enum HeadphoneMatch {
    enum Match<E: Headphone>: Equatable {
        case one(E)
        case none
        case didYouMean([String])
        case ambiguous([String])
        case variants(model: String, [String])
    }

    /// Spellings no normalisation can reach; `wh1000xm4` or `airpods pro2` need no entry here,
    /// they already compare equal once separators are dropped.
    static let aliases: [String: String] = [
        "xm3": "wh-1000xm3", "xm4": "wh-1000xm4", "xm5": "wh-1000xm5",
        "app2": "airpods pro 2", "airpods pro 2nd gen": "airpods pro 2", "airpods pro 2nd generation": "airpods pro 2",
        "apm": "airpods max",
    ]

    /// AutoEq and OPRA name the noise-cancelling state several ways; all of them are what a
    /// person means by "ANC on".
    private static let variantSynonyms = ["anc": "anc-on", "anc-mode": "anc-on", "anc-on-mode": "anc-on"]

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static func variantKey(_ text: String) -> String {
        let key = tokens(text).joined(separator: "-")
        return variantSynonyms[key] ?? key
    }

    struct Hit<E: Headphone> {
        var entry: E
        var name: HeadphoneName
        var modelKey: String
        /// The leading model tokens dropped to reach an exact match — the vendor, as in `apple` for
        /// `airpods pro 2`; nil when the match is only partial.
        var vendor: String?
    }

    enum Tier<E: Headphone> {
        case exact([Hit<E>]), partial([Hit<E>]), fuzzy([String]), nothing
    }

    static func tier<E: Headphone>(_ query: String, in entries: [E]) -> Tier<E> {
        let queryName = HeadphoneName(query)
        let queryTokens = aliased(tokens(queryName.model))
        let compactQuery = queryTokens.joined()
        guard !compactQuery.isEmpty else { return .nothing }

        var exact: [Hit<E>] = []
        var partial: [Hit<E>] = []
        var near: [(distance: Int, model: String)] = []
        let tolerance = compactQuery.count >= 5 ? 2 : (compactQuery.count >= 3 ? 1 : 0)
        for entry in entries {
            let name = HeadphoneName(entry.name)
            let modelTokens = tokens(name.model)
            let compact = modelTokens.joined()
            let withoutVendor = modelTokens.dropFirst().joined()
            if let cut = modelTokens.indices.first(where: { modelTokens[$0...].joined() == compactQuery }) {
                exact.append(Hit(entry: entry, name: name, modelKey: compact, vendor: modelTokens[..<cut].joined(separator: " ")))
            } else if compact.contains(compactQuery)
                        || queryTokens.allSatisfy({ q in modelTokens.contains { $0.hasPrefix(q) } }) {
                partial.append(Hit(entry: entry, name: name, modelKey: compact, vendor: nil))
            } else if tolerance > 0 {
                let distance = min(levenshtein(compact, compactQuery), withoutVendor.isEmpty ? .max : levenshtein(withoutVendor, compactQuery))
                if distance <= tolerance { near.append((distance, name.model)) }
            }
        }
        if !exact.isEmpty { return .exact(exact) }
        if !partial.isEmpty { return .partial(partial) }
        guard !near.isEmpty else { return .nothing }
        let closest = near.map(\.distance).min()!
        var seen = Set<String>()
        let suggestions = near.filter { $0.distance == closest }
            .map(\.model)
            .sorted()
            .filter { seen.insert(tokens($0).joined()).inserted }
        return .fuzzy(Array(suggestions.prefix(5)))
    }

    static func match<E: Headphone>(
        _ query: String, in entries: [E], source: String?, variant: String?, rank: (E) -> Int
    ) -> Match<E> {
        let hits: [Hit<E>]
        switch tier(query, in: entries) {
        case .nothing: return .none
        case .fuzzy(let suggestions): return .didYouMean(suggestions)
        case .exact(let found):
            // `Sony WH-1000XM4` and `WH-1000XM4` are one model; `Moondrop Aria` and `Kiwi Ears Aria`
            // are two, so only a single distinct dropped vendor merges.
            let vendors = Set(found.compactMap(\.vendor).filter { !$0.isEmpty })
            if vendors.count > 1 { return .ambiguous(modelNames(found)) }
            hits = found
        case .partial(let found):
            if Set(found.map(\.modelKey)).count > 1 { return .ambiguous(modelNames(found)) }
            hits = found
        }

        var candidates = hits
        if let source {
            candidates = candidates.filter { $0.entry.source.lowercased() == source.lowercased() }
            guard !candidates.isEmpty else { return .none }
        }

        let model = candidates[0].name.model
        let wanted = variant ?? HeadphoneName(query).variant
        if let wanted {
            let key = variantKey(wanted)
            var chosen = candidates.filter { $0.name.variantKey == key }
            if chosen.isEmpty { chosen = candidates.filter { $0.name.variantKey?.hasPrefix(key) == true } }
            if Set(chosen.compactMap(\.name.variantKey)).count > 1 || chosen.isEmpty {
                return .variants(model: model, variantKeys(chosen.isEmpty ? candidates : chosen))
            }
            candidates = chosen
        } else {
            let plain = candidates.filter { $0.name.variant == nil }
            let ancOn = candidates.filter { $0.name.variantKey == "anc-on" }
            if !plain.isEmpty {
                candidates = plain
            } else if !ancOn.isEmpty {
                candidates = ancOn
            } else if Set(candidates.compactMap(\.name.variantKey)).count > 1 {
                return .variants(model: model, variantKeys(candidates))
            }
        }

        let ranked = candidates.map(\.entry).sorted {
            let r0 = rank($0), r1 = rank($1)
            if r0 != r1 { return r0 < r1 }
            return $0.source < $1.source
        }
        return .one(ranked[0])
    }

    /// Every entry a query reaches, each model's plain entry before its variants, without choosing.
    static func search<E: Headphone>(_ query: String, in entries: [E], rank: (E) -> Int) -> (hits: [E], suggestions: [String]) {
        let hits: [Hit<E>]
        switch tier(query, in: entries) {
        case .nothing: return ([], [])
        case .fuzzy(let suggestions): return ([], suggestions)
        case .exact(let found), .partial(let found): hits = found
        }
        let ordered = hits.sorted {
            if $0.modelKey != $1.modelKey { return $0.modelKey < $1.modelKey }
            let v0 = $0.name.variantKey ?? "", v1 = $1.name.variantKey ?? ""
            if v0 != v1 { return v0 < v1 }
            let r0 = rank($0.entry), r1 = rank($1.entry)
            if r0 != r1 { return r0 < r1 }
            return $0.entry.source < $1.entry.source
        }
        return (ordered.map(\.entry), [])
    }

    private static func aliased(_ tokens: [String]) -> [String] {
        aliases[tokens.joined(separator: " ")].map(Self.tokens) ?? tokens
    }

    private static func modelNames<E>(_ hits: [Hit<E>]) -> [String] {
        var seen = Set<String>()
        return hits.sorted { $0.name.model < $1.name.model }
            .filter { seen.insert($0.modelKey).inserted }
            .map(\.name.model)
    }

    private static func variantKeys<E>(_ hits: [Hit<E>]) -> [String] {
        Array(Set(hits.compactMap(\.name.variantKey))).sorted()
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
