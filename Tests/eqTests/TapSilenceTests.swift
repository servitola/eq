import XCTest
@testable import eq

final class TapSilenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testSignalKeepsItAtZero() {
        var silence = TapSilence()
        XCTAssertEqual(silence.observe(callbacks: 100, signalCallbacks: 100, now: t0), 0)
        XCTAssertEqual(silence.observe(callbacks: 200, signalCallbacks: 150, now: t0 + 5), 0)
    }

    func testCountsFromTheLastObservedSignalWhileCallbacksAdvance() {
        var silence = TapSilence()
        _ = silence.observe(callbacks: 100, signalCallbacks: 80, now: t0)
        XCTAssertEqual(silence.observe(callbacks: 300, signalCallbacks: 80, now: t0 + 5), 5)
        XCTAssertEqual(silence.observe(callbacks: 900, signalCallbacks: 80, now: t0 + 35), 35)
        XCTAssertEqual(silence.observe(callbacks: 950, signalCallbacks: 81, now: t0 + 40), 0)
    }

    func testStoppedEngineIsNotSilence() {
        var silence = TapSilence()
        XCTAssertNil(silence.observe(callbacks: 0, signalCallbacks: 0, now: t0))
        XCTAssertNil(silence.observe(callbacks: 0, signalCallbacks: 0, now: t0 + 60))
    }

    func testStalledCallbacksAreNotSilence() {
        var silence = TapSilence()
        _ = silence.observe(callbacks: 100, signalCallbacks: 80, now: t0)
        XCTAssertNil(silence.observe(callbacks: 100, signalCallbacks: 80, now: t0 + 60))
    }

    func testRestartResetsTheClock() {
        var silence = TapSilence()
        _ = silence.observe(callbacks: 500, signalCallbacks: 0, now: t0)
        XCTAssertEqual(silence.observe(callbacks: 900, signalCallbacks: 0, now: t0 + 50), 50)
        XCTAssertEqual(silence.observe(callbacks: 10, signalCallbacks: 0, now: t0 + 55), 0)
        XCTAssertEqual(silence.observe(callbacks: 400, signalCallbacks: 0, now: t0 + 60), 5)
    }

    // A restart's callback count can climb back past the old signal's high-water mark before
    // the next observe: comparing only against that mark (not the last raw reading) would miss it.
    func testRestartBelowThePreviousReadingResetsEvenAboveTheOldSignalMark() {
        var silence = TapSilence()
        _ = silence.observe(callbacks: 100, signalCallbacks: 80, now: t0)
        XCTAssertEqual(silence.observe(callbacks: 300, signalCallbacks: 80, now: t0 + 5), 5)
        XCTAssertEqual(silence.observe(callbacks: 150, signalCallbacks: 80, now: t0 + 6), 0,
                       "150 dropped from the last reading of 300 even though it is still above the old signal mark of 100")
    }

    func testResetStartsAFreshClockAcrossSleep() {
        var silence = TapSilence()
        _ = silence.observe(callbacks: 500, signalCallbacks: 3, now: t0)
        XCTAssertEqual(silence.observe(callbacks: 800, signalCallbacks: 3, now: t0 + 90), 90)
        silence.reset()
        XCTAssertEqual(silence.observe(callbacks: 0, signalCallbacks: 3, now: t0 + 200), nil)
        XCTAssertEqual(silence.observe(callbacks: 10, signalCallbacks: 3, now: t0 + 201), 1)
    }
}
