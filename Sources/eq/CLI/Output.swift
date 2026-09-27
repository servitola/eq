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
    init(_ text: String, _ json: Encodable) { self.text = text; self.json = AnyEncodable(json) }
}

struct DeviceRef: Encodable { var uid: String; var name: String }
struct ProfileReport: Encodable { var device: DeviceRef; var source: String; var profile: Profile }
struct DeviceRow: Encodable { var uid: String; var name: String; var transport: String?; var connected: Bool; var profile: String }
struct DevicesReport: Encodable { var current: String?; var devices: [DeviceRow] }
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
        }
    }
}
