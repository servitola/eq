import Darwin
import EQTerm
import XCTest
@testable import eq

/// 300 meter frames with moving levels at 120×40 through update, view and the renderer: the
/// bytes a terminal gets and the CPU it takes, beside the line-per-frame writes the watch made
/// before the renderer. Printed for the record; asserted only against the byte budget, since CPU
/// time in a debug build under a busy test run says little.
final class MeterBenchmarkTests: XCTestCase {
    override func setUp() { Paint.forced = true }
    override func tearDown() { Paint.forced = nil }

    static func frames(_ count: Int) -> [MeterFrame] {
        (0..<count).map { n in
            let t = Double(n) / 30
            let out = (0..<10).map { i -> Double in
                let speed: Double = 0.3 + 0.17 * Double(i)
                return -30.5 + 29.5 * sin(t * 2 * Double.pi * speed + Double(i))
            }
            return MeterFrame(t: t, device: "BE-RCA", rate: 44100, in: out.map { min($0 + 2, 0) }, out: out, peak: -6,
                              limiting: false, gains: [3, 2, 0, -1, -2, 0, 1, 2, 3, 1], preamp: -1.5, enabled: true)
        }
    }

    private static func cpu() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    func testThreeHundredFramesStayInTheByteBudget() {
        let size = Size(cols: 120, rows: 40)
        let frames = Self.frames(300)

        var model = MeterModel(size: size)
        var renderer = Renderer()
        var screen = Screen(size)
        var bytes = 0
        let start = Self.cpu()
        for f in frames {
            _ = model.update(.frame(f))
            screen.clear()
            model.view(into: &screen)
            bytes += renderer.render(screen).count
        }
        let spent = Self.cpu() - start

        var old = MeterModel(size: size)
        var oldBytes = 0
        let oldStart = Self.cpu()
        for f in frames {
            _ = old.update(.frame(f))
            let lines = old.lines() ?? []
            oldBytes += Array(("\u{1B}[H" + lines.map { $0 + "\u{1B}[K" }.joined(separator: "\n") + "\u{1B}[J").utf8).count
        }
        let oldSpent = Self.cpu() - oldStart

        print(String(format: "renderer: %.0f bytes/frame, %.2f ms/frame; whole lines: %.0f bytes/frame, %.2f ms/frame",
                     Double(bytes) / 300, spent / 300 * 1000, Double(oldBytes) / 300, oldSpent / 300 * 1000))
        XCTAssertLessThan(Double(bytes) / 300, 4500, "research §8: at most 60 % of the 7.6 KB a frame took before")
    }
}
