import XCTest
@testable import eq

final class MeterFrameTests: XCTestCase {
    static let sample = MeterFrame(
        t: 1790500000.125, device: "BE-RCA", rate: 44100,
        in: Array(repeating: -32.1, count: 10), out: Array(repeating: -28, count: 10),
        peak: -6.2, limiting: false, gains: Array(repeating: 4.8, count: 10), preamp: -1.5, enabled: true)

    func testRoundTrip() throws {
        let line = try MeterFrame.encodeLine(Self.sample)
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        let decoded = try JSONDecoder().decode(MeterFrame.self, from: line.dropLast())
        XCTAssertEqual(decoded, Self.sample)
    }

    func testLineIsCompactWithSpecKeys() throws {
        let text = String(decoding: try MeterFrame.encodeLine(Self.sample), as: UTF8.self)
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
        XCTAssertFalse(text.contains(": "))
        for key in ["t", "device", "rate", "in", "out", "peak", "limiting", "gains", "preamp", "enabled"] {
            XCTAssertTrue(text.contains("\"\(key)\":"), key)
        }
    }
}
