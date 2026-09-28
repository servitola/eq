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

    var comp: Compressor?
    var color: Colour?

    static let amountRange: ClosedRange<Double> = 0...1

    init(comp: Compressor? = nil, color: Colour? = nil) {
        self.comp = comp
        self.color = color
    }

    private enum CodingKeys: String, CodingKey { case comp, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        comp = try c.decodeIfPresent(Compressor.self, forKey: .comp)
        color = try c.decodeIfPresent(Colour.self, forKey: .color).flatMap { $0.amount == 0 ? nil : $0 }
    }

    var isOff: Bool { comp == nil && color == nil }
}
