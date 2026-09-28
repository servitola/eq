import XCTest
@testable import eq

final class ExportTests: XCTestCase {
    private let header = Exporter.Header(device: "HD 600", date: "2026-09-28")

    /// Every filter type, all three preference layers, off-grid numbers that only survive exact printing.
    private let full = Profile(
        name: "HD 600", preamp: -6.3, bands: [1.5, 0, -2, 0.25, 0, -3.1, 0, 2, 0, -1],
        filters: [
            Filter(type: .peak, frequency: 143.7, gain: -5.2, q: 1.1, origin: .import),
            Filter(type: .lowShelf, frequency: 105, gain: 4.2, q: 0.7, origin: .import),
            Filter(type: .highShelf, frequency: 10000, gain: -1, q: 0.7, origin: .hand),
            Filter(type: .lowPass, frequency: 18000, gain: 0, q: 0.707, origin: .hand),
            Filter(type: .highPass, frequency: 25, gain: 0, q: 0.5, origin: .hand),
            Filter(type: .notch, frequency: 6123.4, gain: 0, q: 8, origin: .hand),
            Filter(type: .bandPass, frequency: 1000, gain: 0, q: 0.3, origin: .hand),
        ],
        preference: Preference(bass: 3, treble: -1.5, tilt: 0.3))

    private let bandsOnly = Profile(name: "JBL", preamp: -4.8, bands: Config.screenshotCurve)

    private func engineFilters(_ profile: Profile) -> [Filter] {
        profile.engineBands.map { Filter(type: $0.type, frequency: $0.frequency, gain: $0.gain, q: $0.q) }
    }

    private func sameSound(_ a: [Filter], _ b: [Filter], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for (x, y) in zip(a, b) { XCTAssertTrue(x.sounds(like: y), "\(x) vs \(y)", file: file, line: line) }
    }

    // MARK: - APO

    func testAPORoundTripIsExact() throws {
        let text = try Exporter.render(full, as: .apo, header: header)
        let back = try EQFormats.parse(Data(text.utf8))
        XCTAssertNil(back.bands)
        XCTAssertEqual(back.preamp, full.preamp)
        XCTAssertEqual(back.warnings, [])
        sameSound(back.filters, engineFilters(full))
    }

    func testAPOWritesCentredShelvesAndQPasses() throws {
        let lines = try Exporter.render(full, as: .apo, header: header).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "# Exported by eq for HD 600, 2026-09-28")
        XCTAssertEqual(lines[1], "Preamp: -6.3 dB")
        XCTAssertEqual(lines[2], "Filter 1: ON PK Fc 32 Hz Gain 1.5 dB Q 1.41")
        XCTAssertTrue(lines.contains("Filter 12: ON LSC Fc 105 Hz Gain 4.2 dB Q 0.7"))
        XCTAssertTrue(lines.contains("Filter 13: ON HSC Fc 10000 Hz Gain -1 dB Q 0.7"))
        XCTAssertTrue(lines.contains("Filter 14: ON LPQ Fc 18000 Hz Q 0.707"))
        XCTAssertTrue(lines.contains("Filter 15: ON HPQ Fc 25 Hz Q 0.5"))
        XCTAssertTrue(lines.contains("Filter 16: ON NO Fc 6123.4 Hz Q 8"))
        XCTAssertTrue(lines.contains("Filter 17: ON BP Fc 1000 Hz Q 0.3"))
        XCTAssertEqual(lines.count, 2 + full.engineBands.count)
    }

    func testAPOOfBandsOnlyImportsBackAsTheTenBands() throws {
        let back = try EQFormats.parse(Data(try Exporter.render(bandsOnly, as: .apo, header: header).utf8))
        XCTAssertEqual(back.bands, bandsOnly.bands)
        XCTAssertEqual(back.filters, [])
        XCTAssertEqual(back.preamp, bandsOnly.preamp)
    }

    func testHeaderCommentStaysOneLine() throws {
        let text = try Exporter.render(bandsOnly, as: .apo, header: .init(device: "Evil\nPreamp: 12 dB", date: "d"))
        XCTAssertEqual(try EQFormats.parse(Data(text.utf8)).preamp, bandsOnly.preamp)
    }

    func testNumbersPrintShortestExactForm() {
        XCTAssertEqual(Exporter.number(105), "105")
        XCTAssertEqual(Exporter.number(-0.0), "0")
        XCTAssertEqual(Exporter.number(0.1 + 0.2), "0.30000000000000004")
        let tilt = Preference.tiltCentre / pow(2, 1.25)
        XCTAssertEqual(Double(Exporter.number(tilt)), tilt)
    }

    // MARK: - GraphicEQ

    func testGraphicEQGridIsAutoEqs() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Sony WH-1000XM4 GraphicEQ", withExtension: "txt", subdirectory: "Fixtures"))
        let fixture = try String(contentsOf: url, encoding: .utf8)
        let grid = fixture.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("GraphicEQ: ".count)
            .components(separatedBy: "; ").map { Int($0.split(separator: " ")[0])! }
        XCTAssertEqual(Exporter.graphicEQFrequencies, grid)
        XCTAssertEqual(grid.count, 127)
    }

    func testGraphicEQIsTheWholeResponseWithPreamp() throws {
        let text = try Exporter.render(full, as: .graphiceq, header: header)
        XCTAssertFalse(text.contains("Preamp"))
        let points = text.dropFirst("GraphicEQ: ".count).components(separatedBy: "; ")
        XCTAssertEqual(points.count, 127)
        for point in points {
            let parts = point.split(separator: " ")
            let expected = Exporter.response(full, at: Double(parts[0])!)
            XCTAssertEqual(Double(parts[1])!, expected, accuracy: 0.05, point)
        }
    }

    /// The importer reduces 127 points to ten band gains by interpolation; at the centres that
    /// costs the 0.05 dB of rounding plus the curvature between two grid points.
    func testGraphicEQRoundTripAtBandCentres() throws {
        var profile = Profile(name: nil, preamp: 0, bands: [2, 1, 0, 0, 0, -1, 0, 1, 1, 0],
                              filters: [Filter(type: .peak, frequency: 143.7, gain: -3, q: 1.1)],
                              preference: Preference(bass: 3, treble: -1.5, tilt: 0.3))
        // AutoEq pins the peak at or below 0 dB; the importer then reads the curve with no preamp.
        profile.preamp = -(Exporter.graphicEQFrequencies.map { Exporter.response(profile, at: Double($0)) }.max()! * 10).rounded(.up) / 10
        let back = try EQFormats.parse(Data(try Exporter.render(profile, as: .graphiceq, header: header).utf8))
        let bands = try XCTUnwrap(back.bands)
        XCTAssertEqual(back.preamp, 0)
        for (gain, centre) in zip(bands, Config.bandFrequencies) {
            XCTAssertEqual(gain, Exporter.response(profile, at: centre), accuracy: 0.15, "\(centre) Hz")
        }
    }

    func testFlatGraphicEQHasNoNegativeZero() throws {
        let text = try Exporter.render(.flat, as: .graphiceq, header: header)
        XCTAssertFalse(text.contains("-0.0"))
        XCTAssertTrue(text.hasPrefix("GraphicEQ: 20 0.0; 21 0.0;"))
    }

    // MARK: - eqMac

    func testEqMacCarriesBandsAndPreamp() throws {
        let text = try Exporter.render(bandsOnly, as: .eqmac, header: header)
        let preset = try JSONDecoder().decode(Exporter.EqMacPreset.self, from: Data(text.utf8))
        XCTAssertEqual(preset.gains.bands, bandsOnly.bands)
        XCTAssertEqual(preset.gains.global, bandsOnly.preamp)
        XCTAssertEqual(preset.name, "HD 600")
        XCTAssertFalse(preset.isDefault)
        XCTAssertFalse(preset.id.isEmpty)
    }

    func testEqMacNamesThePreset() throws {
        var profile = bandsOnly
        profile.preset = "night"
        let preset = try JSONDecoder().decode(Exporter.EqMacPreset.self, from: Data(try Exporter.render(profile, as: .eqmac, header: header).utf8))
        XCTAssertEqual(preset.name, "night")
    }

    func testEqMacRefusesWhatItCannotHold() {
        XCTAssertThrowsError(try Exporter.render(full, as: .eqmac, header: header)) { error in
            XCTAssertEqual(error as? ExportError, .eqMacNeedsBandsOnly(filters: 7, preference: true))
            XCTAssertTrue("\(error)".contains("7 parametric filters and bass/treble/tilt"), "\(error)")
        }
        var bass = bandsOnly
        bass.preference = Preference(bass: 2)
        XCTAssertThrowsError(try Exporter.render(bass, as: .eqmac, header: header))
    }

    // MARK: - CamillaDSP

    /// Just enough YAML for our own output: the filters mapping in order, then the pipeline steps.
    private func readCamilla(_ text: String) -> (filters: [String: [String: String]], order: [String], pipeline: [(channel: String, names: [String])]) {
        var filters: [String: [String: String]] = [:], order: [String] = []
        var pipeline: [(channel: String, names: [String])] = []
        var section = "", current = ""
        for line in text.split(separator: "\n").map(String.init) where !line.hasPrefix("#") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count
            if indent == 0 { section = trimmed; continue }
            if section == "filters:" {
                if indent == 2 { current = String(trimmed.dropLast()); order.append(current); filters[current] = [:]; continue }
                let parts = trimmed.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, !parts[1].isEmpty { filters[current]![indent == 4 ? "kind" : parts[0]] = parts[1] }
            } else if trimmed == "- type: Filter" {
                pipeline.append(("", []))
            } else if trimmed.hasPrefix("channel: ") {
                pipeline[pipeline.count - 1].channel = String(trimmed.dropFirst("channel: ".count))
            } else if trimmed.hasPrefix("- ") {
                pipeline[pipeline.count - 1].names.append(String(trimmed.dropFirst(2)))
            }
        }
        return (filters, order, pipeline)
    }

    func testCamillaFiltersAreTheEngineBands() throws {
        let yaml = readCamilla(try Exporter.render(full, as: .camilla, header: header))
        XCTAssertEqual(yaml.order.first, "eq_preamp")
        XCTAssertEqual(yaml.filters["eq_preamp"], ["kind": "Gain", "gain": "-6.3"])
        let types: [String: FilterType] = ["Peaking": .peak, "Lowshelf": .lowShelf, "Highshelf": .highShelf, "Lowpass": .lowPass,
                                           "Highpass": .highPass, "Notch": .notch, "Bandpass": .bandPass]
        let biquads = try yaml.order.dropFirst().map { name -> Filter in
            let p = try XCTUnwrap(yaml.filters[name])
            XCTAssertEqual(p["kind"], "Biquad")
            return Filter(type: try XCTUnwrap(types[p["type"] ?? ""]), frequency: Double(p["freq"]!)!,
                          gain: p["gain"].map { Double($0)! } ?? 0, q: Double(p["q"]!)!)
        }
        sameSound(biquads, engineFilters(full))
        XCTAssertEqual(yaml.order.count, Set(yaml.order).count)
        XCTAssertTrue(yaml.order.contains("eq_band_1khz") && yaml.order.contains("eq_filter_7") && yaml.order.contains("eq_bass_shelf")
            && yaml.order.contains("eq_tilt_4"), "\(yaml.order)")
        XCTAssertEqual(yaml.pipeline.map(\.channel), ["0", "1"])
        XCTAssertEqual(yaml.pipeline.map(\.names), [yaml.order, yaml.order])
    }

    func testCamillaSkipsAZeroPreamp() throws {
        var profile = bandsOnly
        profile.preamp = 0
        let yaml = readCamilla(try Exporter.render(profile, as: .camilla, header: header))
        XCTAssertEqual(yaml.order.count, 10)
        XCTAssertFalse(yaml.order.contains("eq_preamp"))
    }

    // MARK: - JSON

    func testJSONRoundTripIsExact() throws {
        let text = try Exporter.render(full, as: .json, header: header)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: Data(text.utf8)), full)
    }
}
