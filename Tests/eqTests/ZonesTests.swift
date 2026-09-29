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

    func testAxisPutsBandFrequenciesOnTheirBarCentresAndInterpolatesInOctaves() {
        let layout = WatchLayout.fit(cols: 100, rows: 30)
        for (i, f) in Config.bandFrequencies.enumerated() {
            XCTAssertEqual(Strip.x(f, layout: layout), Double(layout.centre(i)), accuracy: 1e-9, "\(f)")
        }
        let between = Strip.x((500.0 * 1000).squareRoot(), layout: layout)
        XCTAssertEqual(between, Double(layout.centre(4) + layout.centre(5)) / 2, accuracy: 1e-9)
        XCTAssertLessThan(Strip.x(20, layout: layout), Double(layout.centre(0)), "below 32 Hz the axis carries on left")
        XCTAssertGreaterThan(Strip.x(20000, layout: layout), Double(layout.centre(9)))
    }

    func testSegmentsStayInsideTheTableWithAGapBetweenRanges() {
        for cols in [20, 42, 60, 100, 200] {
            let layout = WatchLayout.fit(cols: cols, rows: 30)
            for instrument in Instruments.all {
                let segments = Strip.segments(instrument, layout: layout)
                for s in segments {
                    XCTAssertGreaterThanOrEqual(s.lo, 0, "\(cols) \(instrument.name)")
                    XCTAssertLessThan(s.hi, layout.tableWidth, "\(cols) \(instrument.name)")
                    XCTAssertLessThanOrEqual(s.lo, s.hi)
                }
                for (a, b) in zip(segments, segments.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(b.lo, a.hi + 2, "\(cols) \(instrument.name): \(a) \(b)")
                }
            }
        }
    }

    func testVoiceDrawsEveryRangeAtOneHundredColumns() {
        let layout = WatchLayout.fit(cols: 100, rows: 30)
        let voice = Strip.segments(instrument("voice"), layout: layout)
        XCTAssertEqual(voice.map(\.name), ["fundamental", "F1", "F2", "presence", "sibilance"])
        XCTAssertEqual(voice.first?.lo, Int(Strip.x(85, layout: layout).rounded()))
        XCTAssertEqual(voice.last?.hi, Int(Strip.x(9000, layout: layout).rounded()))
    }

    func testKickRowShowsTwoSpansWithTheirNames() {
        let layout = WatchLayout.fit(cols: 100, rows: 30, zones: 8)
        let row = Strip.row(instrument("kick"), layout: layout, levels: silent, gains: flat)
        XCTAssertTrue(row.hasPrefix("  kick "), row)
        let spans = row.dropFirst(Strip.placement(layout).start).split(separator: " ", omittingEmptySubsequences: true)
        XCTAssertTrue(spans.allSatisfy { $0.allSatisfy { $0 == "━" } || !$0.contains("━") }, row)
        XCTAssertEqual(Strip.segments(instrument("kick"), layout: layout).count, 2)
        XCTAssertTrue(row.contains("━ thump ━"), row)
        XCTAssertFalse(row.contains("beater"), "a name wider than its span is left out: \(row)")
        XCTAssertLessThanOrEqual(row.count, 100)
    }

    func testNarrowLayoutUsesShortNamesAndShiftsTheFrame() {
        let layout = WatchLayout.fit(cols: 60, rows: 20, zones: 8)
        XCTAssertEqual(Strip.placement(layout), .init(start: 7, nameWidth: 4, full: false))
        let lines = Watch.frame(frame(), layout: layout, strip: true)
        let strip = Array(lines[(1 + layout.meterRows)..<(1 + layout.meterRows + layout.zoneRows)])
        XCTAssertEqual(strip.map { String($0.prefix(6)).trimmingCharacters(in: .whitespaces) },
                       Array(Instruments.all.map(\.short).prefix(layout.zoneRows)))
        XCTAssertEqual(lines[1 + layout.meterRows + layout.zoneRows + 1], "       " + Table.labelsRow(width: 5, short: true))
        for line in lines { XCTAssertLessThanOrEqual(line.count, 60, line) }
        let plain = Watch.frame(frame(), layout: .fit(cols: 60, rows: 20))
        XCTAssertTrue(plain[1].hasPrefix("     "), "without the strip the frame stays centred")
    }

    func testStripSitsDirectlyAboveTheLiveRow() {
        let layout = WatchLayout.fit(cols: 100, rows: 30, zones: 8)
        let lines = Watch.frame(frame(), layout: layout, strip: true)
        XCTAssertEqual(lines.count, 1 + layout.meterRows + 8 + 3 + 2)
        XCTAssertTrue(lines[1 + layout.meterRows].hasPrefix("  kick"), lines[1 + layout.meterRows])
        XCTAssertTrue(lines[layout.meterRows + 8].hasPrefix("  air"), lines[layout.meterRows + 8])
        XCTAssertEqual(lines[1 + layout.meterRows + 8], String(repeating: " ", count: 10) + String(repeating: "     -20", count: 10))
    }

    func testLoudestBandLendsItsInk() {
        Paint.forced = true
        let layout = WatchLayout.fit(cols: 100, rows: 30, zones: 8)
        var levels = Array(repeating: -30.0, count: 10)
        levels[6] = -3
        var gains = flat
        gains[6] = 4
        let voice = Strip.row(instrument("voice"), layout: layout, levels: levels, gains: gains)
        XCTAssertTrue(voice.contains("\u{1B}[2mvoice"), voice)
        XCTAssertTrue(voice.contains("\u{1B}[92m━"), voice)
        XCTAssertTrue(voice.contains("\u{1B}[2m━"), voice)
        let quiet = Strip.row(instrument("voice"), layout: layout, levels: silent, gains: gains)
        XCTAssertFalse(quiet.contains("\u{1B}[92m"), "silence leaves every span dim")
        let focused = Strip.row(instrument("voice"), layout: layout, levels: silent, gains: gains, highlighted: true)
        XCTAssertTrue(focused.contains("\u{1B}[1mvoice"), focused)
        XCTAssertFalse(focused.contains("\u{1B}[2m━"), "a highlighted row drops the dim from its strokes")
    }

    func testFitReservesStripAndBracketRows() {
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 30, zones: 8).meterRows, 16)
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 30, zones: 1, bracket: true).meterRows, 22)
        let short = WatchLayout.fit(cols: 100, rows: 14, zones: 8, bracket: true)
        XCTAssertEqual(short.meterRows, 4)
        XCTAssertEqual(short.bracketRows, 1)
        XCTAssertEqual(short.zoneRows, 3)
        let voice = Instruments.all.first { $0.name == "voice" }
        XCTAssertEqual(Watch.frame(frame(), layout: short, strip: true, focus: voice).count, 1 + 1 + 4 + 1 + 3 + 2,
                       "a focus shows one strip row however many are budgeted")
        XCTAssertEqual(Watch.frame(frame(), layout: .fit(cols: 100, rows: 14, zones: 1, bracket: true), strip: true, focus: voice).count, 14)
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 10, zones: 8, bracket: true).bracketRows, 0)
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 8, zones: 8).zoneRows, 0)
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 30), WatchLayout.fit(cols: 100, rows: 30, zones: 0))
    }

    func testRunTogglesTheStripOnZ() throws {
        struct Source: MeterSource {
            let lines: [String]
            func lines(maxLines: Int?, handle: (String) -> Bool) -> Bool {
                for line in lines { guard handle(line) else { return false } }
                return true
            }
        }
        let line = String(decoding: try MeterFrame.encodeLine(frame()).dropLast(), as: UTF8.self)
        var emitted: [String] = []
        var keys: [String?] = ["z", "z", nil]
        _ = Watch.run(source: Source(lines: Array(repeating: line, count: 3)), size: { (100, 30) },
                      emit: { emitted.append($0) }, readKey: { keys.isEmpty ? nil : keys.removeFirst() })
        let frames = emitted.filter { $0.contains("\u{1B}[H") }
        XCTAssertEqual(frames.map { $0.contains("cymbals") }, [false, true, false])

        emitted = []
        _ = Watch.run(source: Source(lines: [line]), size: { (100, 30) }, zones: true,
                      emit: { emitted.append($0) }, readKey: { nil })
        XCTAssertTrue(emitted.contains { $0.contains("voice") })
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

    func testHzFormatsUnderAndOverAKilohertz() {
        XCTAssertEqual(InstrumentTable.hz(50), "50Hz")
        XCTAssertEqual(InstrumentTable.hz(2000), "2kHz")
        XCTAssertEqual(InstrumentTable.hz(4200), "4.2kHz")
    }
}
