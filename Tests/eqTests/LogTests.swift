import XCTest
@testable import eq

final class LogTests: XCTestCase {
    func testFormatPrefixesTimestamp() {
        let line = Log.format("hello", at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(line, "1970-01-01T00:00:00Z hello")
    }
}
