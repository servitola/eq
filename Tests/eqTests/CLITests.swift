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
                   version: "2026.09.27.1", updatedAt: Date())
            .write(to: context.statusURL)
        j = try json("status")
        XCTAssertEqual(j["state"] as? String, "running")
        XCTAssertEqual(j["callbacks"] as? Int, 2)
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
        for args in [[file.path, "--source", "crinacle"], ["https://example.com/x.txt", "--refresh"]] {
            let result = CLI.run(["import"] + args, context: context)
            XCTAssertEqual(result.exitCode, 2)
            XCTAssertTrue(result.output.contains("--source and --refresh apply to a headphone name"), result.output)
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
}
