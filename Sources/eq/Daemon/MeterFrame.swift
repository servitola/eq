import Foundation

struct MeterFrame: Codable, Equatable {
    var t: Double
    var device: String?
    var rate: Double
    var `in`: [Double]
    var out: [Double]
    var peak: Double
    var limiting: Bool
    var gains: [Double]
    var preamp: Double
    var enabled: Bool

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func encodeLine(_ frame: MeterFrame) throws -> Data {
        var data = try encoder.encode(frame)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
