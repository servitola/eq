import Foundation

/// What any format hands `eq import`: filters for the parametric tier, or ten gains for the
/// graphic tier, plus the preamp the file asks for.
struct ImportResult: Equatable {
    var filters: [Filter]
    var bands: [Double]?
    var preamp: Double
    var format: String
    var warnings: [String]
}

enum ImportError: Error, Equatable, CustomStringConvertible {
    case empty
    case unrecognized
    /// The file looked like a known format but every filter in it was refused; the reasons say why.
    case nothingUsable([String])
    case preampOutOfRange(Double)

    var description: String {
        switch self {
        case .empty: return "No EQ filters found in the input."
        case .unrecognized:
            return "Unrecognized EQ format. Supported: \(EQFormats.all.map { $0.name }.joined(separator: ", "))."
        case .nothingUsable(let reasons): return "no usable EQ filter: " + reasons.joined(separator: "; ")
        case .preampOutOfRange(let value):
            return String(format: "preamp %g dB is outside %g…%g dB", value, Config.preampRange.lowerBound, Config.preampRange.upperBound)
        }
    }
}

struct ImportContext {
    /// The file being imported; `Include:` resolves against it. nil for a URL or a headphone
    /// name, where a relative path would point into whatever directory `eq` runs in.
    var file: URL?

    static let detached = ImportContext(file: nil)
}

protocol EQFormat {
    static var name: String { get }
    /// Cheap and content-based: no foreign format has a reserved extension, so `filename` is only a hint.
    static func sniff(_ data: Data, filename: String?) -> Bool
    static func parse(_ data: Data) throws -> ImportResult
    /// Formats that reference other files override this; the rest get `parse(_:)`.
    static func parse(_ data: Data, context: ImportContext) throws -> ImportResult
}

extension EQFormat {
    static func parse(_ data: Data, context: ImportContext) throws -> ImportResult { try parse(data) }
}

enum EQFormats {
    /// Tried in order; the first whose sniff accepts the data and whose parse succeeds wins.
    static let all: [any EQFormat.Type] = [APOFormat.self]

    static func parse(_ data: Data, filename: String? = nil, context: ImportContext = .detached) throws -> ImportResult {
        let text = ImportText.decode(data)
        if data.isEmpty || text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { throw ImportError.empty }
        var firstError: Error?
        for format in all where format.sniff(data, filename: filename) {
            do { return try format.parse(data, context: context) }
            catch { firstError = firstError ?? error }
        }
        throw firstError ?? ImportError.unrecognized
    }
}

enum ImportText {
    /// Windows tools save APO configs as UTF-16 with a BOM or in a legacy code page; every
    /// grammar here is ASCII, so Latin-1 reads the latter well enough.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1)
    }
}
