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
struct ProfileReport: Encodable { var device: DeviceRef; var source: String; var profile: Profile; var preset: String? = nil; var app: AppMatch? = nil }
struct PresetEntry: Encodable { var name: String; var profile: Profile }
struct PresetsReport: Encodable {
    var current: String?; var presets: [PresetEntry]
    enum CodingKeys: String, CodingKey { case current, presets }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(current, forKey: .current)
        try container.encode(presets, forKey: .presets)
    }
}
struct PresetShowReport: Encodable { var preset: String; var profile: Profile }
struct PresetRemovedReport: Encodable { var removed: String }
struct PresetRenamedReport: Encodable { var from: String; var to: String }
struct HistoryRow: Encodable { var index: Int; var path: String; var date: Date; var enabled: Bool?; var profile: Profile?; var current: Bool }
struct HistoryReport: Encodable { var position: Int; var entries: [HistoryRow]; var warning: String? }
struct HistoryStepReport: Encodable {
    var position: Int; var date: Date; var device: DeviceRef?; var source: String?; var profile: Profile?; var warning: String?
}
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
    struct Details: Encodable { var format: String; var origin: String; var warnings: [String]; var attribution: String? }
    var device: DeviceRef
    var source: String
    var profile: Profile
    var `import`: Details
}
struct FilterRow: Encodable { var number: Int; var type: FilterType; var frequency: Double; var gain: Double; var q: Double; var origin: FilterOrigin }
struct FiltersReport: Encodable { var device: DeviceRef; var source: String; var imported: String?; var filters: [FilterRow] }
struct BoostRow: Encodable { var instrument: String; var range: HzRange; var gain: Double }
struct BoostReport: Encodable { var device: DeviceRef; var source: String; var knobs: [BoostRow] }
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
        case .daemonClosedMeter: return "daemonClosedMeter"
        case .noEvents: return "noEvents"
        case .daemonClosedEvents: return "daemonClosedEvents"
        case .importUnrecognized: return "importUnrecognized"
        case .importNotFound: return "importNotFound"
        case .importAmbiguous: return "importAmbiguous"
        case .importSuggest: return "importNotFound"
        case .importVariant: return "importVariant"
        case .importRefused: return "importRefused"
        case .network: return "network"
        case .noSuchPreset: return "noSuchPreset"
        case .noSuchApp: return "noSuchApp"
        case .noSuchAppRule: return "noSuchAppRule"
        case .badPresetName: return "badPresetName"
        case .presetExists: return "presetExists"
        case .noBackup: return "noBackup"
        case .noRedo: return "noRedo"
        case .unreadableBackup: return "unreadableBackup"
        case .noSuchFilter: return "noSuchFilter"
        case .exportRefused: return "exportRefused"
        case .exportFailed: return "exportFailed"
        case .notConnected: return "notConnected"
        case .switchFailed: return "switchFailed"
        case .agent: return "agent"
        case .legacyAgent: return "legacyAgent"
        }
    }
}
