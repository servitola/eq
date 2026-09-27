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

    private func line(_ text: String) -> [Character] { Array(text) }

    func testAllZonesUseValidAscendingBands() {
        XCTAssertEqual(Zones.all.count, 10)
        for zone in Zones.all {
            XCTAssertFalse(zone.bands.isEmpty, zone.name)
            XCTAssertTrue(zone.bands.allSatisfy { (0...9).contains($0) }, zone.name)
            XCTAssertEqual(zone.bands, zone.bands.sorted(), zone.name)
            XCTAssertEqual(zone.short.count, 3, zone.name)
            XCTAssertLessThanOrEqual(zone.name.count, Zones.fullNameWidth, zone.name)
        }
        XCTAssertEqual(Zones.compact.map(\.name), ["sub", "kick", "bass", "guitar", "voice", "cymbals", "air"])
    }

    func testModeCycles() {
        XCTAssertEqual(ZoneMode.off.next, .compact)
        XCTAssertEqual(ZoneMode.compact.next, .all)
        XCTAssertEqual(ZoneMode.all.next, .off)
    }

    func testVoiceSpanCoversOneKilohertzCentreNotTwoFifty() {
        let layout = WatchLayout.fit(cols: 64, rows: 30, zones: 7)
        let rows = Zones.render(Zones.compact, layout: layout, levels: silent, gains: flat)
        XCTAssertEqual(rows.count, 7)
        let start = Zones.placement(layout).start
        let voice = line(rows[4])
        XCTAssertTrue(rows[4].hasPrefix("vox "), rows[4])
        XCTAssertEqual(voice[start + layout.centre(5)], "━")
        XCTAssertEqual(voice[start + layout.centre(4)], "━")
        XCTAssertEqual(voice[start + layout.centre(3)], " ")
        XCTAssertEqual(voice.count, start + layout.centre(7) + 1, "the span ends at the 4 kHz bar centre")
    }

    func testWideLayoutUsesFullNamesInThePad() {
        let layout = WatchLayout.fit(cols: 100, rows: 30, zones: 7)
        XCTAssertEqual(Zones.placement(layout), .init(start: 10, nameWidth: 9, full: true))
        let rows = Zones.render(Zones.compact, layout: layout, levels: silent, gains: flat)
        XCTAssertEqual(rows.map { String($0.prefix(9)).trimmingCharacters(in: .whitespaces) },
                       ["sub", "kick", "bass", "guitar", "voice", "cymbals", "air"])
        let lines = Watch.frame(frame(), layout: layout, zones: Zones.compact)
        XCTAssertEqual(lines[1 + layout.meterRows + 1], String(repeating: " ", count: 10) + Table.labelsRow(width: 8))
    }

    func testNarrowLayoutShiftsFrameForShortNames() {
        let layout = WatchLayout.fit(cols: 50, rows: 20, zones: 7)
        XCTAssertEqual(Zones.placement(layout), .init(start: 7, nameWidth: 4, full: false))
        let lines = Watch.frame(frame(), layout: layout, zones: Zones.compact)
        XCTAssertEqual(lines.count, 1 + 8 + 3 + 7)
        XCTAssertEqual(Array(lines.suffix(7)).map { String($0.prefix(6)).trimmingCharacters(in: .whitespaces) },
                       ["sub", "kck", "bas", "gtr", "vox", "cym", "air"])
        XCTAssertEqual(lines[1 + 8 + 1], "       " + Table.labelsRow(width: 4, short: true))
        for line in lines { XCTAssertLessThanOrEqual(line.count, 50, line) }
        let plain = Watch.frame(frame(), layout: .fit(cols: 50, rows: 20))
        XCTAssertEqual(plain[1 + 15 + 1], "     " + Table.labelsRow(width: 4, short: true), "without zones the frame stays centred")
    }

    func testTightLayoutKeepsBarsInsideTheWidth() {
        let layout = WatchLayout.fit(cols: 42, rows: 20, zones: 10)
        let lines = Watch.frame(frame(), layout: layout, zones: Zones.all)
        for line in lines { XCTAssertLessThanOrEqual(line.count, 42, line) }
        XCTAssertTrue(lines.last?.hasPrefix("air") ?? false, lines.last ?? "")
    }

    func testSnareDrawsTwoSegments() {
        let layout = WatchLayout.fit(cols: 100, rows: 30, zones: 10)
        let snare = line(Zones.render([Zones.all[6]], layout: layout, levels: silent, gains: flat)[0])
        let start = Zones.placement(layout).start
        XCTAssertEqual(snare[start + layout.centre(3)], "━")
        XCTAssertEqual(snare[start + layout.centre(5)], " ")
        XCTAssertEqual(snare[start + layout.centre(7)], "━")
        let segments = String(snare).split(separator: " ").filter { $0.contains("━") }
        XCTAssertEqual(segments.map(\.count), [3, 3], "a lone band covers its three-glyph bar")
    }

    func testLoudestBandLendsItsInk() {
        Paint.forced = true
        let layout = WatchLayout.fit(cols: 100, rows: 30, zones: 7)
        var levels = Array(repeating: -30.0, count: 10)
        levels[6] = -3
        var gains = flat
        gains[6] = 4
        let voice = Zones.render([Zones.all[5]], layout: layout, levels: levels, gains: gains)[0]
        XCTAssertTrue(voice.contains("\u{1B}[2mvoice"), voice)
        XCTAssertTrue(voice.contains("\u{1B}[92m━"), voice)
        XCTAssertTrue(voice.contains("\u{1B}[2m━"), voice)
        let quiet = Zones.render([Zones.all[5]], layout: layout, levels: silent, gains: gains)[0]
        XCTAssertFalse(quiet.contains("\u{1B}[92m"), "silence leaves every span dim")
    }

    func testFitReservesZoneRows() {
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 30, zones: 7).meterRows, 18)
        let short = WatchLayout.fit(cols: 100, rows: 14, zones: 7)
        XCTAssertEqual(short.meterRows, 4)
        XCTAssertEqual(short.zoneRows, 5)
        XCTAssertEqual(Watch.frame(frame(), layout: short, zones: Zones.compact).count, 1 + 4 + 3 + 5)
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 8, zones: 7).zoneRows, 0)
        XCTAssertEqual(WatchLayout.fit(cols: 100, rows: 30), WatchLayout.fit(cols: 100, rows: 30, zones: 0))
    }

    func testRunCyclesZonesOnZ() throws {
        struct Source: MeterSource {
            let lines: [String]
            func lines(maxLines: Int?, handle: (String) -> Bool) -> Bool {
                for line in lines { guard handle(line) else { return false } }
                return true
            }
        }
        let line = String(decoding: try MeterFrame.encodeLine(frame()).dropLast(), as: UTF8.self)
        var emitted: [String] = []
        var keys: [UInt8?] = [UInt8(ascii: "z"), UInt8(ascii: "z"), UInt8(ascii: "z"), nil]
        _ = Watch.run(source: Source(lines: Array(repeating: line, count: 4)), size: { (100, 30) },
                      emit: { emitted.append($0) }, readKey: { keys.isEmpty ? nil : keys.removeFirst() })
        let frames = emitted.filter { $0.contains("\u{1B}[H") }
        XCTAssertEqual(frames.count, 4)
        XCTAssertEqual(frames.map { $0.contains("cymbals") }, [false, true, true, false])
        XCTAssertEqual(frames.map { $0.contains("sibilance") }, [false, false, true, false])

        emitted = []
        _ = Watch.run(source: Source(lines: [line]), size: { (100, 30) }, zones: .compact,
                      emit: { emitted.append($0) }, readKey: { nil })
        XCTAssertTrue(emitted.contains { $0.contains("voice") })
    }
}
