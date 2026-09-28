import XCTest
@testable import eq

final class PresetFormatTests: XCTestCase {
    private func parse(_ text: String) throws -> ImportResult { try EQFormats.parse(Data(text.utf8)) }

    // MARK: - EasyEffects

    func testEasyEffectsPresetTakesTheLeftBandsAndBothGains() throws {
        let r = try EQFormats.parse(try formatFixture("EasyEffects Perfect EQ.json"))
        XCTAssertEqual(r.format, "EasyEffects equalizer")
        XCTAssertEqual(r.preamp, -2)
        XCTAssertEqual(r.warnings, [])
        XCTAssertNil(r.bands)
        XCTAssertEqual(r.filters.count, 10)
        XCTAssertEqual(r.filters[0], Filter(type: .peak, frequency: 32, gain: 4, q: 1.504760237537245))
        XCTAssertEqual(r.filters[9].frequency, 16000)
    }

    private func easyEffects(split: Bool, right: String, bands: String, gains: String = #""input-gain": 1.5, "output-gain": -3"#) -> String {
        #"{"output": {"plugins_order": ["equalizer#0"], "equalizer#0": {\#(gains), "num-bands": 5, "split-channels": \#(split), "left": {\#(bands)}, "right": {\#(right)}}}}"#
    }

    func testEasyEffectsSkipsWhatHasNoEqualAndWarnsWhenSplitChannelsDiffer() throws {
        let bands = #"""
        "band0": {"frequency": 80, "gain": 3, "q": 0.7, "type": "Lo-shelf", "slope": "x1", "mute": false},
        "band1": {"frequency": 1000, "gain": 3, "q": 1, "type": "Resonance", "slope": "x1", "mute": false},
        "band2": {"frequency": 2000, "gain": 3, "q": 1, "type": "Bell", "slope": "x1", "mute": true},
        "band3": {"frequency": 30, "gain": 9, "q": 0.7, "type": "Hi-pass", "slope": "x2", "mute": false},
        "band4": {"frequency": 5000, "gain": 3, "q": 0, "type": "Bell", "slope": "x1", "mute": false}
        """#
        let r = try parse(easyEffects(split: true, right: "", bands: bands))
        XCTAssertEqual(r.preamp, -1.5)
        XCTAssertEqual(r.filters, [Filter(type: .lowShelf, frequency: 80, gain: 3, q: 0.7), Filter(type: .highPass, frequency: 30, gain: 0, q: 0.7)])
        XCTAssertEqual(r.warnings.count, 4)
        XCTAssertEqual(r.warnings.first, "left and right channels differ; imported the left channel")
        XCTAssertTrue(r.warnings.contains("band3: slope x2 imported as a single filter"))

        let linked = try parse(easyEffects(split: false, right: "", bands: bands))
        XCTAssertFalse(linked.warnings.contains { $0.contains("differ") })
        XCTAssertThrowsError(try parse(easyEffects(split: false, right: "", bands: bands, gains: #""input-gain": 20"#))) {
            XCTAssertEqual($0 as? ImportError, .preampOutOfRange(20))
        }
        XCTAssertThrowsError(try parse(easyEffects(split: false, right: "", bands: #""band0": {"type": "Allpass"}"#))) {
            guard case .nothingUsable = $0 as? ImportError else { return XCTFail("\($0)") }
        }
    }

    // MARK: - Peace

    func testPeaceShelfWithQIsTheShelfPeaceWritesAndItsPreamp() throws {
        let r = try EQFormats.parse(try formatFixture("Peace Bass Boost 2.peace"))
        XCTAssertEqual(r.format, "Peace")
        XCTAssertEqual(r.preamp, -4)
        XCTAssertEqual(r.warnings, [])
        // Filter5=14 is Peace's LSCQ, written as `LSC … Q`: a centred shelf with that Q.
        XCTAssertEqual(r.filters, [Filter(type: .lowShelf, frequency: 166, gain: 10, q: 0.4)])
    }

    func testPeacePassFiltersAreItsButterworthCascades() throws {
        let r = try EQFormats.parse(try formatFixture("Peace Equalizer 15 Band with HPF and LPF.peace"))
        XCTAssertEqual(r.warnings, [])
        XCTAssertEqual(r.filters.map(\.type), Array(repeating: .highPass, count: 4) + Array(repeating: .lowPass, count: 4))
        // Quality 8 is an eighth-order Butterworth: four biquads with Q 1/(2 sin((2k-1)π/16)).
        let expected = (1...4).map { 1 / (2 * sin(Double(2 * $0 - 1) * .pi / 16)) }.sorted()
        for (filter, q) in zip(r.filters.prefix(4), expected) { XCTAssertEqual(filter.q, q, accuracy: 1e-6) }
        XCTAssertEqual(r.filters[0].frequency, 20)
        XCTAssertEqual(r.filters[4].frequency, 20000)
    }

    func testPeaceSlopeShelvesAndCommandsGoThroughAPO() throws {
        let tilt = try EQFormats.parse(try formatFixture("Peace Tilt filter 10 dB down.peace"))
        XCTAssertEqual(tilt.preamp, -5)
        XCTAssertEqual(tilt.filters.map(\.type), [.lowShelf, .highShelf])
        XCTAssertEqual(tilt.filters[0].q, try XCTUnwrap(ImportCheck.shelfQ(slope: 2.73, gain: 19.3)), accuracy: 1e-9)

        let chuMoy = try EQFormats.parse(try formatFixture("Peace Chu Moy Crossfeed Simulation (by commands).peace"))
        XCTAssertEqual(chuMoy.preamp, -3.53)
        XCTAssertEqual(chuMoy.filters.map(\.type), [.highShelf])
        XCTAssertEqual(chuMoy.warnings, [
            "Copy: ignored, eq does not mix channels", "Delay: ignored, eq has no delay",
            "skipped 1 line for channels other than left and right",
        ])
    }

    func testPeaceSkipsBadSlidersByNameAndKeepsTheLeftGroup() throws {
        let r = try parse("""
        [General]
        PreAmp=-3
        Bass Gain=4
        [Speakers]
        SpeakerId0=0
        SpeakerTargets0=all
        SpeakerName0=All
        SpeakerId1=1
        SpeakerTargets1=L
        SpeakerName1=Left
        [Frequencies]
        Frequency1=100
        Frequency2=abc
        Frequency3=1000
        Frequency4=2000
        Frequency5=3000
        Frequency6=4000
        Frequency7=50
        [Gains]
        Gain1=3
        Gain3=2
        Gain4=-2
        Gain6=5
        [Filters]
        Filter3=7
        Filter4=99
        Filter7=11
        [Qualities]
        Quality1=1
        Quality7=40
        [Disabled]
        Disabled6=1
        [Frequencies1]
        Frequency1=500
        [Gains1]
        Gain1=-6
        """)
        XCTAssertEqual(r.preamp, -3)
        XCTAssertEqual(r.filters, [Filter(type: .peak, frequency: 100, gain: 3, q: 1), Filter(type: .peak, frequency: 500, gain: -6, q: 1.41)])
        XCTAssertEqual(r.warnings, [
            "Peace effects ignored: Bass Gain",
            "slider 2: skipped, frequency \u{201C}abc\u{201D} is not a number",
            "slider 4: skipped, unknown filter type 99",
            "slider 7: skipped, order 40 is steeper than 16",
            "slider 3: skipped a filter: an all-pass filter is not supported",
            "left and right channels differ; imported the left channel",
        ])
    }

    func testPeaceGraphicModeSetsTheBandsAndRefusesAPreampOutOfRange() throws {
        let sliders = Config.bandFrequencies.enumerated().map { "Frequency\($0.offset + 1)=\(Int($0.element))" }.joined(separator: "\n")
        let gains = (1...10).map { "Gain\($0)=\($0 - 5)" }.joined(separator: "\n")
        let r = try parse("[General]\nGraphicEQ=1\nPreAmp=-5\n[Frequencies]\n\(sliders)\n[Gains]\n\(gains)\n")
        // Graphic mode writes the sliders as a GraphicEQ: line, the curve APO then plays.
        // A staircase is not ten peaks' shape; the fit gets within a dB at every centre, closer on average.
        let misses = Config.bandFrequencies.enumerated().map { abs(heard(r, at: $0.element) - (Double($0.offset - 4) - 5)) }
        XCTAssertLessThan(misses.max()!, 1.5, "\(misses)")
        XCTAssertLessThan(misses.reduce(0, +) / 10, 0.6, "\(misses)")
        XCTAssertEqual(r.format, "Peace (10 bands)")
        XCTAssertThrowsError(try parse("[General]\nPreAmp=25\n[Frequencies]\nFrequency1=100\n[Gains]\nGain1=1\n")) {
            XCTAssertEqual($0 as? ImportError, .preampOutOfRange(25))
        }
        XCTAssertThrowsError(try parse("[Frequencies]\nFrequency1=100\n")) {
            guard case .nothingUsable = $0 as? ImportError else { return XCTFail("\($0)") }
        }
    }
}
