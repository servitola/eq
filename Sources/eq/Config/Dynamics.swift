import Foundation

/// Light compression and colour, after the EQ and before the limiter. Either part may be off;
/// a profile stores nil when both are.
struct Dynamics: Codable, Equatable {
    enum Compressor: String, Codable, CaseIterable {
        case gentle, night
    }

    enum ColourKind: String, Codable, CaseIterable {
        case tape, tube
    }

    struct Colour: Codable, Equatable {
        var kind: ColourKind
        var amount: Double
    }

    /// A colour whose kind this build does not know, kept as written.
    struct UnknownColour: Codable, Equatable {
        var kind: String
        var amount: Double
    }

    /// Setting either one replaces whatever unknown value stood in its place.
    var comp: Compressor? { didSet { unknownComp = nil } }
    var color: Colour? { didSet { unknownColor = nil } }
    /// A mode or kind from a newer eq or a hand edit: it runs nothing, but a save writes it back
    /// rather than rejecting the whole file over it or dropping it.
    private(set) var unknownComp: String?
    private(set) var unknownColor: UnknownColour?

    static let amountRange: ClosedRange<Double> = 0...1

    init(comp: Compressor? = nil, color: Colour? = nil) {
        self.comp = comp
        self.color = color
    }

    private enum CodingKeys: String, CodingKey { case comp, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try c.decodeIfPresent(String.self, forKey: .comp) {
            comp = Compressor(rawValue: raw)
            if comp == nil { unknownComp = raw }
        }
        if let raw = try c.decodeIfPresent(UnknownColour.self, forKey: .color), raw.amount != 0 {
            color = ColourKind(rawValue: raw.kind).map { Colour(kind: $0, amount: raw.amount) }
            if color == nil { unknownColor = raw }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(comp?.rawValue ?? unknownComp, forKey: .comp)
        try c.encodeIfPresent(color.map { UnknownColour(kind: $0.kind.rawValue, amount: $0.amount) } ?? unknownColor, forKey: .color)
    }

    var isOff: Bool { comp == nil && color == nil && unknownComp == nil && unknownColor == nil }

    /// What the file names that this build cannot run, for the daemon's log and `eq doctor`.
    var unknown: [String] {
        [unknownComp.map { "comp mode \"\($0)\"" }, unknownColor.map { "color \"\($0.kind)\"" }].compactMap { $0 }
    }
}
