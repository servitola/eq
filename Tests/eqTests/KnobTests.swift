import XCTest
@testable import eq

final class KnobTests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-knob-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-28" })
        _ = CLI.run(["init"], context: context)
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func run(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private func knobs(_ uid: String = "BUILTIN") throws -> [String: Double]? {
        try XCTUnwrap(try context.store.load().devices[uid]).instruments
    }

    private func instrument(_ name: String) -> Instrument { Instruments.named(name)! }

    private func response(_ band: EQBand, at frequency: Double, rate: Double = 48000) -> Double {
        BiquadCoefficients.make(type: band.type, frequency: band.frequency, gainDB: band.gain, q: band.q, sampleRate: rate)
            .magnitudeDB(at: frequency, sampleRate: rate)
    }

    // MARK: - The table

    func testEveryCharacterRangeIsOneOfTheInstrumentsOwn() {
        let expected = ["kick": "thump", "bass": "growl/attack", "snare": "crack", "guitar": "bite",
                        "piano": "brightness", "voice": "presence", "cymbals": "shimmer", "air": "sparkle"]
        for instrument in Instruments.all {
            XCTAssertEqual(instrument.character, expected[instrument.name], instrument.name)
            XCTAssertTrue(instrument.ranges.contains(instrument.characterRange), instrument.name)
        }
        XCTAssertEqual(instrument("voice").characterRange, HzRange(name: "presence", low: 2000, high: 5000))
        XCTAssertEqual(instrument("kick").characterRange, HzRange(name: "thump", low: 50, high: 100))
        XCTAssertEqual(instrument("snare").characterRange, HzRange(name: "crack", low: 4000, high: 6000))
    }

    func testAKnobIsOnePeakAtTheGeometricCentreAsWideAsTheRange() {
        let voice = instrument("voice").knob(gain: 3)
        XCTAssertEqual(voice.type, .peak)
        XCTAssertEqual(voice.frequency, (2000.0 * 5000).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(voice.q, voice.frequency / 3000, accuracy: 1e-12)
        XCTAssertEqual(instrument("kick").knob(gain: 1).q, 2.0.squareRoot(), accuracy: 1e-12, "one octave is the graphic bands' Q")
        XCTAssertEqual(response(voice, at: voice.frequency), 3, accuracy: 0.01)
        XCTAssertEqual(response(voice, at: 200), 0, accuracy: 0.1)
    }

    func testEveryKnobPassesTheStabilityGuardAtEveryEnd() {
        for instrument in Instruments.all {
            for gain in [Config.gainRange.lowerBound, 0.5, Config.gainRange.upperBound] {
                let band = instrument.knob(gain: gain)
                let filter = Filter(type: band.type, frequency: band.frequency, gain: band.gain, q: band.q)
                for rate in [44100.0, 48000, 96000, 192000] {
                    XCTAssertNil(Config.firstUnstableFilter([filter], sampleRate: rate), "\(instrument.name) \(gain) dB at \(rate)")
                }
            }
        }
    }

    func testKnobsRunAfterThePreferenceInTableOrderAndOnlyWhenSet() {
        var profile = Profile(name: nil, preamp: 0, bands: Profile.flat.bands, preference: Preference(bass: 2))
        XCTAssertEqual(profile.engineBands.count, 11)
        profile.instruments = ["voice": 3, "kick": -2, "air": 0]
        XCTAssertEqual(profile.engineBands.count, 13)
        XCTAssertEqual(profile.engineBands[11], instrument("kick").knob(gain: -2))
        XCTAssertEqual(profile.engineBands[12], instrument("voice").knob(gain: 3))
        XCTAssertEqual(profile.engineBandLabel(10), "bass shelf")
        XCTAssertEqual(profile.engineBandLabel(12), "voice boost")
    }

    // MARK: - Config

    func testOldConfigLoadsAndAnEmptyLayerIsNotWritten() throws {
        let old = #"{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0]}"#
        XCTAssertNil(try JSONDecoder().decode(Profile.self, from: Data(old.utf8)).instruments)
        let encoded = String(decoding: try JSONEncoder().encode(Profile.flat), as: UTF8.self)
        XCTAssertFalse(encoded.contains("instruments"))
    }

    func testAHandEditedUnknownNameLoadsAndRunsNothing() throws {
        var raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: context.store.url)) as? [String: Any])
        var profile = try XCTUnwrap(raw["default"] as? [String: Any])
        profile["instruments"] = ["vocals": 40, "voice": 2]
        raw["default"] = profile
        try JSONSerialization.data(withJSONObject: raw).write(to: context.store.url)
        let loaded = try context.store.load().default
        XCTAssertEqual(loaded.unknownInstruments, ["vocals"])
        XCTAssertEqual(loaded.knobs.map(\.instrument.name), ["voice"])
        XCTAssertEqual(loaded.engineBands.count, 11)
    }

    func testAKnownKnobOutOfRangeIsRejected() throws {
        var config = try context.store.load()
        config.default.instruments = ["voice": 13]
        XCTAssertThrowsError(try config.validate()) {
            XCTAssertEqual($0 as? ConfigError, .preferenceOutOfRange("default", "voice boost 13.0 dB (-12…12 dB)"))
        }
    }

    // MARK: - CLI

    func testBoostSetsShowsAndZeroRemoves() throws {
        let set = run("boost", "voice", "+3")
        XCTAssertEqual(set.exitCode, 0, set.output)
        XCTAssertTrue(set.output.hasPrefix("boost voice +3.0 dB"), set.output)
        run("boost", "KCK", "-2,5")
        XCTAssertEqual(try knobs(), ["voice": 3, "kick": -2.5])
        XCTAssertTrue(run().output.contains("boost: kick -2.5 voice +3"), run().output)
        run("boost", "voice", "0")
        run("boost", "kick", "0")
        XCTAssertNil(try knobs())
        XCTAssertFalse(run().output.contains("boost"))
    }

    func testUnknownInstrumentAndBadGainsAreRefused() throws {
        let unknown = run("boost", "vocals", "3")
        XCTAssertEqual(unknown.exitCode, 2)
        XCTAssertTrue(unknown.output.contains("unknown instrument \"vocals\" — use one of kick bass snare"), unknown.output)
        XCTAssertEqual(run("boost", "voice", "13").exitCode, 2)
        XCTAssertEqual(run("boost", "voice", "loud").exitCode, 2)
        XCTAssertEqual(run("boost", "voice").exitCode, 2)
        XCTAssertNil(try knobs())
    }

    func testBoostAloneListsEveryInstrument() throws {
        run("boost", "snare", "4")
        let listed = run("boost")
        XCTAssertEqual(listed.exitCode, 0)
        let lines = listed.output.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 1 + Instruments.all.count, listed.output)
        XCTAssertTrue(lines.contains { $0.contains("snare") && $0.contains("crack 4kHz–6kHz") && $0.hasSuffix("+4.0 dB") }, listed.output)
        XCTAssertTrue(lines.contains { $0.contains("voice") && $0.hasSuffix("+0.0 dB") }, listed.output)

        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(CLI.run(["boost", "--json"], context: context).output.utf8))
            as? [String: Any])
        let rows = try XCTUnwrap(json["knobs"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 8)
        let snare = try XCTUnwrap(rows.first { $0["instrument"] as? String == "snare" })
        XCTAssertEqual(snare["gain"] as? Double, 4)
        XCTAssertEqual((snare["range"] as? [String: Any])?["low"] as? Double, 4000)
    }

    func testDeviceOptionAndJSON() throws {
        let result = CLI.run(["boost", "--device", "jbl", "kick", "2", "--json"], context: context)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any], result.output)
        XCTAssertEqual((json["profile"] as? [String: Any])?["instruments"] as? [String: Double], ["kick": 2])
        XCTAssertEqual(try knobs("BT-1"), ["kick": 2])
    }

    func testPresetsCarryFlatDropsAndHistoryShows() throws {
        run("boost", "voice", "3")
        run("preset", "save", "vox")
        XCTAssertEqual(try context.store.load().presets?["vox"]?.instruments, ["voice": 3])
        run("flat")
        XCTAssertNil(try knobs())
        run("preset", "use", "vox")
        XCTAssertEqual(try knobs(), ["voice": 3])
        run("boost", "voice", "4")
        XCTAssertTrue(run().output.contains("vox*"), "a turned knob is a changed curve")
        XCTAssertTrue(run("history").output.contains("boost voice +4"))
    }

    func testExportWritesKnobsAsPeaks() throws {
        run("flat")
        run("boost", "kick", "3")
        let apo = run("export").output
        XCTAssertTrue(apo.contains("Filter 11: ON PK Fc \(Exporter.number(50 * 2.0.squareRoot())) Hz Gain 3 dB Q \(Exporter.number(2.0.squareRoot()))"), apo)
        XCTAssertTrue(run("export", "--format", "camilla").output.contains("eq_kick_boost:"))
        let eqmac = run("export", "--format", "eqmac")
        XCTAssertEqual(eqmac.exitCode, 1)
        XCTAssertTrue(eqmac.output.contains("instrument boosts"), eqmac.output)
    }

    func testOwnJSONRoundTripsTheKnobs() throws {
        run("boost", "voice", "3")
        let file = dir.appendingPathComponent("vox.json")
        XCTAssertEqual(run("export", "--format", "json", "--out", file.path).exitCode, 0)
        run("flat")
        let imported = run("import", file.path)
        XCTAssertEqual(imported.exitCode, 0, imported.output)
        XCTAssertEqual(try knobs(), ["voice": 3])

        let odd = #"{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0],"instruments":{"vocals":2,"kick":30,"snare":1}}"#
        let result = try EQJSONFormat.parse(Data(odd.utf8))
        XCTAssertEqual(result.instruments, ["snare": 1])
        XCTAssertEqual(result.warnings, ["instrument kick: skipped, boost out of range", "instrument vocals: skipped, eq has no such instrument"])
    }
}
