import Darwin
import EQTerm
import XCTest
@testable import eq

/// 300 meter frames at 120×40 through update, view and the renderer, for each look at each
/// colour depth: the bytes a terminal gets and the CPU it takes. Printed for the record; asserted
/// against the byte budget only, since CPU time in a debug build under a busy test run says little.
final class MeterBenchmarkTests: XCTestCase {
    enum Motion: String, CaseIterable {
        /// research 09 §4: a random walk around a mix, a kick on the low bands, a 20 dB/s fall.
        case music
        /// Every band jumps to a random level every frame.
        case stress
    }

    /// A fixed-seed generator, so every run measures the same frames.
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }

        mutating func gauss() -> Double {
            let u = max(next(), 1e-12), v = next()
            return (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
        }
    }

    /// `spectrum`: the third octaves too, moving the same way around the bands' levels 4 dB down, as
    /// the daemon sends them rounded to 0.1 dB.
    static func frames(_ count: Int, motion: Motion = .music, spectrum: Bool = true) -> [MeterFrame] {
        var random = Random(state: 7)
        let base: [Double] = [-10, -8, -12, -16, -20, -18, -23, -27, -30, -38]
        let thirds = (0..<31).map { j -> Double in
            let x = min(max(Double(j - 2) / 3, 0), 9), k = min(Int(x), 8)
            return base[k] + (base[k + 1] - base[k]) * (x - Double(k)) - 4
        }
        var shown = base, shownThirds = thirds
        func step(_ level: inout Double, base: Double, low: Bool, n: Int) {
            switch motion {
            case .stress:
                level = -60 + 59 * random.next()
            case .music:
                let beat = low ? 6 * pow(max(0, sin(Double(n) / 30 * 2 * Double.pi * 2)), 4) : 0
                let target = base + beat + random.gauss() * 3
                level = target > level ? target : max(target, level - 20.0 / 30 * 3)
            }
        }
        return (0..<count).map { n in
            for i in 0..<10 { step(&shown[i], base: base[i], low: i < 3, n: n) }
            let out = shown.map { min(max($0, -60), 0) }
            var frame = MeterFrame(t: Double(n) / 30, device: "BE-RCA", rate: 44100, in: out.map { min($0 + 1.5, -0.5) }, out: out,
                                   peak: (out.max()! * 10).rounded() / 10, limiting: false, gains: Config.screenshotCurve, preamp: -4.8,
                                   enabled: true, comp: -2.1)
            if spectrum {
                for j in 0..<31 { step(&shownThirds[j], base: thirds[j], low: j < 9, n: n) }
                frame.spectrum = shownThirds.map { (min(max($0, -60), 0) * 10).rounded() / 10 }
            }
            return frame
        }
    }

    private static func cpu() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    /// Bytes a frame after the first, bytes of the first (a whole screen), and CPU a frame.
    static func measure(look: Look, depth: ColorDepth, motion: Motion, frames count: Int = 300,
                        view: TUIView = .meter, spectrum: Bool = true, size: Size = Size(cols: 120, rows: 40)) -> (perFrame: Double, full: Int, ms: Double) {
        var settings = LookSettings()
        settings.look = look
        settings.depth = depth
        let header = Watch.Header(preset: ("favourite", true), preference: Preference(bass: 1, treble: -0.5), knobs: ["voice": 3],
                                  dynamics: Dynamics(comp: .night, color: .init(kind: .tape, amount: 0.3)))
        var model = MeterModel(size: size, header: header, look: settings, view: view)
        if Self.lists.contains(view) {
            load(&model)
            var listed = header
            listed.profile = TUILookTests.playing
            _ = model.update(.header(listed))
        }
        var renderer = Renderer()
        var screen = Screen(size)
        var bytes = 0
        var full = 0
        let frames = Self.frames(count + 1, motion: motion, spectrum: spectrum)
        let start = cpu()
        for (n, f) in frames.enumerated() {
            _ = model.update(.frame(f))
            screen.clear()
            model.view(into: &screen)
            let written = renderer.render(screen).count
            if n == 0 { full = written } else { bytes += written }
        }
        return (Double(bytes) / Double(count), full, (cpu() - start) / Double(count + 1) * 1000)
    }

    static let lists: [TUIView] = [.presets, .devices, .filters, .apps, .system, .history]

    /// What the list views read, as the goldens have it.
    private static func load(_ model: inout MeterModel) {
        let data = TUILookTests.pages(TUILookTests.scene(cols: 120, rows: 40)) { _ in }
        _ = model.update(.library(data.library))
        _ = model.update(.running(data.running))
        _ = model.update(.system(data.system))
        _ = model.update(.history(data.versions))
        model.doctor = data.doctor
    }

    /// A list view with nothing but keys: `j` and `k` in turn, each moving the selection and its preview.
    static func measureKeys(look: Look, depth: ColorDepth, view: TUIView, presses count: Int = 300) -> (perKey: Double, full: Int) {
        let size = Size(cols: 120, rows: 40)
        var settings = LookSettings()
        settings.look = look
        settings.depth = depth
        var model = MeterModel(size: size, look: settings, view: view)
        load(&model)
        _ = model.update(.header(Watch.Header(preset: ("favourite", true), profile: TUILookTests.playing)))
        var renderer = Renderer()
        var screen = Screen(size)
        model.view(into: &screen)
        let full = renderer.render(screen).count
        var bytes = 0
        for n in 0..<count {
            _ = model.update(.input(.key(KeyPress(.char(n % 2 == 0 ? "j" : "k")))))
            screen.clear()
            model.view(into: &screen)
            bytes += renderer.render(screen).count
        }
        return (Double(bytes) / Double(count), full)
    }

    func testEveryLookAndDepthStaysInTheByteBudget() {
        var table = ["| Look | Colours | Motion | Bytes a frame | Full frame | ms a frame |", "| --- | --- | --- | --- | --- | --- |"]
        for look in Look.allCases {
            for depth in ColorDepth.allCases {
                for motion in Motion.allCases {
                    let m = Self.measure(look: look, depth: depth, motion: motion)
                    table.append(String(format: "| %@ | %@ | %@ | %.0f | %d | %.2f |", look.rawValue, depth.rawValue, motion.rawValue,
                                        m.perFrame, m.full, m.ms))
                    XCTAssertLessThan(m.perFrame, 4500, "research 08 §8: at most 60 % of the 7.6 KB a frame took before M2; \(look) \(depth) \(motion)")
                }
            }
        }
        for motion in Motion.allCases {
            let m = Self.measure(look: .studio, depth: .truecolor, motion: motion, size: Size(cols: 140, rows: 40))
            table.append(String(format: "| studio, 140×40 (bars 3 columns apart) | 24bit | %@ | %.0f | %d | %.2f |", motion.rawValue,
                                m.perFrame, m.full, m.ms))
            XCTAssertLessThan(m.perFrame, 4500, "the wider spectrum; \(motion)")
        }
        for look in Look.allCases {
            for motion in Motion.allCases {
                let m = Self.measure(look: look, depth: .truecolor, motion: motion, spectrum: false)
                table.append(String(format: "| %@, ten bands (no spectrum) | 24bit | %@ | %.0f | %d | %.2f |", look.rawValue, motion.rawValue,
                                    m.perFrame, m.full, m.ms))
                XCTAssertLessThan(m.perFrame, 4500, "the fallback without a spectrum; \(look) \(motion)")
            }
        }
        for look in Look.allCases {
            for motion in Motion.allCases {
                let m = Self.measure(look: look, depth: .truecolor, motion: motion, view: .instruments)
                table.append(String(format: "| %@, instruments view | 24bit | %@ | %.0f | %d | %.2f |", look.rawValue, motion.rawValue,
                                    m.perFrame, m.full, m.ms))
                XCTAssertLessThan(m.perFrame, 4500, "the Instruments view's mini-meters too; \(look) \(motion)")
            }
        }
        for look in Look.allCases {
            for depth in ColorDepth.allCases {
                for motion in Motion.allCases {
                    let m = Self.measure(look: look, depth: depth, motion: motion, view: .tune)
                    table.append(String(format: "| %@, tune view | %@ | %@ | %.0f | %d | %.2f |", look.rawValue, depth.rawValue, motion.rawValue,
                                        m.perFrame, m.full, m.ms))
                    XCTAssertLessThan(m.perFrame, 4500, "the Tune view's mini-meters and output; \(look) \(depth) \(motion)")
                }
            }
        }
        for view in Self.lists {
            for look in Look.allCases {
                for depth in ColorDepth.allCases {
                    let m = Self.measure(look: look, depth: depth, motion: .stress, view: view)
                    let keys = Self.measureKeys(look: look, depth: depth, view: view)
                    table.append(String(format: "| %@, %@ view | %@ | stress | %.0f | %d | %.2f |", look.rawValue, view.rawValue, depth.rawValue,
                                        m.perFrame, m.full, m.ms))
                    table.append(String(format: "| %@, %@ view | %@ | j k | %.0f | %d | — |", look.rawValue, view.rawValue, depth.rawValue,
                                        keys.perKey, keys.full))
                    XCTAssertLessThan(m.perFrame, 4500, "\(view): only the status bar moves; \(look) \(depth)")
                    XCTAssertLessThan(keys.perKey, 4500, "\(view): a new selection and its preview; \(look) \(depth)")
                }
            }
        }
        print(table.joined(separator: "\n"))
    }
}
