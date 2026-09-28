import XCTest
@testable import eq

final class CLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-27" })
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func runCLI(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    func testInitWritesScreenshotCurveForBuiltIn() throws {
        let result = runCLI("init")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains(context.store.url.path))
        let config = try context.store.load()
        XCTAssertEqual(config.devices["BUILTIN"]?.bands, Config.screenshotCurve)
        XCTAssertEqual(config.devices["BUILTIN"]?.name, "MacBook Pro Speakers")
    }

    func testShowPrintsCurrentDeviceProfileAsTable() {
        _ = runCLI("init")
        let result = runCLI()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("MacBook Pro Speakers"))
        XCTAssertTrue(result.output.contains("32Hz"))
        XCTAssertTrue(result.output.contains("+4.8"))
        XCTAssertTrue(result.output.contains("-3.1"))
        XCTAssertTrue(result.output.contains("preamp"))
    }

    func testShowWithoutConfigHintsInit() {
        let result = runCLI()
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("eq init"), result.output)
    }

    func testShowPrefersDaemonDeviceWhenStatusIsFresh() throws {
        _ = runCLI("init")
        try Status(state: .running, device: .init(uid: "BT-1", name: "JBL Big", transport: "bluetooth"), sampleRate: 48000,
                   profile: .default, framesProcessed: 1, callbacks: 1, writes: 1, enabled: true, error: nil, pid: getpid(),
                   version: "2026.09.27.1", updatedAt: Date())
            .write(to: context.statusURL)
        let result = runCLI()
        XCTAssertTrue(result.output.contains("JBL Big"))
        XCTAssertTrue(result.output.contains("default profile"))
    }

    func testShowUsesAliveStatusEvenWhenOld() throws {
        _ = runCLI("init")
        try Status(state: .running, device: .init(uid: "BT-1", name: "JBL Big", transport: "bluetooth"), sampleRate: 48000,
                   profile: .default, framesProcessed: 1, callbacks: 1, writes: 1, enabled: true, error: nil, pid: getpid(),
                   version: "2026.09.27.1", updatedAt: Date().addingTimeInterval(-60))
            .write(to: context.statusURL)
        let result = runCLI()
        XCTAssertTrue(result.output.contains("JBL Big"))
    }

    func testShowIgnoresDeadPidStatus() throws {
        _ = runCLI("init")
        try Status(state: .running, device: .init(uid: "BT-1", name: "JBL Big", transport: "bluetooth"), sampleRate: 48000,
                   profile: .default, framesProcessed: 1, callbacks: 1, writes: 1, enabled: true, error: nil, pid: 2_000_000_000,
                   version: "2026.09.27.1", updatedAt: Date().addingTimeInterval(-60))
            .write(to: context.statusURL)
        let result = runCLI()
        XCTAssertTrue(result.output.contains("MacBook Pro Speakers"))
    }

    func testSetOnCurrentDeviceCreatesProfileFromDefault() throws {
        _ = runCLI("init")
        try Status(state: .running, device: .init(uid: "BT-1", name: "JBL Big", transport: "bluetooth"), sampleRate: 48000,
                   profile: .default, framesProcessed: 1, callbacks: 1, writes: 1, enabled: true, error: nil, pid: getpid(),
                   version: "2026.09.27.1", updatedAt: Date())
            .write(to: context.statusURL)
        let result = runCLI("set", "1khz", "-3", "64hz", "+2")
        XCTAssertEqual(result.exitCode, 0, result.output)
        let profile = try XCTUnwrap(try context.store.load().devices["BT-1"])
        XCTAssertEqual(profile.name, "JBL Big")
        XCTAssertEqual(profile.bands[5], -3)
        XCTAssertEqual(profile.bands[1], 2)
        XCTAssertEqual(profile.bands[0], Config.screenshotCurve[0])
    }

    func testSetWithDeviceSubstring() throws {
        _ = runCLI("init")
        let result = runCLI("set", "--device", "jbl", "16khz", "+1")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(try context.store.load().devices["BT-1"]?.bands[9], 1)
    }

    func testSetRejectsUnknownBandWithoutWriting() throws {
        _ = runCLI("init")
        let before = try context.store.load()
        let result = runCLI("set", "77hz", "+1")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("unknown band"))
        XCTAssertEqual(try context.store.load(), before)
    }

    func testAmbiguousAndMissingDevice() {
        _ = runCLI("init")
        context.connectedDevices = { [("A", "Speakers One", "usb"), ("B", "Speakers Two", "usb")] }
        XCTAssertTrue(runCLI("set", "--device", "speakers", "1khz", "0").output.contains("matches several"))
        XCTAssertTrue(runCLI("set", "--device", "nothing", "1khz", "0").output.contains("no device or profile"))
    }

    func testPreampFlatAndCopy() throws {
        _ = runCLI("init")
        XCTAssertEqual(runCLI("preamp", "-1.5").exitCode, 0)
        XCTAssertEqual(try context.store.load().devices["BUILTIN"]?.preamp, -1.5)
        XCTAssertEqual(runCLI("copy", "--to", "JBL").exitCode, 0)
        XCTAssertEqual(try context.store.load().devices["BT-1"]?.preamp, -1.5)
        XCTAssertEqual(try context.store.load().devices["BT-1"]?.name, "JBL Big")
        XCTAssertEqual(runCLI("flat").exitCode, 0)
        XCTAssertEqual(try context.store.load().devices["BUILTIN"], Profile(name: "MacBook Pro Speakers", preamp: 0, bands: Profile.flat.bands))
        XCTAssertEqual(try context.store.load().devices["BT-1"]?.preamp, -1.5)
    }

    func testOnOffToggleEnabled() throws {
        _ = runCLI("init")
        XCTAssertEqual(runCLI("off").exitCode, 0)
        XCTAssertFalse(try context.store.load().enabled)
        XCTAssertEqual(runCLI("on").exitCode, 0)
        XCTAssertTrue(try context.store.load().enabled)
    }

    func testDevicesListsConnectedAndProfiles() throws {
        _ = runCLI("init")
        _ = runCLI("set", "--device", "jbl", "1khz", "0")
        context.connectedDevices = { [("BUILTIN", "MacBook Pro Speakers", "builtin")] }
        let out = runCLI("devices").output
        XCTAssertTrue(out.contains("MacBook Pro Speakers"))
        XCTAssertTrue(out.contains("JBL Big"))
        XCTAssertTrue(out.contains("disconnected"))
        XCTAssertTrue(out.contains("* "))
    }

    func testStatusWhenDaemonMissingAndWhenNoPermission() throws {
        var result = runCLI("status")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("not running"))
        try Status(state: .noPermission, device: nil, sampleRate: 0, profile: nil, framesProcessed: 0, callbacks: 0, writes: 1, enabled: true,
                   error: "Couldn’t create audio tap (error 1852797029).", pid: getpid(),
                   version: "2026.09.27.1", updatedAt: Date())
            .write(to: context.statusURL)
        result = runCLI("status")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("Screen & System Audio Recording"))
        XCTAssertTrue(runCLI("status", "--json").output.contains("\"no-permission\""))
    }

    func testDoctorExitCodeAndJSON() {
        context.doctorProbes = {
            DoctorProbes(
                osVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0) },
                loadConfig: { Config.initial(builtInUID: nil, builtInName: nil) },
                readStatus: { nil },
                defaultOutput: { DefaultOutput(name: "Speakers", streams: 1, channels: 2) },
                launchAgentLoaded: { true },
                executablePath: { _ in nil },
                signalStatus: { _ in true },
                sleep: { _ in },
                smoke: false)
        }
        let result = runCLI("doctor")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("✗ daemon"), result.output)
        let j = try? json("doctor")
        XCTAssertEqual(j?["ok"] as? Bool, false)
    }

    func testUnknownCommandShowsUsage() {
        let result = runCLI("bogus")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("eq set"))
    }

    private func fixtureText(_ name: String) throws -> String {
        try String(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")))
    }

    private func json(_ args: String...) throws -> [String: Any] {
        let result = CLI.run(args + ["--json"], context: context)
        let data = Data(result.output.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], result.output)
    }

    func testJSONShow() throws {
        _ = runCLI("init")
        let j = try json()
        XCTAssertEqual((j["device"] as? [String: Any])?["name"] as? String, "MacBook Pro Speakers")
        XCTAssertEqual(j["source"] as? String, "device")
        let profile = try XCTUnwrap(j["profile"] as? [String: Any])
        XCTAssertEqual((profile["bands"] as? [Double])?.count, 10)
        XCTAssertEqual((profile["filters"] as? [Any])?.count, 0)
    }

    func testJSONSetDevicesToggleInitStatusHelp() throws {
        var j = try json("init")
        XCTAssertEqual(j["created"] as? Bool, true)
        XCTAssertEqual(j["path"] as? String, context.store.url.path)
        j = try json("set", "1khz", "-3")
        XCTAssertEqual(((j["profile"] as? [String: Any])?["bands"] as? [Double])?[5], -3)
        j = try json("devices")
        XCTAssertEqual(j["current"] as? String, "BUILTIN")
        let devices = try XCTUnwrap(j["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first { $0["uid"] as? String == "BUILTIN" }?["profile"] as? String, "own")
        j = try json("off")
        XCTAssertEqual(j["enabled"] as? Bool, false)
        j = try json("help")
        XCTAssertTrue((j["usage"] as? String ?? "").contains("eq set"))
        try Status(state: .running, device: .init(uid: "BUILTIN", name: "MacBook Pro Speakers", transport: "builtin"), sampleRate: 48000,
                   profile: .device, framesProcessed: 1, callbacks: 2, writes: 1, enabled: true, error: nil, pid: getpid(),
                   version: "2026.09.27.1", updatedAt: Date(), latencyMs: 11.6, tapSilentSeconds: 3,
                   warnings: [])
            .write(to: context.statusURL)
        j = try json("status")
        XCTAssertEqual(j["state"] as? String, "running")
        XCTAssertEqual(j["callbacks"] as? Int, 2)
        XCTAssertEqual(j["latencyMs"] as? Double, 11.6)
        XCTAssertEqual(j["tapSilentSeconds"] as? Double, 3)
        XCTAssertEqual(j["warnings"] as? [String], [])
    }

    func testJSONErrorKeepsExitCode() throws {
        _ = runCLI("init")
        let result = CLI.run(["set", "77hz", "+1", "--json"], context: context)
        XCTAssertEqual(result.exitCode, 2)
        let j = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let error = try XCTUnwrap(j["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "unknownBand")
        XCTAssertTrue((error["message"] as? String ?? "").contains("77hz"))
        let missing = CLI.run(["status", "--json"], context: context)
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(missing.output.contains("\"daemonNotRunning\""))
    }

    func testJSONDevicesEmitsNullCurrentAndTransport() throws {
        _ = runCLI("init")
        context.connectedDevices = { [] }
        context.defaultOutput = { nil }
        let j = try json("devices")
        XCTAssertTrue(j["current"] is NSNull)
        let devices = try XCTUnwrap(j["devices"] as? [[String: Any]])
        let disconnected = try XCTUnwrap(devices.first { $0["uid"] as? String == "BUILTIN" })
        XCTAssertTrue(disconnected["transport"] is NSNull)
    }

    func testImportFromFileSetsFiltersResetsBandsAndPreamp() throws {
        _ = runCLI("init")
        let file = dir.appendingPathComponent("xm4.txt")
        try fixtureText("Sony WH-1000XM4 ParametricEQ").write(to: file, atomically: true, encoding: .utf8)
        let result = runCLI("import", file.path, "--device", "jbl")
        XCTAssertEqual(result.exitCode, 0, result.output)
        let profile = try XCTUnwrap(try context.store.load().devices["BT-1"])
        XCTAssertEqual(profile.filters.count, 10)
        XCTAssertEqual(profile.preamp, -6.1)
        XCTAssertEqual(profile.bands, Profile.flat.bands)
        XCTAssertEqual(profile.name, "JBL Big")
        XCTAssertEqual(profile.imported, "file xm4 · 2026-09-27")
        XCTAssertTrue(result.output.contains("lowShelf"))
    }

    func testImportFileFollowsIncludeBesideItButAURLDoesNot() throws {
        _ = runCLI("init")
        let sub = dir.appendingPathComponent("apo")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let config = "Preamp: -4 dB\nInclude: part.txt\nFilter: ON PK Fc 3000 Hz Gain 2 dB Q 1\n"
        try config.write(to: sub.appendingPathComponent("config.txt"), atomically: true, encoding: .utf8)
        try "Filter: ON LSC Fc 105 Hz Gain 3 dB Q 0.7\n".write(to: sub.appendingPathComponent("part.txt"), atomically: true, encoding: .utf8)
        let file = runCLI("import", sub.appendingPathComponent("config.txt").path)
        XCTAssertEqual(file.exitCode, 0, file.output)
        XCTAssertFalse(file.output.contains("warning"), file.output)
        XCTAssertEqual(try context.store.load().devices["BUILTIN"]?.filters.map(\.frequency), [105, 3000])

        context.fetch = { _ in Data(config.utf8) }
        let j = try json("import", "https://example.com/config.txt")
        let warnings = try XCTUnwrap((j["import"] as? [String: Any])?["warnings"] as? [String])
        XCTAssertEqual(warnings, ["line 2: not following Include: part.txt, only a file import can include other files"])
        XCTAssertEqual(try context.store.load().devices["BUILTIN"]?.filters.map(\.frequency), [3000])
    }

    func testImportFixedBandEQSetsTheBandsAndIgnoresKeepBands() throws {
        _ = runCLI("init")
        let file = dir.appendingPathComponent("fixed.txt")
        try fixtureText("Sony WH-1000XM4 FixedBandEQ").write(to: file, atomically: true, encoding: .utf8)
        let result = runCLI("import", file.path, "--keep-bands")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertTrue(result.output.contains("--keep-bands ignored: AutoEq FixedBandEQ (10 bands) sets all ten bands."), result.output)
        let profile = try XCTUnwrap(try context.store.load().devices["BUILTIN"])
        XCTAssertEqual(profile.bands, [-4.3, -1.8, -5.8, -1.4, 0.5, -0.6, 6.0, -0.8, 1.0, -2.2])
        XCTAssertEqual(profile.filters, [])
        XCTAssertEqual(profile.preamp, -5.8)
    }

    func testImportRefusesAPreampOutsideTheRange() throws {
        _ = runCLI("init")
        let file = dir.appendingPathComponent("loud.txt")
        try "Preamp: -40 dB\nFilter: ON PK Fc 1000 Hz Gain 1 dB Q 1\n".write(to: file, atomically: true, encoding: .utf8)
        let result = runCLI("import", file.path)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("not imported: \(file.path): preamp -40 dB is outside -30…12 dB"), result.output)
    }

    func testImportKeepBands() throws {
        _ = runCLI("init")
        _ = runCLI("set", "64hz", "+2")
        let file = dir.appendingPathComponent("xm4.txt")
        try fixtureText("Sony WH-1000XM4 ParametricEQ").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(runCLI("import", file.path, "--keep-bands").exitCode, 0)
        XCTAssertEqual(try context.store.load().devices["BUILTIN"]?.bands[1], 2)
    }

    func testImportByNameUsesIndexAndFetchesParametricFile() throws {
        _ = runCLI("init")
        let index = try String(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "INDEX", withExtension: "md", subdirectory: "Fixtures")))
        let parametric = try fixtureText("Sony WH-1000XM4 ParametricEQ")
        var urls: [String] = []
        context.fetch = { url in
            urls.append(url.absoluteString)
            if url == AutoEqIndex.indexURL { return Data(index.utf8) }
            return Data(parametric.utf8)
        }
        let result = runCLI("import", "wh-1000xm4", "--source", "crinacle")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(urls.count, 2)
        XCTAssertTrue(urls[1].contains("crinacle/GRAS%2043AG-7%20over-ear/Sony%20WH-1000XM4/Sony%20WH-1000XM4%20ParametricEQ.txt"))
        let profile = try XCTUnwrap(try context.store.load().devices["BUILTIN"])
        XCTAssertEqual(profile.imported, "AutoEq crinacle · Sony WH-1000XM4 · 2026-09-27")
        let j = try json("import", "wh-1000xm4", "--source", "crinacle")
        XCTAssertEqual(((j["import"] as? [String: Any])?["origin"] as? String), "AutoEq crinacle · Sony WH-1000XM4")
        XCTAssertEqual(((j["import"] as? [String: Any])?["format"] as? String), "AutoEq / Equalizer APO parametric")
    }

    func testImportAmbiguousAndNotFoundAndOffline() throws {
        _ = runCLI("init")
        let index = try String(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "INDEX", withExtension: "md", subdirectory: "Fixtures")))
        context.fetch = { url in
            if url == AutoEqIndex.indexURL { return Data(index.utf8) }
            throw URLError(.fileDoesNotExist)
        }
        var result = runCLI("import", "sony")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("Sony WH-1000XM5"))
        result = runCLI("import", "bose")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("no ParametricEQ.txt"))
        context.fetch = { _ in throw URLError(.notConnectedToInternet) }
        result = runCLI("import", "airpods pro 2", "--refresh")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("network"))
        context.fetch = { url in
            if url == AutoEqIndex.indexURL { return Data(index.utf8) }
            throw URLError(.fileDoesNotExist)
        }
        result = runCLI("import", "airpods pro 2")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("no ParametricEQ.txt"), result.output)
        XCTAssertTrue(result.output.contains("AirPods Pro 2"), result.output)
    }

    private final class Fetches { var urls: [String] = [] }

    @discardableResult
    private func serveFixtureIndex() throws -> Fetches {
        let index = try String(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "INDEX", withExtension: "md", subdirectory: "Fixtures")))
        let opra = try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "opra", withExtension: "jsonl", subdirectory: "Fixtures")))
        let parametric = try fixtureText("Sony WH-1000XM4 ParametricEQ")
        let fetches = Fetches()
        context.fetch = { url in
            fetches.urls.append(url.absoluteString)
            if url == OPRA.databaseURL { return opra }
            return Data((url == AutoEqIndex.indexURL ? index : parametric).utf8)
        }
        return fetches
    }

    func testImportVariantPicksTheTaggedEntry() throws {
        _ = runCLI("init")
        let fetches = try serveFixtureIndex()
        let result = runCLI("import", "wh1000xm4", "--variant", "anc-off")
        XCTAssertEqual(result.exitCode, 0, result.output)
        let urls = fetches.urls
        XCTAssertTrue(urls[1].contains("HypetheSonics/over-ear/Sony%20WH-1000XM4%20(ANC%20Off)/"), urls[1])
        XCTAssertEqual(try context.store.load().devices["BUILTIN"]?.imported, "AutoEq HypetheSonics · Sony WH-1000XM4 (ANC Off) · 2026-09-27")
    }

    func testImportAsksForVariantAndSuggestsOnTypo() throws {
        _ = runCLI("init")
        try serveFixtureIndex()
        let before = try context.store.load()
        var result = runCLI("import", "moondrop aria")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("several variants — pick one with --variant:\n  sample-1\n  sample-2"), result.output)
        XCTAssertEqual((try json("import", "moondrop aria")["error"] as? [String: Any])?["code"] as? String, "importVariant")
        result = runCLI("import", "airpods pro 2", "--variant", "bogus")
        XCTAssertTrue(result.output.contains("has no variant \"bogus\""), result.output)
        result = runCLI("import", "sony wh-1000xm6")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("did you mean:\n  Sony WH-1000XM3\n  Sony WH-1000XM4"), result.output)
        XCTAssertEqual((try json("import", "sony wh-1000xm6")["error"] as? [String: Any])?["code"] as? String, "importNotFound")
        XCTAssertEqual(try context.store.load(), before)
    }

    func testImportSearchListsWithoutImporting() throws {
        let fetches = try serveFixtureIndex()
        let result = runCLI("import", "--search", "wh1000xm4")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(fetches.urls, [AutoEqIndex.indexURL.absoluteString, OPRA.databaseURL.absoluteString])
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.store.url.path))
        let lines = result.output.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "8 matches for \"wh1000xm4\"")
        XCTAssertTrue(lines[1].hasPrefix("* Sony WH-1000XM4  —        oratory1990 "), lines[1])
        XCTAssertTrue(lines[4].contains("OPRA · oratory1990 (Harman Target)"), lines[4])
        XCTAssertTrue(lines[4].hasSuffix("  OPRA"), lines[4])
        XCTAssertTrue(lines[5].contains("OPRA · AutoEQ (Measured by oratory1990)"), lines[5])
        XCTAssertTrue(lines[7].contains("anc-on   HypetheSonics "), lines[7])
        XCTAssertTrue(lines[8].contains("anc-on   OPRA · AutoEQ (Measured by HypetheSonics)"), lines[8])
        XCTAssertEqual(lines.last, "* is what eq import \"wh1000xm4\" applies")

        let j = try json("import", "--search", "airpods pro 2", "--source", "crinacle")
        let results = try XCTUnwrap(j["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(results[0]["variantKey"] as? String, "51db-anc")
        XCTAssertEqual(results[0]["model"] as? String, "Apple AirPods Pro 2")
        XCTAssertEqual(results[0]["database"] as? String, "AutoEq")
        XCTAssertEqual(results.filter { $0["pick"] as? Bool == true }.map { $0["variant"] as? String }, ["ANC mode"])

        let variants = runCLI("import", "--search", "moondrop aria")
        XCTAssertTrue(variants.output.hasSuffix("several variants — add --variant sample-1 | sample-2"), variants.output)
    }

    func testImportSearchWithoutMatchSuggestsAndFails() throws {
        try serveFixtureIndex()
        let result = runCLI("import", "--search", "moondorp aria")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.output, "no headphone matches \"moondorp aria\" — did you mean: Moondrop Aria")
        let j = try json("import", "--search", "moondorp aria")
        XCTAssertEqual(j["suggestions"] as? [String], ["Moondrop Aria"])
        XCTAssertEqual((j["results"] as? [Any])?.count, 0)
        XCTAssertEqual(runCLI("import", "--search", "sony", "--device", "jbl").exitCode, 2)
        XCTAssertEqual(runCLI("import", "--search", "sony", "--keep-bands").exitCode, 2)
    }

    func testImportFallsBackToOPRAWithAttribution() throws {
        _ = runCLI("init")
        let fetches = try serveFixtureIndex()
        let result = runCLI("import", "sennheiser hd 600")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(fetches.urls, [AutoEqIndex.indexURL.absoluteString, OPRA.databaseURL.absoluteString])
        let lines = result.output.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "imported OPRA oratory1990 · Sennheiser HD 600 (OPRA parametric)")
        XCTAssertEqual(lines[1], "preset by oratory1990 (Harman Target) · via OPRA (https://github.com/opra-project/OPRA), CC BY-SA 4.0")
        let profile = try XCTUnwrap(try context.store.load().devices["BUILTIN"])
        XCTAssertEqual(profile.imported, "OPRA oratory1990 · Sennheiser HD 600 · 2026-09-27")
        XCTAssertEqual(profile.filters.count, 10)
        XCTAssertEqual(profile.preamp, -9.3)
        XCTAssertEqual(profile.filters.first, Filter(type: .peak, frequency: 20, gain: 4, q: 1.1, origin: .import))
        let j = try json("import", "sennheiser hd 600")
        let details = try XCTUnwrap(j["import"] as? [String: Any])
        XCTAssertEqual(details["format"] as? String, "OPRA parametric")
        XCTAssertTrue((details["attribution"] as? String ?? "").contains("CC BY-SA 4.0"))
    }

    func testImportSourceOPRASkipsAutoEqAndAutoEqHitSkipsOPRA() throws {
        _ = runCLI("init")
        let fetches = try serveFixtureIndex()
        var result = runCLI("import", "wh1000xm4", "--source", "OPRA")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(fetches.urls, [OPRA.databaseURL.absoluteString])
        XCTAssertEqual(try context.store.load().devices["BUILTIN"]?.imported, "OPRA oratory1990 · Sony WH-1000XM4 · 2026-09-27")
        result = runCLI("import", "wh1000xm4", "--source", "opra", "--variant", "anc-on")
        XCTAssertEqual(try context.store.load().devices["BUILTIN"]?.imported, "OPRA AutoEQ · Sony WH-1000XM4 (ANC on) · 2026-09-27", result.output)

        fetches.urls = []
        result = runCLI("import", "wh1000xm4")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertFalse(fetches.urls.contains(OPRA.databaseURL.absoluteString), "\(fetches.urls)")
        XCTAssertFalse(result.output.contains("OPRA"), result.output)
        result = runCLI("import", "sennheiser hd 600", "--source", "crinacle")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(fetches.urls.contains(OPRA.databaseURL.absoluteString), "\(fetches.urls)")
    }

    func testImportTriesOPRAWhenTheAutoEqIndexCannotLoad() throws {
        _ = runCLI("init")
        let opra = try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "opra", withExtension: "jsonl", subdirectory: "Fixtures")))
        context.fetch = { url in
            guard url == OPRA.databaseURL else { throw URLError(.notConnectedToInternet) }
            return opra
        }
        let result = runCLI("import", "sennheiser hd 600")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(try context.store.load().devices["BUILTIN"]?.imported, "OPRA oratory1990 · Sennheiser HD 600 · 2026-09-27")

        let missing = runCLI("import", "nothing like it")
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(missing.output.contains("the last index is kept in"), "a miss in OPRA reports why AutoEq was not asked: \(missing.output)")
        XCTAssertEqual(runCLI("import", "sennheiser hd 600", "--source", "crinacle").exitCode, 1)
    }

    func testImportRefusesAnOPRAPreampOutOfRange() throws {
        _ = runCLI("init")
        let before = try context.store.load()
        let database = """
        {"type":"vendor","id":"acme","data":{"name":"Acme"}}
        {"type":"product","id":"acme::loud","data":{"name":"Loud","vendor_id":"acme"}}
        {"type":"eq","id":"acme:loud::deep","data":{"author":"somebody","type":"parametric_eq","parameters":{"gain_db":-40,"bands":[{"type":"peak_dip","frequency":1000,"gain_db":-3,"q":1.4}]},"product_id":"acme::loud"}}
        """
        context.fetch = { _ in Data(database.utf8) }
        let result = runCLI("import", "acme loud", "--source", "opra")
        XCTAssertEqual(result.exitCode, 1, result.output)
        XCTAssertTrue(result.output.contains("not imported: OPRA preset \u{201C}acme:loud::deep\u{201D} has preamp -40 dB, outside -30…12 dB"),
                      result.output)
        XCTAssertEqual(try context.store.load(), before)
    }

    func testImportSearchKeepsAutoEqWhenOPRAIsDown() throws {
        let index = try String(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "INDEX", withExtension: "md", subdirectory: "Fixtures")))
        context.fetch = { url in
            guard url == AutoEqIndex.indexURL else { throw URLError(.notConnectedToInternet) }
            return Data(index.utf8)
        }
        let result = runCLI("import", "--search", "wh1000xm4")
        XCTAssertEqual(result.exitCode, 0, result.output)
        let lines = result.output.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("warning: network: OPRA:"), lines[0])
        XCTAssertEqual(lines[1], "5 matches for \"wh1000xm4\"")
        XCTAssertEqual(runCLI("import", "--search", "wh1000xm4", "--source", "opra").exitCode, 1)
        let j = try json("import", "--search", "wh1000xm4")
        XCTAssertEqual((j["warnings"] as? [String])?.count, 1)
    }

    func testImportAmbiguityListIsCapped() {
        _ = runCLI("init")
        let index = (1...25).map { "- [Model \($0)](./s/r/Model \($0)) by s" }.joined(separator: "\n")
        context.fetch = { _ in Data(index.utf8) }
        let result = runCLI("import", "model")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.hasSuffix("… and 5 more"), result.output)
        XCTAssertEqual(result.output.components(separatedBy: "\n  ").count, 22, result.output)
    }

    func testSourceAndRefreshRejectedForFileAndURL() throws {
        _ = runCLI("init")
        let file = dir.appendingPathComponent("xm4.txt")
        try fixtureText("Sony WH-1000XM4 ParametricEQ").write(to: file, atomically: true, encoding: .utf8)
        for args in [[file.path, "--source", "crinacle"], ["https://example.com/x.txt", "--refresh"], [file.path, "--variant", "anc-on"]] {
            let result = CLI.run(["import"] + args, context: context)
            XCTAssertEqual(result.exitCode, 2)
            XCTAssertTrue(result.output.contains("--source, --variant and --refresh apply to a headphone name"), result.output)
        }
    }

    func testConfigErrorsCarryConfigCodeAndSlashesStayUnescaped() throws {
        _ = runCLI("init")
        XCTAssertFalse(runCLI("init", "--json").output.contains("\\/"))
        try Data(#"{"version":2,"enabled":true,"default":{"preamp":0,"bands":[0,0,0,0,0,0,0,0,0,0]},"devices":{}}"#.utf8)
            .write(to: context.store.url)
        let j = try json("show")
        XCTAssertEqual((j["error"] as? [String: Any])?["code"] as? String, "config")
        XCTAssertTrue(runCLI("show").isError)
    }

    func testImportRejectsUnknownOption() {
        _ = runCLI("init")
        let result = runCLI("import", "sony", "--sorce", "crinacle")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("unknown option"), result.output)
    }

    func testImportClearRejectsOtherFlags() {
        _ = runCLI("init")
        let result = runCLI("import", "--clear", "--refresh")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.output.contains("--clear takes only --device"), result.output)
    }

    func testImportGarbageFileWritesNothing() throws {
        _ = runCLI("init")
        let before = try context.store.load()
        let file = dir.appendingPathComponent("junk.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let result = runCLI("import", file.path)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("could not read"))
        XCTAssertEqual(try context.store.load(), before)
    }

    func testStreamWithoutDaemon() {
        context.meterSocketURL = dir.appendingPathComponent("meter.sock")
        let result = runCLI("stream")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("not serving"), result.output)
    }

    func testStreamPrintsLines() throws {
        let socketURL = dir.appendingPathComponent("meter.sock")
        context.meterSocketURL = socketURL
        let queue = DispatchQueue(label: "stream-test")
        let server = MeterServer(socketURL: socketURL, queue: queue, tick: 0.01,
                                  source: { MeterFrameTests.sample }, onClientsChanged: { _ in })
        try server.start()
        defer { queue.sync { server.stop() } }

        var lines: [String] = []
        context.emit = { lines.append($0) }
        context.streamLimit = 5

        let result = runCLI("stream")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertEqual(lines.count, 5)
        for line in lines {
            XCTAssertEqual(try JSONDecoder().decode(MeterFrame.self, from: Data(line.utf8)), MeterFrameTests.sample)
        }
    }

    func testStreamStaysCompactAndPlainOnATerminal() throws {
        Paint.forced = true
        let socketURL = dir.appendingPathComponent("meter.sock")
        context.meterSocketURL = socketURL
        let queue = DispatchQueue(label: "stream-colour-test")
        let server = MeterServer(socketURL: socketURL, queue: queue, tick: 0.01,
                                  source: { MeterFrameTests.sample }, onClientsChanged: { _ in })
        try server.start()
        defer { queue.sync { server.stop() } }
        var lines: [String] = []
        context.emit = { lines.append($0) }
        context.streamLimit = 3
        let result = runCLI("stream", "--json")
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(lines.count, 3)
        XCTAssertFalse(lines.contains { $0.contains("\u{1B}") || $0.contains("\n") })
    }

    func testHumanLinesArePaintedOnlyWhenColourIsOn() throws {
        let esc = "\u{1B}["
        func lines(_ forced: Bool) throws -> [String: String] {
            Paint.forced = forced
            try? FileManager.default.removeItem(at: context.store.url)
            var out: [String: String] = ["init": runCLI("init").output]
            out["init again"] = runCLI("init").output
            out["on"] = runCLI("on").output
            out["off"] = runCLI("off").output
            out["copy"] = runCLI("copy", "--to", "JBL").output
            out["devices"] = runCLI("devices").output
            out["undo"] = runCLI("undo").output
            try Status(state: .running, device: .init(uid: "BUILTIN", name: "MacBook Pro Speakers", transport: "builtin"),
                       sampleRate: 48000, profile: .device, framesProcessed: 1, callbacks: 2, writes: 1, enabled: true,
                       error: nil, pid: getpid(), version: "1", updatedAt: Date(), latencyMs: 11.63,
                       warnings: ["filter 2 unstable at 192000 Hz — bypassed"])
                .write(to: context.statusURL)
            out["status"] = runCLI("status").output
            return out
        }
        let painted = try lines(true)
        XCTAssertTrue(painted["init"]!.hasPrefix(esc + "32mwrote" + esc + "0m " + esc + "2m"), painted["init"]!)
        XCTAssertTrue(painted["init again"]!.contains(esc + "2m" + context.store.url.path), painted["init again"]!)
        XCTAssertEqual(painted["on"], "eq " + esc + "32mon" + esc + "0m")
        XCTAssertEqual(painted["off"], "eq " + esc + "33moff (bypass)" + esc + "0m")
        XCTAssertTrue(painted["copy"]!.contains(esc + "1mJBL Big" + esc + "0m"), painted["copy"]!)
        XCTAssertTrue(painted["devices"]!.contains(esc + "1mJBL Big" + esc + "0m"), painted["devices"]!)
        XCTAssertTrue(painted["undo"]!.contains(esc + "32mrestored"), painted["undo"]!)
        XCTAssertTrue(painted["status"]!.contains(esc + "2mstate:" + esc + "0m " + esc + "32mrunning"), painted["status"]!)
        XCTAssertTrue(painted["status"]!.contains(esc + "32mdevice profile"), painted["status"]!)
        XCTAssertTrue(painted["status"]!.contains("latency " + esc + "33m11.6 ms" + esc + "0m"), painted["status"]!)
        XCTAssertTrue(painted["status"]!.contains(esc + "33mwarning:" + esc + "0m filter 2 unstable at 192000 Hz — bypassed"), painted["status"]!)
        let plain = try lines(false)
        for (command, text) in plain { XCTAssertFalse(text.contains("\u{1B}"), "\(command): \(text)") }
        XCTAssertEqual(plain["on"], "eq on")
        XCTAssertEqual(plain["off"], "eq off (bypass)")
        XCTAssertTrue(plain["status"]!.hasPrefix("state: running\ndevice: MacBook Pro Speakers [builtin] 48000 Hz, latency 11.6 ms, device profile"), plain["status"]!)
    }

    func testStreamExitsOneWhenDaemonCloses() throws {
        let socketURL = dir.appendingPathComponent("meter.sock")
        context.meterSocketURL = socketURL
        let queue = DispatchQueue(label: "stream-eof-test")
        let server = MeterServer(socketURL: socketURL, queue: queue, tick: 0.01,
                                  source: { MeterFrameTests.sample }, onClientsChanged: { _ in })
        try server.start()
        queue.asyncAfter(deadline: .now() + 0.05) { server.stop() }

        var lines: [String] = []
        context.emit = { lines.append($0) }

        let result = runCLI("stream")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("daemon closed the meter"), result.output)
    }

    func testImportClear() throws {
        _ = runCLI("init")
        let file = dir.appendingPathComponent("xm4.txt")
        try fixtureText("Sony WH-1000XM4 ParametricEQ").write(to: file, atomically: true, encoding: .utf8)
        _ = runCLI("import", file.path)
        _ = runCLI("set", "64hz", "+1")
        XCTAssertEqual(runCLI("import", "--clear").exitCode, 0)
        let profile = try XCTUnwrap(try context.store.load().devices["BUILTIN"])
        XCTAssertEqual(profile.filters, [])
        XCTAssertNil(profile.imported)
        XCTAssertEqual(profile.preamp, 0)
        XCTAssertEqual(profile.bands[1], 1)
    }

    func testZonesJSONListsInstrumentRanges() throws {
        let result = CLI.run(["zones", "--json"], context: context)
        XCTAssertEqual(result.exitCode, 0)
        let instruments = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]], result.output)
        XCTAssertEqual(instruments.count, 8)
        let voice = try XCTUnwrap(instruments.first { $0["name"] as? String == "voice" })
        XCTAssertEqual(voice["bands"] as? [Double], [64, 125, 250, 500, 1000, 2000, 4000, 8000])
        XCTAssertEqual(Set(voice.keys), ["name", "ranges", "bands"])
        let ranges = try XCTUnwrap(voice["ranges"] as? [[String: Any]])
        XCTAssertEqual(ranges.map { $0["name"] as? String }, ["fundamental", "F1", "F2", "presence", "sibilance"])
    }

    func testZonesTextShowsInstrumentRangesAndTouchedBands() {
        let result = runCLI("zones")
        XCTAssertEqual(result.exitCode, 0)
        let lines = result.output.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, Instruments.all.reduce(0) { $0 + $1.ranges.count })
        XCTAssertTrue(lines[0].hasPrefix("kick"), lines[0])
        XCTAssertTrue(lines[0].contains("thump 50Hz–100Hz"), lines[0])
        XCTAssertTrue(lines[0].contains("64Hz 125Hz"), lines[0])
        for line in lines { XCTAssertLessThanOrEqual(line.count, 90, line) }
        XCTAssertEqual(runCLI("zones", "extra").exitCode, 2)
    }

    func testWatchAcceptsOnlyZonesFlag() {
        let zones = runCLI("watch", "--zones")
        XCTAssertTrue(zones.output.contains("eq watch needs a terminal"), zones.output)
        let other = runCLI("watch", "--loud")
        XCTAssertEqual(other.exitCode, 2)
        XCTAssertTrue(other.output.contains("eq watch [--zones]"), other.output)
    }
}
