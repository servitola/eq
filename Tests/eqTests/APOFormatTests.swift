import XCTest
@testable import eq

final class APOFormatTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")))
    }

    private func parse(_ text: String, context: ImportContext = .detached) throws -> ImportResult {
        try EQFormats.parse(Data(text.utf8), context: context)
    }

    private func sQ(gain: Double, s: Double) -> Double {
        let a = pow(10, gain / 40)
        return 1 / sqrt((a + 1 / a) * (1 / s - 1) + 2)
    }

    func testRegistryListsFormatsAndRejectsWhatNoneSniffs() {
        XCTAssertTrue(EQFormats.all.contains { ObjectIdentifier($0) == ObjectIdentifier(APOFormat.self) })
        XCTAssertTrue(APOFormat.sniff(Data("Preamp: -1 dB".utf8), filename: nil))
        XCTAssertFalse(APOFormat.sniff(Data(#"{"gains": {"global": 0}}"#.utf8), filename: "x.json"))
        XCTAssertThrowsError(try parse("hello: world")) { XCTAssertEqual($0 as? ImportError, .unrecognized) }
        XCTAssertThrowsError(try EQFormats.parse(Data())) { XCTAssertEqual($0 as? ImportError, .empty) }
        XCTAssertTrue("\(ImportError.unrecognized)".contains(APOFormat.name))
    }

    func testEveryShelfEncodingIsAShelfTheWayAPOBuildsIt() throws {
        let r = try parse("""
        Filter: ON LS Fc 300 Hz Gain 5.0 dB
        Filter: ON LSC 10.8 dB Fc 300 Hz Gain 5.0 dB
        Filter: ON LSC Fc 300 Hz Gain 5.0 dB Q 0.6473
        Filter: ON LS 12dB Fc 2000 Hz Gain -5.0 dB
        Filter: ON HS 6dB Fc 12000 Hz Gain 10.0 dB
        Filter: ON HSC 6 dB Fc 100 Hz Gain -6.0 dB
        Filter: ON HS Fc 1000 Hz Gain -3 dB Q 0.7
        Filter: ON HSQ Fc 1000 Hz Gain -3 dB Q 0.7
        """)
        XCTAssertEqual(r.warnings, [])
        XCTAssertEqual(r.filters.map(\.type), [.lowShelf, .lowShelf, .lowShelf, .lowShelf, .highShelf, .highShelf, .highShelf, .highShelf])
        // Plain LS is APO's S 0.9 at the centre, the same as LSC 10.8 dB (10.8 / 12 = 0.9).
        XCTAssertEqual(r.filters[0], Filter(type: .lowShelf, frequency: 300, gain: 5, q: sQ(gain: 5, s: 0.9)))
        XCTAssertEqual(r.filters[1].q, r.filters[0].q, accuracy: 1e-12)
        XCTAssertEqual(r.filters[2], Filter(type: .lowShelf, frequency: 300, gain: 5, q: 0.6473))
        XCTAssertEqual(r.filters[3].q, 0.5.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(r.filters[3].frequency, 2000 * pow(10, 5.0 / 80), accuracy: 1e-9)
        XCTAssertEqual(r.filters[4].q, sQ(gain: 10, s: 0.5), accuracy: 1e-12)
        XCTAssertEqual(r.filters[4].frequency, 12000 / pow(10, 10.0 / 80 / 0.5), accuracy: 1e-9)
        XCTAssertEqual(r.filters[5], Filter(type: .highShelf, frequency: 100, gain: -6, q: sQ(gain: -6, s: 0.5)))
        let a = pow(10, -3.0 / 40), s = 1 / ((1 / (0.49) - 2) / (a + 1 / a) + 1)
        XCTAssertEqual(r.filters[6].q, 0.7)
        XCTAssertEqual(r.filters[6].frequency, 1000 / pow(10, 3.0 / 80 / s), accuracy: 1e-9)
        XCTAssertEqual(r.filters[7], Filter(type: .highShelf, frequency: 1000, gain: -3, q: 0.7))
    }

    func testTooSteepASlopeIsSkippedNotTrapped() throws {
        let r = try parse("""
        Filter 1: ON LSC 30 dB Fc 100 Hz Gain 20 dB
        Filter 2: ON PK Fc 1000 Hz Gain 1 dB Q 1
        """)
        XCTAssertEqual(r.filters.count, 1)
        XCTAssertEqual(r.warnings, ["line 1: skipped a filter: a 30 dB/oct slope is too steep for 20 dB of gain"])
    }

    func testPassAndNotchTypesTakeAPODefaultsAndIgnoreGain() throws {
        let r = try parse("""
        Filter  1: ON  HP       Fc     30 Hz
        Filter  2: ON  LPQ      Fc     10000 Hz  Q  0.400
        Filter: ON  NO       Fc     50 Hz
        Filter: ON BP Fc 1000 Hz Q 0.5
        Filter: ON LP Fc 8000 Hz Gain 5 dB
        Filter: ON NOTCH Fc 60 Hz BW Oct 0.1
        Filter: ON PK Fc 1000 Hz Gain 3 dB
        """)
        XCTAssertEqual(Array(r.filters.prefix(5)), [
            Filter(type: .highPass, frequency: 30, gain: 0, q: 0.5.squareRoot()),
            Filter(type: .lowPass, frequency: 10000, gain: 0, q: 0.4),
            Filter(type: .notch, frequency: 50, gain: 0, q: 30),
            Filter(type: .bandPass, frequency: 1000, gain: 0, q: 0.5),
            Filter(type: .lowPass, frequency: 8000, gain: 0, q: 0.5.squareRoot()),
        ])
        XCTAssertEqual(r.filters[5].q, APOFormat.qFromBandwidth(0.1, frequency: 60), accuracy: 1e-12)
        XCTAssertEqual(r.warnings, ["line 7: skipped a filter: no Q or bandwidth"])
    }

    /// The research doc's open question: the old `sqrt(2^BW) / (2^BW − 1)` is RBJ's analog
    /// relation `1 / (2 sinh(ln2/2 · BW))` rewritten; APO adds only the w0/sin w0 warp.
    func testBandwidthToQMatchesRBJAndWarpsLikeAPO() {
        for bw in [0.5, 1, 2, 4] {
            let n = pow(2, bw)
            XCTAssertEqual(n.squareRoot() / (n - 1), 1 / (2 * sinh(log(2) / 2 * bw)), accuracy: 1e-12)
            XCTAssertEqual(APOFormat.qFromBandwidth(bw, frequency: 20), n.squareRoot() / (n - 1), accuracy: 1e-5)
        }
        XCTAssertLessThan(APOFormat.qFromBandwidth(1, frequency: 10000), 0.8 * APOFormat.qFromBandwidth(1, frequency: 100))
    }

    func testMalformedLinesAreSkippedWithAReason() throws {
        let r = try parse("""
        Preamp: loud dB
        Filter 1: ON PK Fc abc Hz Gain 1 dB Q 1
        Filter 2: ON PK Fc 1e400 Hz Gain 1 dB Q 1
        Filter 3: ON PK Fc 30000 Hz Gain 1 dB Q 1
        Filter 4: ON PK Fc 1000 Hz Gain 99 dB Q 1
        Filter 5: ON PK Fc 1000 Hz Gain 1 dB Q 50
        Filter 6: ON PK Fc 1000 Hz Gain `20*log10(0.5)` dB Q 1
        Filter 7: ON IIR Order 2 Coefficients 0.03 0.07 0.03 1.27 -1.84 0.72
        Filter 8: ON XYZ Fc 1000 Hz Gain 1 dB Q 1
        Filter 9: ON PK Gain 1 dB Q 1
        Filter 10: ON PK Fc 1000 Hz Gain nan dB Q 1
        Filter 11: ON PK Fc 1000 Hz Gain 1 dB BW Oct -1
        Filter 12: ON PK Fc 1000 Hz Gain 2 dB Q 1
        """)
        XCTAssertEqual(r.filters, [Filter(type: .peak, frequency: 1000, gain: 2, q: 1)])
        XCTAssertEqual(r.preamp, 0)
        XCTAssertEqual(r.warnings, [
            "line 1: skipped a Preamp: line without a number in dB",
            "line 2: skipped a filter: no frequency (Fc)",
            "line 3: skipped a filter: frequency \u{201C}1e400\u{201D} is not a number",
            "line 4: skipped a filter: frequency 30000 Hz is outside 10–24000 Hz",
            "line 5: skipped a filter: gain 99 dB is outside -30–30 dB",
            "line 6: skipped a filter: Q 50 is outside 0.1–30",
            "line 7: skipped a filter: no gain",
            "line 8: skipped a filter: an IIR filter's raw coefficients are not supported",
            "line 9: skipped a filter: unknown filter type \u{201C}XYZ\u{201D}",
            "line 10: skipped a filter: no frequency (Fc)",
            "line 11: skipped a filter: no gain",
            "line 12: skipped a filter: bandwidth -1 octaves is not positive",
        ])
    }

    func testNothingUsableSaysWhy() {
        XCTAssertThrowsError(try parse("Filter 1: ON PK Fc 99999 Hz Gain 1 dB Q 1")) {
            XCTAssertEqual($0 as? ImportError, .nothingUsable(["line 1: skipped a filter: frequency 99999 Hz is outside 10–24000 Hz"]))
        }
    }

    func testHostileNumbersNeverTrap() throws {
        let values = ["nan", "inf", "-inf", "1e309", "-1e309", "", "0", "-0", "99999999999999999999999", "0x10", "1..2", "--1", ".", "e", ",,"]
        for v in values {
            for line in ["Preamp: \(v) dB", "Filter: ON PK Fc \(v) Hz Gain 1 dB Q 1", "Filter: ON PK Fc 1000 Hz Gain \(v) dB Q 1",
                         "Filter: ON LSC \(v) dB Fc 100 Hz Gain 3 dB", "Filter: ON LS Fc 100 Hz Gain 3 dB Q \(v)",
                         "Filter: ON PK Fc 1000 Hz Gain 1 dB BW Oct \(v)", "GraphicEQ: \(v) 1; 100 \(v); 1000 0"] {
                if let r = try? parse(line + "\nFilter: ON PK Fc 500 Hz Gain 1 dB Q 1") {
                    for f in r.filters {
                        XCTAssertTrue(f.frequency.isFinite && f.gain.isFinite && f.q.isFinite, line)
                        XCTAssertTrue(Config.filterFrequencyRange.contains(f.frequency) && Config.filterQRange.contains(f.q), line)
                    }
                    XCTAssertTrue(r.preamp.isFinite, line)
                    XCTAssertTrue(r.bands?.allSatisfy { $0.isFinite && Config.gainRange.contains($0) } ?? true, line)
                }
            }
        }
    }

    func testFrequencyUnitsCommasAndREWThousands() throws {
        let r = try parse("""
        Filter: ON PK Fc 10 kHz Gain -3,5 dB Q 1
        Filter: ON PK Fc 1,911 Hz Gain 1 dB Q 1
        Filter: ON PK Fc 50,4 Hz Gain 1 dB Q 1
        Filter: ON PK Fc 2 kHz Gain 1 dB Q 1
        """)
        XCTAssertEqual(r.filters.map(\.frequency), [10000, 1911, 50.4, 2000])
        XCTAssertEqual(r.filters[0].gain, -3.5)
    }

    func testPreampsSumAndOutOfRangeIsRefused() throws {
        XCTAssertEqual(try parse("Preamp: -6 db\nPreamp: -5 dB\nFilter: ON PK Fc 1000 Hz Gain 1 dB Q 1").preamp, -11)
        XCTAssertThrowsError(try parse("Preamp: -20 dB\nPreamp: -20 dB\nFilter: ON PK Fc 1000 Hz Gain 1 dB Q 1")) {
            XCTAssertEqual($0 as? ImportError, .preampOutOfRange(-40))
        }
    }

    /// AutoEq's `.txt` preamp is the cascade's own peak; its README and web app take 0.1 dB more.
    /// The file's value is what gets applied, not a recomputed or more conservative one.
    func testAutoEqPreampIsTakenFromTheFileNotRecomputed() throws {
        let r = try EQFormats.parse(try fixture("Sony WH-1000XM4 ParametricEQ"))
        XCTAssertEqual(r.preamp, -6.1)
        let coefficients = r.filters.map {
            BiquadCoefficients.make(type: $0.type, frequency: $0.frequency, gainDB: $0.gain, q: $0.q, sampleRate: 48000)
        }
        let peak = stride(from: log10(20.0), through: log10(20000.0), by: 0.001).map { e -> Double in
            coefficients.reduce(0) { $0 + $1.magnitudeDB(at: pow(10, e), sampleRate: 48000) }
        }.max() ?? 0
        XCTAssertEqual(-peak, r.preamp, accuracy: 0.1, "the file's preamp is the cascade's peak")
        XCTAssertNotEqual(r.preamp, (-(peak + 0.1) * 10).rounded() / 10, "not the README's extra 0.1 dB")
    }

    func testFixedBandEQBecomesTheTenBands() throws {
        let r = try EQFormats.parse(try fixture("Sony WH-1000XM4 FixedBandEQ"))
        XCTAssertEqual(r.bands, [-4.3, -1.8, -5.8, -1.4, 0.5, -0.6, 6.0, -0.8, 1.0, -2.2])
        XCTAssertEqual(r.filters, [])
        XCTAssertEqual(r.preamp, -5.8)
        XCTAssertEqual(r.format, "AutoEq FixedBandEQ (10 bands)")
        XCTAssertEqual(r.warnings, [])
    }

    func testTenPeaksOffOurCentresStayFilters() throws {
        var text = String(decoding: try fixture("Sony WH-1000XM4 FixedBandEQ"), as: UTF8.self)
        text = text.replacingOccurrences(of: "Fc 500 Hz", with: "Fc 560 Hz")
        let r = try parse(text)
        XCTAssertNil(r.bands)
        XCTAssertEqual(r.filters.count, 10)
        XCTAssertEqual(r.format, "AutoEq / Equalizer APO parametric")
    }

    func testREWGenericExportWithItsSpacingAndEmptySlots() throws {
        let r = try EQFormats.parse(try fixture("REW Generic filters"))
        XCTAssertEqual(r.format, "REW filter settings")
        XCTAssertEqual(r.filters.count, 13)
        XCTAssertEqual(r.filters[0], Filter(type: .peak, frequency: 7515, gain: -9.7, q: 1))
        XCTAssertEqual(r.filters[2], Filter(type: .peak, frequency: 50.4, gain: -6, q: 2.58))
        XCTAssertEqual(r.preamp, 0)
        XCTAssertEqual(r.warnings, [], "`ON None` slots are empty, not errors")
    }

    /// The shape squig.link's graphtool.js writes: CRLF, `Channel: L`/`R` blocks each with a preamp.
    func testSquigLinkChannelsAndCRLF() throws {
        let block = "Preamp: -3.6 dB\r\nFilter 1: ON LSC Fc 105 Hz Gain -1.1 dB Q 0.7\r\nFilter 2: ON PK Fc 172 Hz Gain -3.1 dB Q 0.9\r\n"
        let same = try parse("Channel: L\r\n" + block + "\r\nChannel: R\r\n" + block + "\r\n")
        XCTAssertEqual(same.warnings, [])
        XCTAssertEqual(same.preamp, -3.6)
        XCTAssertEqual(same.filters.count, 2)

        let other = block.replacingOccurrences(of: "Gain -3.1", with: "Gain -2.0")
        let differ = try parse("Channel: L\r\n" + block + "\r\nChannel: R\r\n" + other)
        XCTAssertEqual(differ.filters[1].gain, -3.1)
        XCTAssertEqual(differ.warnings, ["left and right channels differ; imported the left channel"])

        XCTAssertEqual(try parse("Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1\r\nFilter 2: ON AP Fc 900 Hz Q 0.7\r\n").warnings,
                       ["line 2: skipped a filter: an all-pass filter is not supported"])
        let lf = try EQFormats.parse(try fixture("Sony WH-1000XM4 ParametricEQ"))
        let crlf = String(decoding: try fixture("Sony WH-1000XM4 ParametricEQ"), as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(try parse(crlf), lf)
    }

    func testDisabledPaddingIsSilent() throws {
        let r = try parse("""
        Preamp: -3.6 dB
        Filter 1: ON LSC Fc 105 Hz Gain -1.1 dB Q 0.70
        Filter 9: OFF PK Fc 0 Hz Gain 0.0 dB Q 0.000
        Filter 10: OFF PK Fc 0 Hz Gain 0.0 dB Q 0.000
        """)
        XCTAssertEqual(r.filters.count, 1)
        XCTAssertEqual(r.warnings, [])
    }

    func testAPOReferenceExample() throws {
        let r = try EQFormats.parse(try fixture("APO config reference example"))
        XCTAssertEqual(r.preamp, -11, "-6 for all channels plus -5 for the left")
        XCTAssertEqual(r.filters.count, 3)
        XCTAssertEqual(r.filters[0], Filter(type: .peak, frequency: 50, gain: -3, q: 10))
        XCTAssertEqual(r.filters[1].q, APOFormat.qFromBandwidth(0.167, frequency: 100), accuracy: 1e-12)
        XCTAssertEqual(r.filters[2], Filter(type: .lowShelf, frequency: 300, gain: 5, q: sQ(gain: 5, s: 0.9)))
        XCTAssertEqual(r.warnings, [
            "Device: ignored, every filter is imported whatever device it names",
            "line 4: not following Include: example.txt, only a file import can include other files",
            "line 12: not following Include: demo.txt, only a file import can include other files",
            "left and right channels differ; imported the left channel",
        ])
    }

    func testOtherChannelsAndIgnoredCommandsAreNamedOnce() throws {
        let r = try parse("""
        Stage: pre-mix
        Copy: L=L+0.5*R
        Copy: R=R+0.5*L
        Eval: a=1
        If: sampleRate == 48000
        Filter: ON PK Fc 1000 Hz Gain 1 dB Q 1
        EndIf:
        Delay: 5 ms
        Channel: C LFE
        Filter: ON PK Fc 60 Hz Gain 3 dB Q 1
        """)
        XCTAssertEqual(r.filters.count, 1)
        XCTAssertEqual(r.warnings, [
            "Stage: ignored, every filter is imported into one stage",
            "Copy: ignored, eq does not mix channels",
            "Eval: ignored, expressions are not evaluated",
            "If:/Else: ignored, filters from every branch are imported",
            "Delay: ignored, eq has no delay",
            "skipped 1 line for channels other than left and right",
        ])
    }

    func testGraphicEQPointsAreCheckedAndAFilePreampWins() throws {
        let r = try parse("GraphicEQ: 20 0; 0 5; abc; 40 6; 80 0; 20000 0")
        XCTAssertEqual(r.warnings.first, "line 1: skipped 2 malformed GraphicEQ points")
        XCTAssertEqual(r.bands?[0] ?? 0, 6 * log(32.0 / 20) / log(40.0 / 20), accuracy: 0.05)
        XCTAssertEqual(r.preamp, -((r.bands?.max() ?? 0) * 10).rounded() / 10)

        let loud = try parse("Preamp: -2 dB\nGraphicEQ: 20 20; 20000 20")
        XCTAssertEqual(loud.bands, Array(repeating: 12, count: 10))
        XCTAssertEqual(loud.preamp, -2)
        XCTAssertTrue(loud.warnings.contains("GraphicEQ gains beyond ±12 dB were limited to it"), "\(loud.warnings)")

        let mixed = try parse("GraphicEQ: 20 1; 20000 1\nFilter: ON PK Fc 1000 Hz Gain 1 dB Q 1")
        XCTAssertEqual(mixed.bands, Array(repeating: 1, count: 10))
        XCTAssertEqual(mixed.filters.count, 1)
        XCTAssertEqual(mixed.format, "Equalizer APO GraphicEQ + filters")
    }

    func testByteOrderMarksAndUTF16() throws {
        let text = "Preamp: -1 dB\r\nFilter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1\r\n"
        let plain = try parse(text)
        XCTAssertEqual(try EQFormats.parse(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)), plain)
        XCTAssertEqual(try EQFormats.parse(try XCTUnwrap(text.data(using: .utf16))), plain)
    }

    // MARK: - Include

    private func tree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eq-apo-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func parseFile(_ url: URL) throws -> ImportResult {
        try EQFormats.parse(try Data(contentsOf: url), filename: url.lastPathComponent, context: ImportContext(file: url))
    }

    func testIncludeResolvesAgainstTheIncludingFileAndStopsCycles() throws {
        let root = try tree([
            "main.txt": "Preamp: -2 dB\nInclude: sub/part.txt\nFilter: ON PK Fc 3000 Hz Gain 3 dB Q 1",
            "sub/part.txt": "Filter: ON PK Fc 1000 Hz Gain 1 dB Q 1\nInclude: more.txt\nInclude: ../main.txt\nInclude: missing.txt",
            "sub/more.txt": "Preamp: -1 dB\nFilter: ON PK Fc 2000 Hz Gain 2 dB Q 1",
        ])
        let r = try parseFile(root.appendingPathComponent("main.txt"))
        XCTAssertEqual(r.filters.map(\.frequency), [1000, 2000, 3000])
        XCTAssertEqual(r.preamp, -3)
        XCTAssertEqual(r.warnings.count, 2, "\(r.warnings)")
        XCTAssertEqual(r.warnings[0], "part.txt line 3: not following Include: ../main.txt, it includes itself")
        XCTAssertTrue(r.warnings[1].hasPrefix("part.txt line 4: not following Include: missing.txt, cannot read "), r.warnings[1])
    }

    func testIncludeDepthIsLimited() throws {
        var files: [String: String] = [:]
        for i in 0...6 { files["f\(i).txt"] = "Filter: ON PK Fc \(1000 + i) Hz Gain 1 dB Q 1\nInclude: f\(i + 1).txt" }
        let r = try parseFile(try tree(files).appendingPathComponent("f0.txt"))
        XCTAssertEqual(r.filters.count, APOFormat.maxIncludeDepth + 1)
        XCTAssertEqual(r.warnings, ["f4.txt line 2: not following Include: f5.txt, includes nest deeper than 4"])
    }

    func testIncludeFanOutIsLimited() throws {
        let includes = Array(repeating: "Include: leaf.txt", count: APOFormat.maxIncludedFiles + 1).joined(separator: "\n")
        let root = try tree(["main.txt": includes, "leaf.txt": "Filter: ON PK Fc 1000 Hz Gain 1 dB Q 1"])
        let r = try parseFile(root.appendingPathComponent("main.txt"))
        XCTAssertEqual(r.filters.count, APOFormat.maxIncludedFiles)
        XCTAssertEqual(r.warnings.count, 1)
    }
}
