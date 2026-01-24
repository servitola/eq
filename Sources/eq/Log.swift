import Foundation

enum Log {
    private static let formatter = ISO8601DateFormatter()

    static func format(_ message: String, at date: Date = Date()) -> String {
        "\(formatter.string(from: date)) \(message)"
    }

    static func write(_ message: String) {
        FileHandle.standardError.write(Data((format(message) + "\n").utf8))
    }
}
