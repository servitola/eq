import Foundation

/// The text entry point from before formats had a registry.
enum AutoEqParser {
    static func parse(_ text: String) throws -> ImportResult { try EQFormats.parse(Data(text.utf8)) }
}
