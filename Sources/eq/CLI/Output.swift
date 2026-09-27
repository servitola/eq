import Foundation

struct AnyEncodable: Encodable {
    private let encodeInto: (Encoder) throws -> Void
    init(_ value: Encodable) { encodeInto = { try value.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encodeInto(encoder) }
}

struct Output {
    var text: String
    var json: AnyEncodable
    var exitCode: Int32 = 0
    // stream prints each line itself as it arrives; this marks the final empty Output so
    // run()/main.swift don't also print a trailing blank line or JSON blob after it.
    var streamed = false
    init(_ text: String, _ json: Encodable) { self.text = text; self.json = AnyEncodable(json) }
}

struct DeviceRef: Encodable { var uid: String; var name: String }
struct ProfileReport: Encodable { var device: DeviceRef; var source: String; var profile: Profile }
struct DeviceRow: Encodable {
    var uid: String; var name: String; var transport: String?; var connected: Bool; var profile: String
    enum CodingKeys: String, CodingKey { case uid, name, transport, connected, profile }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(name, forKey: .name)
        try container.encode(transport, forKey: .transport)
        try container.encode(connected, forKey: .connected)
        try container.encode(profile, forKey: .profile)
    }
}
struct DevicesReport: Encodable {
    var current: String?; var devices: [DeviceRow]
    enum CodingKeys: String, CodingKey { case current, devices }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(current, forKey: .current)
        try container.encode(devices, forKey: .devices)
    }
}
struct ImportReport: Encodable {
    struct Details: Encodable { var format: String; var origin: String; var warnings: [String] }
    var device: DeviceRef
    var source: String
    var profile: Profile
    var `import`: Details
}
struct ToggleReport: Encodable { var enabled: Bool }
struct InitReport: Encodable { var path: String; var created: Bool }
struct UsageReport: Encodable { var usage: String }
struct ErrorReport: Encodable {
    struct Body: Encodable { var code: String; var message: String }
    var error: Body
}

extension CLIError {
    var code: String {
        switch self {
        case .usage: return "usage"
        case .unknownBand: return "unknownBand"
        case .badGain: return "badGain"
        case .gainOutOfRange: return "gainOutOfRange"
        case .noSuchDevice: return "noSuchDevice"
        case .ambiguousDevice: return "ambiguousDevice"
        case .noCurrentDevice: return "noCurrentDevice"
        case .daemonNotRunning: return "daemonNotRunning"
        case .noMeter: return "noMeter"
        case .importUnrecognized: return "importUnrecognized"
        case .importNotFound: return "importNotFound"
        case .importAmbiguous: return "importAmbiguous"
        case .network: return "network"
        }
    }
}
