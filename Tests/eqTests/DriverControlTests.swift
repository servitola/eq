import EQCore
import XCTest
@testable import eq

/// The settings record eq sends the HAL plug-in, checked with the decoder the plug-in itself runs.
final class DriverControlTests: XCTestCase {
    private static let rich = Profile(
        name: "rich", preamp: -4.5, bands: [3, 2, 1, 0, -1, -2, 0, 1, 2, 3],
        filters: [Filter(type: .lowShelf, frequency: 105, gain: 4, q: 0.7), Filter(type: .highPass, frequency: 25, gain: 0, q: 0.5),
                  Filter(type: .peak, frequency: 3150, gain: -2.5, q: 4)],
        preference: Preference(bass: 3, treble: -2, tilt: 0.6), instruments: [Instruments.all[0].name: 4],
        dynamics: Dynamics(comp: .gentle, color: .init(kind: .tube, amount: 0.3)))

    /// Every extreme the config accepts, so the plug-in never refuses what the daemon would play.
    private static let extreme = Profile(
        name: "extreme", preamp: Config.preampRange.lowerBound, bands: Config.bandFrequencies.indices.map { $0 % 2 == 0 ? 12 : -12 },
        filters: [Filter(type: .peak, frequency: Config.filterFrequencyRange.lowerBound, gain: 30, q: 0.1),
                  Filter(type: .notch, frequency: Config.filterFrequencyRange.upperBound, gain: -30, q: 30),
                  Filter(type: .bandPass, frequency: 1000, gain: 0, q: Config.filterQRange.upperBound)],
        preference: Preference(bass: 12, treble: -12, tilt: Preference.tiltRange.upperBound),
        instruments: Dictionary(uniqueKeysWithValues: Instruments.all.map { ($0.name, 12.0) }),
        dynamics: Dynamics(comp: .night, color: .init(kind: .tape, amount: 1)))

    private func decode(_ record: Data) -> (status: eqc_blob_status, settings: eqc_settings, uid: String, serial: UInt64) {
        var settings = eqc_settings()
        var uid = [CChar](repeating: 0, count: Int(EQC_BLOB_UID_CAPACITY))
        var serial: UInt64 = 0
        let status = record.withUnsafeBytes { eqc_blob_decode($0.baseAddress!, $0.count, &settings, &uid, &serial) }
        return (status, settings, String(cString: uid), serial)
    }

    func testRecordRoundTripsThroughThePluginsDecoder() throws {
        for profile in [Profile.flat, Self.rich, Self.extreme] {
            for enabled in [true, false] {
                let settings = EQProcessor.settings(profile: profile, enabled: enabled)
                let record = try XCTUnwrap(DriverControl.record(settings, targetUID: "EB-06-EF-24-61-CF:output", serial: 1_727_000_000_123))
                let decoded = decode(record)
                XCTAssertEqual(decoded.status, EQC_BLOB_OK, "\(profile.name ?? "flat")")
                XCTAssertEqual(decoded.uid, "EB-06-EF-24-61-CF:output")
                XCTAssertEqual(decoded.serial, 1_727_000_000_123)
                XCTAssertEqual(decoded.settings.bandCount, Int32(profile.engineBands.count))
                XCTAssertEqual(decoded.settings.bypassed, !enabled)
                XCTAssertEqual(DriverControl.record(decoded.settings, targetUID: decoded.uid, serial: decoded.serial), record)
            }
        }
    }

    /// The daemon's processor and the driver get the same settings for the same profile, so both
    /// modes play the same curve.
    func testTheDriverGetsWhatTheProcessorGets() throws {
        for profile in [Profile.flat, Self.rich, Self.extreme] {
            for enabled in [true, false] {
                let processor = EQProcessor()
                processor.apply(profile: profile, enabled: enabled)
                let played = try XCTUnwrap(processor.settings)
                XCTAssertEqual(DriverControl.record(played, targetUID: "uid", serial: 1),
                               DriverControl.record(EQProcessor.settings(profile: profile, enabled: enabled), targetUID: "uid", serial: 1))
            }
        }
        let rich = EQProcessor.settings(profile: Self.rich, enabled: true)
        XCTAssertEqual(rich.compressor, EQC_COMPRESSOR_GENTLE)
        XCTAssertEqual(rich.colour, EQC_COLOUR_TUBE)
        XCTAssertEqual(rich.preampDB, -4.5)
        XCTAssertTrue(rich.limiterEnabled)
        XCTAssertEqual(rich.limiterCeilingDB, -1)
    }

    func testRecordNeedsAUIDThatFits() {
        let settings = EQProcessor.settings(profile: .flat, enabled: true)
        XCTAssertNil(DriverControl.record(settings, targetUID: "", serial: 1))
        XCTAssertNil(DriverControl.record(settings, targetUID: String(repeating: "x", count: 256), serial: 1))
        XCTAssertNotNil(DriverControl.record(settings, targetUID: String(repeating: "x", count: 255), serial: 1))
    }

    func testMeterFrameDecodes() throws {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: eqc_engine_size(), alignment: 16)
        defer { memory.deallocate() }
        let engine = OpaquePointer(memory)
        eqc_engine_init(engine, Config.bandFrequencies, Int32(Config.bandFrequencies.count))
        var frame = eqc_meter_frame()
        eqc_meter_frame_read(&frame, engine, Config.bandFrequencies, Int32(Config.bandFrequencies.count))
        let data = withUnsafeBytes(of: &frame) { Data($0) }
        let meter = try XCTUnwrap(DriverControl.meter(from: data))
        XCTAssertEqual(meter.frequencies, Config.bandFrequencies)
        XCTAssertEqual(meter.outputDB, Array(repeating: EQC_METER_FLOOR_DB, count: Config.bandFrequencies.count))
        XCTAssertEqual(meter.peakDB, EQC_METER_FLOOR_DB)
        XCTAssertFalse(meter.limiting)
        XCTAssertNil(DriverControl.meter(from: data.dropLast()))
        XCTAssertNil(DriverControl.meter(from: Data(count: data.count)))
    }

    func testSelectorsMatchThePlugin() {
        XCTAssertEqual(DriverControl.settingsSelector, 0x6571_5374)
        XCTAssertEqual(DriverControl.meterSelector, 0x6571_4D74)
        XCTAssertEqual(DriverControl.healthSelector, 0x6571_486C)
    }
}

final class DriverCLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!
    private var fake: FakeDriver!

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-driver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fake = FakeDriver()
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BT-1", "JBL Big") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-29" })
        context.driver = { [unowned self] in fake }
        var serial: UInt64 = 4241
        context.driverSerial = { serial += 1; return serial }
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    func testStatusPrintsTheHealthSorted() {
        let result = run("driver", "status")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output, """
        eqActive: no
        settingsSerial: 0
        settingsVersion: 1
        target: BUILTIN
        targetName: MacBook Pro Speakers
        writerRequirement: identifier "com.servitola.eq"
        """)
        let json = run("driver", "status", "--json").output
        XCTAssertTrue(json.contains("\"eqActive\" : false"), json)
    }

    /// Push sends the driver's target its own profile, not the default output's.
    func testPushSendsTheTargetsProfile() throws {
        XCTAssertEqual(run("set", "--device", "macbook", "1khz", "+4").exitCode, 0)
        XCTAssertEqual(run("comp", "night", "--device", "macbook").exitCode, 0)
        let result = run("driver", "push")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(result.output, "pushed the own profile of MacBook Pro Speakers to the driver; playing")
        let config = try context.store.load()
        let profile = try XCTUnwrap(config.devices["BUILTIN"])
        XCTAssertEqual(fake.written, [DriverControl.record(EQProcessor.settings(profile: profile, enabled: true), targetUID: "BUILTIN", serial: 4242)])

        fake.applies = false
        fake.state["target"] = "HDMI-1"
        fake.state["targetName"] = ""
        XCTAssertEqual(run("driver", "push").output, "pushed the default profile of HDMI-1 to the driver; stored, not playing yet")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run("driver", "push", "--json").output.utf8)) as? [String: Any])
        XCTAssertEqual(json["source"] as? String, "default")
        XCTAssertEqual(json["playing"] as? Bool, false)
    }

    func testFailuresSayWhy() {
        fake.refuses = true
        let refused = run("driver", "push")
        XCTAssertEqual(refused.exitCode, 1)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.output.contains("identifier \"com.servitola.eq\""), refused.output)

        fake.refuses = false
        fake.state["target"] = ""
        XCTAssertEqual(run("driver", "push").output, "error: driver: the driver has no target yet")

        context.driver = { nil }
        XCTAssertEqual(run("driver", "status").output, "error: driver: not installed: no audio device com.servitola.eq.device")
        XCTAssertEqual(run("driver").exitCode, 2)
    }
}

final class DriverHealthTests: XCTestCase {
    func testReadsThePluginsKeys() {
        let health = DriverHealth(["target": "BT-RCA", "targetName": "BE-RCA", "ioRunning": true, "underruns": 3, "overruns": 1,
                                   "clockCorrectionPpm": -12.5, "sampleRate": 48000.0, "latencyFrames": 7200, "eqActive": true,
                                   "settingsVersion": 1, "settingsSerial": 42, "hidden": false, "killed": false])
        XCTAssertEqual(health.target, "BT-RCA")
        XCTAssertTrue(health.ioRunning)
        XCTAssertEqual(health.underruns, 3)
        XCTAssertEqual(health.clockPpm, -12.5)
        XCTAssertEqual(health.latencyMs, 150)
        XCTAssertEqual(health.settingsVersion, 1)
        XCTAssertNil(DriverHealth([:]).settingsVersion)
        XCTAssertNil(DriverHealth([:]).latencyMs)
    }

    func testSelectorsMatchThePlugin() {
        XCTAssertEqual(DriverControl.targetSelector, 0x6571_5467)
        XCTAssertEqual(DriverControl.hiddenSelector, 0x6571_4864)
        XCTAssertEqual(DriverControl.requiredVersion, 1)
    }
}
