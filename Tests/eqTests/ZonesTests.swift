import EQTerm
import XCTest
@testable import eq

final class ZonesTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private let silent = Array(repeating: Watch.floorDB, count: 10)
    private let flat = Array(repeating: 0.0, count: 10)

    private func frame(out: [Double] = Array(repeating: -20, count: 10), gains: [Double] = Config.screenshotCurve) -> MeterFrame {
        MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: Array(repeating: -60, count: 10), out: out, peak: -6,
                   limiting: false, gains: gains, preamp: -1.5, enabled: true)
    }

    private func instrument(_ name: String) -> Instrument { Instruments.all.first { $0.name == name }! }

    /// Where the studio meter sits under the status bar and, from 14 rows, the tab row.
    private func geometry(_ cols: Int, _ rows: Int, zones: Int = 0) -> MeterGeometry {
        let tabs = rows >= TabRow.minRows ? 1 : 0
        return MeterGeometry.studio(Size(cols: cols, rows: rows - tabs), zones: zones, focus: false, tabs: tabs).lowered(by: tabs)
    }

    func testAxisPutsBandFrequenciesOnTheirBarCentresAndInterpolatesInOctaves() {
        let centres = geometry(100, 30).centres
        for (i, f) in Config.bandFrequencies.enumerated() {
            XCTAssertEqual(Strip.x(f, centres: centres), Double(centres[i]), accuracy: 1e-9, "\(f)")
            XCTAssertEqual(Strip.frequency(at: Double(centres[i]), centres: centres), f, accuracy: 1e-6)
        }
        let between = Strip.x((500.0 * 1000).squareRoot(), centres: centres)
        XCTAssertEqual(between, Double(centres[4] + centres[5]) / 2, accuracy: 1e-9)
        XCTAssertLessThan(Strip.x(20, centres: centres), Double(centres[0]), "below 32 Hz the axis carries on left")
        XCTAssertGreaterThan(Strip.x(20000, centres: centres), Double(centres[9]))
    }

    func testSegmentsStayInsideTheTableWithAGapBetweenRanges() {
        for cols in [20, 42, 60, 100, 200] {
            let g = geometry(cols, 30)
            for instrument in Instruments.all {
                let segments = Strip.segments(instrument, centres: g.centres, columns: g.table)
                for s in segments {
                    XCTAssertGreaterThanOrEqual(s.lo, g.table.lowerBound, "\(cols) \(instrument.name)")
                    XCTAssertLessThanOrEqual(s.hi, g.table.upperBound, "\(cols) \(instrument.name)")
                    XCTAssertLessThanOrEqual(s.lo, s.hi)
                }
                for (a, b) in zip(segments, segments.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(b.lo, a.hi + 2, "\(cols) \(instrument.name): \(a) \(b)")
                }
            }
        }
    }

    func testVoiceDrawsEveryRangeAtOneHundredColumns() {
        let g = geometry(100, 30)
        let voice = Strip.segments(instrument("voice"), centres: g.centres, columns: g.table)
        XCTAssertEqual(voice.map(\.name), ["fundamental", "F1", "F2", "presence", "sibilance"])
        XCTAssertEqual(voice.first?.lo, Int(Strip.x(85, centres: g.centres).rounded()))
        XCTAssertEqual(voice.last?.hi, Int(Strip.x(9000, centres: g.centres).rounded()))
    }

    func testKickRowShowsTwoSpansWithTheirNames() throws {
        let g = geometry(100, 30, zones: 8)
        let lines = MeterScreens.lines(frame(out: silent), cols: 100, rows: 30, strip: true)
        let row = lines[g.zoneY]
        XCTAssertTrue(row.hasPrefix(String(repeating: " ", count: g.nameX) + "kck "), row)
        XCTAssertEqual(Strip.segments(instrument("kick"), centres: g.centres, columns: g.table).count, 2)
        XCTAssertTrue(row.contains("━ thump ━"), row)
        XCTAssertFalse(row.contains("beater"), "a name wider than its span is left out: \(row)")
        XCTAssertEqual(lines[g.zoneY + 7].trimmingCharacters(in: .whitespaces).prefix(3), "air")
    }

    func testNarrowLayoutUsesShortNamesAndShiftsTheFrame() {
        let g = MeterGeometry.compact(Size(cols: 56, rows: 20), zones: 8, focus: false)
        XCTAssertFalse(g.fullNames)
        XCTAssertEqual(g.x0, 5)
        let lines = MeterScreens.lines(frame(), cols: 56, rows: 20, strip: true)
        let strip = Array(lines[g.zoneY..<(g.zoneY + g.zoneRows)])
        XCTAssertEqual(strip.map { $0.trimmingCharacters(in: .whitespaces).prefix(3) }.map(String.init),
                       Array(Instruments.all.map(\.short).prefix(g.zoneRows)))
        XCTAssertEqual(MeterGeometry.compact(Size(cols: 56, rows: 20), zones: 0, focus: false).x0, 3,
                       "without the strip the frame stays centred")
    }

    func testANarrowMeterHidesInstrumentsAboveItsLastBand() throws {
        var hidden = 0
        for cols in [24, 30, 36, 44] {
            let scene = MeterScreens.scene(frame(), cols: cols, rows: 30, strip: true)
            let g = StudioView(scene: scene, compact: true).geometry
            let shown = Zones.shown(scene, centres: g.centres, table: g.table)
            hidden += Instruments.all.count - shown.count
            XCTAssertEqual(g.zoneRows, shown.count, "\(cols): a row for each instrument drawn, no bare names")
            let lines = MeterScreens.lines(frame(), cols: cols, rows: 30, strip: true)
            for (k, instrument) in shown.enumerated() {
                let row = lines[g.zoneY + k]
                XCTAssertTrue(row.trimmingCharacters(in: .whitespaces).hasPrefix(instrument.short), "\(cols): \(row)")
                XCTAssertTrue(row.contains("━"), "\(cols): \(instrument.name) has a span: \(row)")
            }
            XCTAssertEqual(g.liveY, g.zoneY + shown.count, "\(cols)")
        }
        XCTAssertGreaterThan(hidden, 0, "some width drops a band and the instruments above it")
        let wide = MeterScreens.scene(frame(), cols: 100, rows: 30, strip: true)
        let g = StudioView(scene: wide, compact: true).geometry
        XCTAssertEqual(Zones.shown(wide, centres: g.centres, table: g.table).count, Instruments.all.count)
    }

    func testCompactStripSitsDirectlyAboveTheLiveRow() {
        let g = MeterGeometry.compact(Size(cols: 59, rows: 30), zones: 8, focus: false)
        let lines = MeterScreens.lines(frame(), cols: 59, rows: 30, strip: true)
        XCTAssertEqual(g.liveY, g.zoneY + 8)
        XCTAssertTrue(lines[g.zoneY].trimmingCharacters(in: .whitespaces).hasPrefix("kck"), lines[g.zoneY])
        XCTAssertTrue(lines[g.zoneY + 7].trimmingCharacters(in: .whitespaces).hasPrefix("air"), lines[g.zoneY + 7])
        XCTAssertEqual(lines[g.liveY].split(separator: " "), Array(repeating: "-20", count: 10))
    }

    func testLoudInstrumentsTakeTheirHueAndQuietOnesFade() {
        let g = geometry(100, 30, zones: 8)
        func stroke(_ out: [Double]) -> Style {
            let screen = MeterScreens.screen(MeterScreens.scene(frame(out: out), cols: 100, rows: 30, strip: true, depth: .truecolor))
            let row = g.zoneY + 5
            let x = (0..<100).first { screen[$0, row].text == "━" }!
            return screen[x, row].style
        }
        let theme = LookSettings().theme
        let voice = theme.hue(instrument("voice"))
        XCTAssertEqual(stroke(Array(repeating: -12, count: 10)).fg, .rgb(voice.r, voice.g, voice.b))
        XCTAssertNotEqual(stroke(silent).fg, .rgb(voice.r, voice.g, voice.b), "silence fades the row")
    }

    func testFitReservesStripAndBracketRows() {
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 30, zones: 8).meterRows, 16)
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 30, zones: 1, bracket: true).meterRows, 22)
        let short = WatchLayout.fit(cols: 100, rows: 14, zones: 8, bracket: true)
        XCTAssertEqual(short.meterRows, 4)
        XCTAssertEqual(short.bracketRows, 1)
        XCTAssertEqual(short.zoneRows, 3)
        let voice = Instruments.all.first { $0.name == "voice" }
        XCTAssertEqual(MeterScreens.lines(frame(), cols: 100, rows: 14, strip: true, focus: voice).count, 14)
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 10, zones: 8, bracket: true).bracketRows, 0)
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 8, zones: 8).zoneRows, 0)
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 30), WatchLayout.fit(cols: 100, rows: 30, zones: 0))
        XCTAssertEqual(geometry(100, 36, zones: 8).zoneRows, 8)
        XCTAssertEqual(geometry(100, 24, zones: 8).zoneRows, 2, "the boxed meter keeps its height before the strip")
        XCTAssertEqual(MeterGeometry.studio(Size(cols: 100, rows: 24), zones: 1, focus: true).zoneRows, 1)
    }

    func testRunTogglesTheStripOnZ() throws {
        let line = String(decoding: try MeterFrame.encodeLine(frame()).dropLast(), as: UTF8.self)
        var keys: [String?] = ["z", "z", nil]
        let frames = MeterHarness.run(lines: Array(repeating: line, count: 3), size: { (100, 30) },
                                      readKey: { keys.isEmpty ? nil : keys.removeFirst() }).drawn
        XCTAssertEqual(frames.map { $0.contains(" cym ") }, [false, true, false])

        let zoned = MeterHarness.run(lines: [line], size: { (100, 30) }, zones: true, readKey: { nil })
        XCTAssertTrue(zoned.drawn.contains { $0.contains(" vox ") })
    }

    func testInstrumentsAllRangesAreValidAndWithinAudibleSpectrum() {
        XCTAssertEqual(Instruments.all.count, 8)
        for instrument in Instruments.all {
            XCTAssertFalse(instrument.ranges.isEmpty, instrument.name)
            XCTAssertEqual(instrument.short.count, 3, instrument.name)
            for range in instrument.ranges {
                XCTAssertLessThan(range.low, range.high, "\(instrument.name) \(range.name)")
                XCTAssertGreaterThanOrEqual(range.low, 20, "\(instrument.name) \(range.name)")
                XCTAssertLessThanOrEqual(range.high, 20000, "\(instrument.name) \(range.name)")
            }
        }
    }

    /// 85 Hz (voice's fundamental low edge) falls inside band 64's octave window [45.25, 90.51],
    /// so the touched set starts at 64 Hz, not 125 Hz as a naive read of the low edge suggests.
    func testVoiceTouchesBandsFromSixtyFourToEightThousand() {
        let voice = try! XCTUnwrap(Instruments.all.first { $0.name == "voice" })
        XCTAssertEqual(voice.bands.map { Config.bandFrequencies[$0] }, [64, 125, 250, 500, 1000, 2000, 4000, 8000])
    }

    func testKickHasTwoDisjointRanges() {
        let kick = try! XCTUnwrap(Instruments.all.first { $0.name == "kick" })
        XCTAssertEqual(kick.ranges.count, 2)
        XCTAssertLessThan(kick.ranges[0].high, kick.ranges[1].low, "thump and beater click do not overlap")
        XCTAssertEqual(kick.bands.map { Config.bandFrequencies[$0] }, [64, 125, 2000, 4000], "two disjoint groups of touched bands")
    }

    func testOuterSpanCoversTheFullInstrumentEvenAcrossAGap() {
        let kick = try! XCTUnwrap(Instruments.all.first { $0.name == "kick" })
        XCTAssertEqual(kick.outerSpan, HzRange(name: "kick", low: 50, high: 5000))
    }

    func testInstrumentsJSONShape() throws {
        let data = try JSONEncoder().encode(Instruments.all)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json.count, 8)
        let kick = try XCTUnwrap(json.first { $0["name"] as? String == "kick" })
        XCTAssertEqual(Set(kick.keys), ["name", "ranges", "bands", "character"])
        XCTAssertEqual(kick["bands"] as? [Double], [64, 125, 2000, 4000])
        let ranges = try XCTUnwrap(kick["ranges"] as? [[String: Any]])
        XCTAssertEqual(ranges.map { $0["name"] as? String }, ["thump", "beater click"])
        XCTAssertEqual(ranges.map { $0["low"] as? Double }, [50, 2000])
        XCTAssertEqual(ranges.map { $0["high"] as? Double }, [100, 5000])
    }

    func testInstrumentTableRendersOneLinePerRangeWithinAModestWidth() {
        let lines = InstrumentTable.render(Instruments.all)
        XCTAssertEqual(lines.count, Instruments.all.reduce(0) { $0 + $1.ranges.count })
        for line in lines { XCTAssertLessThanOrEqual(line.count, 90, line) }
        XCTAssertTrue(lines[0].hasPrefix("kick"), lines[0])
        XCTAssertTrue(lines[0].contains("thump 50Hz–100Hz"), lines[0])
        XCTAssertTrue(lines[0].contains("64Hz 125Hz"), lines[0])
        XCTAssertTrue(lines[1].hasPrefix(" "), "continuation lines leave the name column blank: \(lines[1])")
        XCTAssertTrue(lines[1].contains("beater click 2kHz–5kHz"), lines[1])
    }

    func testInstrumentTableFitsTheTerminalAndKeepsEveryBand() {
        let wanted = Instruments.all.flatMap { $0.ranges.flatMap { InstrumentTable.bandsText($0).split(separator: " ") } }
        for width in [20, 30, 40, 50, 60, 70, 80, 120] {
            let lines = InstrumentTable.render(Instruments.all, width: width)
            for line in lines { XCTAssertLessThanOrEqual(TerminalText.width(line), width, "\(width): \(line)") }
            let bands = lines.flatMap { $0.split(separator: " ").filter { $0.hasSuffix("Hz") && Config.bandLabels.contains(String($0)) } }
            XCTAssertEqual(bands.count, wanted.count, "\(width): every band, once each")
        }
        XCTAssertEqual(InstrumentTable.render(Instruments.all, width: 80), InstrumentTable.render(Instruments.all), "80 columns need no wrap")
        XCTAssertFalse(InstrumentTable.render(Instruments.all, width: 20).contains { $0.contains("…") }, "a range wraps rather than losing its end")
        let narrow = InstrumentTable.render(Instruments.all, width: 50)
        let piano = narrow.firstIndex { $0.hasPrefix("piano") }!
        XCTAssertTrue(narrow[piano + 1].hasPrefix(String(repeating: " ", count: 34)), "the wrapped bands stay in their column: \(narrow[piano + 1])")
        let stacked = InstrumentTable.render(Instruments.all, width: 30)
        XCTAssertTrue(stacked[0].hasPrefix("kick    thump"), stacked[0])
        XCTAssertTrue(stacked[1].hasPrefix("          64Hz"), "under 45 columns the bands go under their range: \(stacked[1])")
    }

    func testZonesNeedsNoConfigAndNoDevice() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-zones-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var context = CLIContext(store: ConfigStore(url: dir.appendingPathComponent("eq.json")), statusURL: dir.appendingPathComponent("status.json"),
                                 connectedDevices: { [] }, defaultOutput: { nil }, fetch: { _ in throw URLError(.notConnectedToInternet) },
                                 cacheDirectory: dir.appendingPathComponent("cache"), today: { "2026-10-14" })
        context.width = { _ in 44 }
        let result = CLI.run(["zones"], context: context)
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.hasPrefix("kick"), result.output)
        for line in result.output.split(separator: "\n") { XCTAssertLessThanOrEqual(TerminalText.width(String(line)), 44, String(line)) }
        XCTAssertEqual(CLI.run(["zones", "--json"], context: context).exitCode, 0)
        XCTAssertFalse(context.store.exists())
    }

    func testHzFormatsUnderAndOverAKilohertz() {
        XCTAssertEqual(InstrumentTable.hz(50), "50Hz")
        XCTAssertEqual(InstrumentTable.hz(2000), "2kHz")
        XCTAssertEqual(InstrumentTable.hz(4200), "4.2kHz")
    }
}
