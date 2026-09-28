import XCTest
@testable import eq

final class CamillaDSPFormatTests: XCTestCase {
    private func parse(_ text: String) throws -> ImportResult { try EQFormats.parse(Data(text.utf8)) }

    func testPipelineChannelZeroIsImportedAndTheRestNamed() throws {
        let r = try EQFormats.parse(try formatFixture("CamillaDSP headless-camilladsp config.yml"))
        XCTAssertEqual(r.format, "CamillaDSP config")
        XCTAssertEqual(r.preamp, 0)
        XCTAssertEqual(r.filters.count, 15)
        XCTAssertEqual(r.filters.first, Filter(type: .peak, frequency: 92, gain: -5.72, q: 2.19))
        XCTAssertEqual(r.filters.last, Filter(type: .peak, frequency: 7486, gain: -4.47, q: 1))
        XCTAssertEqual(r.warnings, [
            "pipeline Mixer steps ignored",
            "filter \u{201C}convolution_left\u{201D}: skipped, Conv filters have no equal in eq",
            "filter \u{201C}convolution_right\u{201D}: skipped, Conv filters have no equal in eq",
            "left and right channels differ; imported the left channel (channel 0)",
        ])
    }

    /// `channel: n` (CamillaDSP 2.x) and a `channels:` list (3.0 on) both route a step; a step with
    /// neither, or `channels: null`, runs on every channel, and an empty list on none.
    func testPipelineStepsOfEveryCamillaVersionRoute() throws {
        let filters = """
            filters:
              a: {type: Biquad, parameters: {type: Peaking, freq: 100, gain: 1, q: 1}}
              b: {type: Biquad, parameters: {type: Peaking, freq: 200, gain: 2, q: 1}}
              c: {type: Biquad, parameters: {type: Peaking, freq: 300, gain: 3, q: 1}}
            pipeline:

            """
        let steps: [(String, [Double], Bool)] = [
            ("  - {type: Filter, channel: 0, names: [a]}\n  - {type: Filter, channel: 1, names: [a]}", [100], false),
            ("  - type: Filter\n    channels: [0, 1]\n    names:\n      - a\n      - b", [100, 200], false),
            ("  - type: Filter\n    channels:\n      - 1\n      - 0\n    names: [b]", [200], false),
            ("  - {type: Filter, names: [c]}\n  - {type: Filter, channels: null, names: [a]}", [300, 100], false),
            ("  - {type: Filter, channels: [], names: [b]}\n  - {type: Filter, channels: [0], names: [a]}", [100], true),
            ("  - {type: Filter, channels: [0, 1], bypassed: True, names: [b]}\n  - {type: Filter, channels: [0, 1], names: [a]}", [100], false),
        ]
        for (pipeline, frequencies, differ) in steps {
            let r = try parse(filters + pipeline + "\n")
            XCTAssertEqual(r.filters.map(\.frequency), frequencies, pipeline)
            XCTAssertEqual(r.warnings.contains("left and right channels differ; imported the left channel (channel 0)"), differ, pipeline)
        }
    }

    func testEveryBiquadCamillaDefinesIsReadAsItsSourceComputesIt() throws {
        let r = try EQFormats.parse(try formatFixture("CamillaDSP all_biquads.yml"))
        XCTAssertEqual(r.filters.map(\.type), [.highPass, .lowPass, .highShelf, .highShelf, .lowShelf, .lowShelf, .peak, .peak, .notch, .notch, .bandPass, .bandPass])
        XCTAssertEqual(r.filters[2], Filter(type: .highShelf, frequency: 1000, gain: -12, q: try XCTUnwrap(ImportCheck.shelfQ(slope: 6, gain: -12))))
        XCTAssertEqual(r.filters[3].q, 0.6)
        // bandwidth warps at the config's own 44.1 kHz, as biquad.rs does.
        XCTAssertEqual(r.filters[7].q, APOFormat.qFromBandwidth(2, frequency: 1000, sampleRate: 44100), accuracy: 1e-12)
        XCTAssertEqual(r.filters[11].q, APOFormat.qFromBandwidth(1.2, frequency: 1000, sampleRate: 44100), accuracy: 1e-12)
        XCTAssertEqual(r.warnings.first, "no pipeline: imported every filter under filters:, in order")
        XCTAssertEqual(r.warnings.count, 18)
        XCTAssertTrue(r.warnings.contains("filter \u{201C}free\u{201D}: skipped, Free biquads are not supported"))
    }

    func testGainFiltersAreThePreampAndFlowStyleAndCommentsRead() throws {
        let r = try parse("""
        ---
        devices: {samplerate: 48000, chunksize: 1024}   # flow mapping
        filters:
          preamp:
            type: Gain
            parameters: {gain: -6, inverted: false}
          half:
            type: Gain
            parameters:
              gain: 0.5
              scale: linear
          'bass shelf':
            type: Biquad
            parameters: { type: Lowshelf, freq: 105, gain: 5.5, q: 0.71 }
          "peak #1":
            type: Biquad
            parameters:
              type: Peaking
              freq: 1000
              gain: -3
              q: 1.41
          loud:
            type: Loudness
            parameters: {reference_level: -25}
        pipeline:
        - type: Filter
          channels: [0, 1]
          names: [preamp, half, 'bass shelf', "peak #1", missing]
        - type: Filter
          channel: 1
          bypassed: true
          names: [loud]
        """)
        XCTAssertEqual(r.preamp, -6 + 20 * log10(0.5), accuracy: 1e-12)
        XCTAssertEqual(r.filters, [
            Filter(type: .lowShelf, frequency: 105, gain: 5.5, q: 0.71),
            Filter(type: .peak, frequency: 1000, gain: -3, q: 1.41),
        ])
        XCTAssertEqual(r.warnings, ["filter \u{201C}missing\u{201D}: skipped, is not defined under filters:"])
    }

    func testBadNumbersAndBadYAMLAreRefusedNotTrapped() throws {
        let r = try parse("""
        filters:
          a: {type: Biquad, parameters: {type: Peaking, freq: .inf, gain: 1, q: 1}}
          b: {type: Biquad, parameters: {type: Peaking, freq: 1000, gain: 1e999, q: 1}}
          c: {type: Biquad, parameters: {type: Highshelf, freq: 1000, gain: 20, slope: 30}}
          d: {type: Biquad, parameters: {type: Peaking, freq: 1000, gain: 1}}
          e: {type: Biquad, parameters: {type: Peaking, freq: 1000, gain: 1, q: 0.5}}
          g: {type: Gain, parameters: {gain: 0, scale: linear}}
        pipeline:
          - {type: Filter, channel: 0, names: [a, b, c, d, e, g]}
          - {type: Filter, channel: 1, names: [e]}
        """)
        XCTAssertEqual(r.filters, [Filter(type: .peak, frequency: 1000, gain: 1, q: 0.5)])
        XCTAssertEqual(r.warnings.count, 5)
        XCTAssertThrowsError(try parse("filters:\n\tpeak: {}\npipeline:\n")) {
            guard case .nothingUsable(let reasons) = $0 as? ImportError else { return XCTFail("\($0)") }
            XCTAssertTrue(reasons[0].contains("tab"))
        }
        for text in ["filters:\n  a: &x {type: Gain}\npipeline:", "filters:\n  a: |\n    x\npipeline:", "filters:\n  a: {type: [Gain\npipeline:",
                     "filters:\n  a:\n b: 1\npipeline:", "filters:\npipeline: " + String(repeating: "[", count: 5000),
                     "filters:\n" + (1...200).map { String(repeating: " ", count: $0) + "k\($0):" }.joined(separator: "\n") + "\npipeline:"] {
            XCTAssertThrowsError(try parse(text), text.prefix(40).description)
        }
    }

    func testYAMLSubsetShapes() throws {
        let doc = try YAML.parse("""
        a: 1
        b:
          - x
          - k: v   # comment
            m: 'quoted # not a comment'
          -
            - nested
        c: [1, "two, three", {d: e}]
        e:
        """)
        XCTAssertEqual(doc["a"], .scalar("1"))
        XCTAssertEqual(doc["b"]?.list?.count, 3)
        XCTAssertEqual(doc["b"]?.list?[1]["m"], .scalar("quoted # not a comment"))
        XCTAssertEqual(doc["b"]?.list?[2], .list([.scalar("nested")]))
        XCTAssertEqual(doc["c"], .list([.scalar("1"), .scalar("two, three"), .map([(key: "d", value: .scalar("e"))])]))
        XCTAssertEqual(doc["e"], .scalar(""))
        XCTAssertNil(YAML.scalar("inf").number)
        XCTAssertNil(YAML.scalar("nan").number)
        XCTAssertEqual(YAML.scalar("-1.5e2").number, -150)
    }
}

final class FormatSniffTests: XCTestCase {
    static let fixtures: [(file: String, format: any EQFormat.Type)] = [
        ("Sony WH-1000XM4 ParametricEQ.txt", APOFormat.self), ("Sony WH-1000XM4 GraphicEQ.txt", APOFormat.self),
        ("Sony WH-1000XM4 FixedBandEQ.txt", APOFormat.self), ("REW Generic filters.txt", APOFormat.self),
        ("APO config reference example.txt", APOFormat.self), ("SoundSource Sample-Profile.txt", APOFormat.self),
        ("eqMac Advanced presets.json", EqMacFormat.self), ("eqMac Expert presets.json", EqMacFormat.self),
        ("Poweramp PA-CEQ 3.0.json", PowerampFormat.self), ("EasyEffects Perfect EQ.json", EasyEffectsFormat.self),
        ("Peace Bass Boost 2.peace", PeaceFormat.self), ("Peace Equalizer 15 Band with HPF and LPF.peace", PeaceFormat.self),
        ("Peace Tilt filter 10 dB down.peace", PeaceFormat.self), ("Peace Chu Moy Crossfeed Simulation (by commands).peace", PeaceFormat.self),
        ("CamillaDSP headless-camilladsp config.yml", CamillaDSPFormat.self), ("CamillaDSP all_biquads.yml", CamillaDSPFormat.self),
    ]

    func testEveryFixtureIsSniffedAsItsOwnFormatAndNoOther() throws {
        XCTAssertEqual(Set(Self.fixtures.map { "\($0.format)" }), Set(EQFormats.all.map { "\($0)" }))
        for (file, format) in Self.fixtures {
            let data = try formatFixture(file)
            let sniffed = EQFormats.all.filter { $0.sniff(data, filename: nil) }.map { "\($0)" }
            XCTAssertEqual(sniffed, ["\(format)"], file)
            XCTAssertNoThrow(try EQFormats.parse(data), file)
        }
        let camillaGain = Data("filters:\n  preamp:\n    type: Gain\n    parameters: {gain: -3}\n  Filter1: {type: Biquad, parameters: {type: Peaking, freq: 100, gain: 1, q: 1}}\npipeline:\n  - {type: Filter, channel: 0, names: [preamp, Filter1]}\n".utf8)
        XCTAssertEqual(EQFormats.all.filter { $0.sniff(camillaGain, filename: nil) }.map { "\($0)" }, ["\(CamillaDSPFormat.self)"])
    }

    /// APO text however it is typed (case, spacing, CRLF, UTF-16, other formats' words in comments)
    /// is APO's alone; text another sniffer also claims still imports as APO when that parse fails.
    func testUnusualAPOTextIsNotStolen() throws {
        let only = [
            "  preamp: -3 dB\r\n\tfilter 1 : on pk fc 100 hz gain 3 db q 1\r\n",
            "Filter1: ON PK Fc 1000 Hz Gain -3 dB Q 1",
            "# filters:\n# pipeline:\n# type: Biquad\n# [Gains]\nChannel: L\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1",
            "[not a section]\nPreamp: -2 dB\nFilter: ON LSC Fc 105 Hz Gain 3 dB Q 0.7",
            "GraphicEQ: 20 -1; 1000 0; 20000 -2",
            "Device: [Speakers]\nPreamp:-6dB\nFilter  1: ON  PK       Fc   1000 Hz  Gain  -3.0 dB  Q  1.00",
            "{ not JSON }\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1",
        ]
        for text in only {
            for data in [Data(text.utf8), try XCTUnwrap(text.data(using: .utf16))] {
                XCTAssertEqual(EQFormats.all.filter { $0.sniff(data, filename: nil) }.map { "\($0)" }, ["\(APOFormat.self)"], text)
                XCTAssertNoThrow(try EQFormats.parse(data), text)
            }
        }
        let shared = Data("filters:\nFilter: ON PK Fc 100 Hz Gain 1 dB Q 1\npipeline: none\n".utf8)
        XCTAssertEqual(EQFormats.all.filter { $0.sniff(shared, filename: nil) }.map { "\($0)" }, ["\(CamillaDSPFormat.self)", "\(APOFormat.self)"])
        XCTAssertEqual(try EQFormats.parse(shared).filters, [Filter(type: .peak, frequency: 100, gain: 1, q: 1)])
    }

    func testSoundSourceSampleIsAPOText() throws {
        let r = try EQFormats.parse(try formatFixture("SoundSource Sample-Profile.txt"))
        XCTAssertEqual(r.preamp, -7.9)
        XCTAssertEqual(r.filters.count, 10)
        XCTAssertEqual(r.filters[0], Filter(type: .peak, frequency: 210, gain: -4.9, q: 0.46))
        XCTAssertEqual(r.warnings, [])
    }

    func testTruncatedFixturesNeverTrap() throws {
        for (file, _) in Self.fixtures {
            let data = try formatFixture(file)
            for end in stride(from: 0, to: data.count, by: max(1, data.count / 150)) {
                _ = try? EQFormats.parse(data.prefix(end))
            }
        }
    }
}
