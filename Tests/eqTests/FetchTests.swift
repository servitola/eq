import XCTest
@testable import eq

final class FetchTests: XCTestCase {
    private let url = URL(string: "https://example.com/INDEX.md")!

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    func testOKReturnsData() throws {
        XCTAssertEqual(try HTTPFetch.checkedData(Data("ok".utf8), response(200), nil), Data("ok".utf8))
    }

    func testNotFoundBecomesFileDoesNotExist() {
        XCTAssertThrowsError(try HTTPFetch.checkedData(Data("404: Not Found".utf8), response(404), nil)) {
            XCTAssertEqual(($0 as? URLError)?.code, .fileDoesNotExist)
        }
    }

    func testServerErrorBecomesBadServerResponse() {
        XCTAssertThrowsError(try HTTPFetch.checkedData(Data("oops".utf8), response(500), nil)) {
            XCTAssertEqual(($0 as? URLError)?.code, .badServerResponse)
        }
    }
}
