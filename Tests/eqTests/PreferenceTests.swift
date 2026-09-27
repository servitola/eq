import XCTest
@testable import eq

final class PreferenceTests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-pref-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-27" })
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

    private func layer(_ uid: String = "BUILTIN") throws -> Preference? {
        try XCTUnwrap(try context.store.load().devices[uid]).preference
    }

    /// The summed response of `bands` at 48 kHz, through the same Float32 coefficients the engine runs.
    private func response(_ bands: [EQBand], at frequency: Double) -> Double {
        bands.reduce(0) {
            $0 + BiquadCoefficients.make(type: $1.type, frequency: $1.frequency, gainDB: $1.gain, q: $1.q, sampleRate: 48000)
                .magnitudeDB(at: frequency, sampleRate: 48000)
        }
    }

    func testBassIsAutoEqsLowShelf() {
        let bands = Preference(bass: 6).engineBands.map(\.band)
        XCTAssertEqual(bands, [EQBand(type: .lowShelf, frequency: 105, gain: 6, q: 0.7)])
        XCTAssertEqual(response(bands, at: 20), 6, accuracy: 0.3)
        XCTAssertEqual(response(bands, at: 105), 3, accuracy: 0.05)
        XCTAssertEqual(response(bands, at: 1000), 0, accuracy: 0.1)
    }

    func testTrebleIsAutoEqsHighShelf() {
        let bands = Preference(treble: -4).engineBands.map(\.band)
        XCTAssertEqual(bands, [EQBand(type: .highShelf, frequency: 10000, gain: -4, q: 0.7)])
        XCTAssertEqual(response(bands, at: 10000), -2, accuracy: 0.05)
        XCTAssertEqual(response(bands, at: 1000), 0, accuracy: 0.1)
        XCTAssertLessThan(response(bands, at: 20000), -3)
    }

    func testTiltFollowsAutoEqsLineAcrossTheAudibleBand() {
        for slope in [1.2, -0.5, 0.3] {
            let bands = Preference(tilt: slope).engineBands.map(\.band)
            XCTAssertEqual(bands.count, 4)
            for step in 0...60 {
                let f = 20 * pow(1000, Double(step) / 60)
                let line = slope * log2(f / Preference.tiltCentre)
                XCTAssertEqual(response(bands, at: f), line, accuracy: 0.26 * abs(slope) + 0.01, "\(slope) dB/oct at \(f) Hz")
            }
            XCTAssertEqual(response(bands, at: Preference.tiltCentre), 0, accuracy: 0.05)
        }
    }

    func testEngineAppendsOnlyTheSetShelvesAfterFilters() {
        var profile = Profile(name: nil, preamp: 0, bands: Profile.flat.bands, filters: [Filter(type: .peak, frequency: 3000, gain: -2, q: 2)])
        XCTAssertEqual(profile.engineBands.count, 11)
        profile.preference = Preference(bass: 3, tilt: 0.5)
        XCTAssertEqual(profile.engineBands.count, 16)
        XCTAssertEqual(profile.engineBands[11], EQBand(type: .lowShelf, frequency: 105, gain: 3, q: 0.7))
        XCTAssertEqual(profile.engineBandLabel(10), "filter 1")
        XCTAssertEqual(profile.engineBandLabel(11), "bass shelf")
        XCTAssertEqual(profile.engineBandLabel(12), "tilt")
    }

    func testCommandsSetAndClearTheLayer() throws {
        XCTAssertEqual(run("bass", "+3").exitCode, 0)
        XCTAssertEqual(run("treble", "-2").exitCode, 0)
        let tilt = run("tilt", "-0,5")
        XCTAssertEqual(tilt.exitCode, 0, tilt.output)
        XCTAssertTrue(tilt.output.hasPrefix("tilt -0.5 dB/octave"), tilt.output)
        XCTAssertEqual(try layer(), Preference(bass: 3, treble: -2, tilt: -0.5))
        let shown = run().output
        XCTAssertTrue(shown.contains("preference: bass +3.0 dB  treble -2.0 dB  tilt -0.5 dB/oct"), shown)
        run("bass", "0")
        run("treble", "0")
        run("tilt", "0")
        XCTAssertNil(try layer())
        XCTAssertFalse(run().output.contains("preference"))
    }

    func testDeviceOptionAndJSON() throws {
        let result = CLI.run(["bass", "--device", "jbl", "4", "--json"], context: context)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any], result.output)
        let preference = try XCTUnwrap((json["profile"] as? [String: Any])?["preference"] as? [String: Any])
        XCTAssertEqual(preference["bass"] as? Double, 4)
        XCTAssertEqual(try layer("BT-1")?.bass, 4)
        XCTAssertNil(try layer())
    }

    func testRangesAreRefused() throws {
        XCTAssertEqual(run("bass", "13").exitCode, 2)
        XCTAssertEqual(run("treble", "loud").exitCode, 2)
        XCTAssertEqual(run("tilt", "1.5").exitCode, 2)
        XCTAssertEqual(run("tilt").exitCode, 2)
        XCTAssertNil(try layer())
        var config = try context.store.load()
        config.default.preference = Preference(tilt: 2)
        XCTAssertThrowsError(try config.validate()) {
            XCTAssertEqual($0 as? ConfigError, .preferenceOutOfRange("default", "tilt 2.0 dB/octave (-1.2…1.2 dB/octave)"))
        }
    }

    func testDecodingIsBackwardsCompatible() throws {
        let old = #"{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0]}"#
        XCTAssertNil(try JSONDecoder().decode(Profile.self, from: Data(old.utf8)).preference)
        let partial = #"{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0],"preference":{"bass":2}}"#
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: Data(partial.utf8)).preference, Preference(bass: 2))
        let encoded = String(decoding: try JSONEncoder().encode(Profile.flat), as: UTF8.self)
        XCTAssertFalse(encoded.contains("preference"))
    }

    func testPresetsCarryTheLayer() throws {
        run("bass", "3")
        XCTAssertEqual(run("preset", "save", "warm").exitCode, 0)
        XCTAssertEqual(try context.store.load().presets?["warm"]?.preference, Preference(bass: 3))
        run("flat")
        XCTAssertNil(try layer())
        run("preset", "use", "warm")
        XCTAssertEqual(try layer(), Preference(bass: 3))
        run("bass", "4")
        XCTAssertTrue(run().output.contains("warm*"))
    }

    func testWatchKeysStepBassAndTreble() throws {
        XCTAssertEqual(WatchKeys.action(for: "b"), .bass(0.5))
        XCTAssertEqual(WatchKeys.action(for: "B"), .bass(-0.5))
        XCTAssertEqual(WatchKeys.action(for: "и"), .bass(0.5))
        XCTAssertEqual(WatchKeys.action(for: "И"), .bass(-0.5))
        XCTAssertEqual(WatchKeys.action(for: "t"), .treble(0.5))
        XCTAssertEqual(WatchKeys.action(for: "T"), .treble(-0.5))
        XCTAssertEqual(WatchKeys.action(for: "е"), .treble(0.5))
        XCTAssertEqual(WatchKeys.action(for: "Е"), .treble(-0.5))

        let session = CLI.WatchSession(context)
        try session.apply(.bass(0.5))
        try session.apply(.bass(0.5))
        try session.apply(.treble(-0.5))
        XCTAssertEqual(try layer(), Preference(bass: 1, treble: -0.5))
        XCTAssertEqual(session.preference(), Preference(bass: 1, treble: -0.5))
        try session.apply(.undo)
        try session.apply(.undo)
        try session.apply(.undo)
        XCTAssertNil(try layer())
        run("bass", "12")
        try session.apply(.bass(0.5))
        XCTAssertEqual(try layer()?.bass, 12)
    }

    func testWatchHeaderShowsTheLayer() {
        let f = MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: [], out: [], peak: -6, limiting: false,
                           gains: [], preamp: 0, enabled: true)
        let layout = WatchLayout.fit(cols: 120, rows: 30)
        XCTAssertTrue(Watch.frame(f, layout: layout, preference: Preference(bass: 3, treble: -2))[0]
            .contains("preamp +0.0 dB · bass +3 treble -2 · peak"))
        XCTAssertFalse(Watch.frame(f, layout: layout)[0].contains("bass"))
    }
}
