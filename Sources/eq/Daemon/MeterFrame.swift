import Foundation

/// A transient listen-alone window. Lives only in the daemon; never part of `Config`.
struct SoloRange: Codable, Equatable {
    var low: Double
    var high: Double
}

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
    var solo: SoloRange? = nil
    /// The app rule heard instead of the device's curve; `gains` and `preamp` are then its preset's.
    var app: AppMatch? = nil
    /// The compressor's gain change in dB, 0 or below; absent while it is off.
    var comp: Double? = nil

    // Written by hand only so an inactive solo goes out as an explicit `null`; the synthesized
    // encoder would omit the key.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encodeIfPresent(device, forKey: .device)
        try c.encode(rate, forKey: .rate)
        try c.encode(self.in, forKey: .in)
        try c.encode(out, forKey: .out)
        try c.encode(peak, forKey: .peak)
        try c.encode(limiting, forKey: .limiting)
        try c.encode(gains, forKey: .gains)
        try c.encode(preamp, forKey: .preamp)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(solo, forKey: .solo)
        try c.encodeIfPresent(app, forKey: .app)
        try c.encodeIfPresent(comp, forKey: .comp)
    }

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
