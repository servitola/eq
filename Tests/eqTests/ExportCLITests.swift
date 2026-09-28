import XCTest
@testable import eq

final class ExportCLITests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-28" })
        XCTAssertEqual(runCLI("init").exitCode, 0)
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func runCLI(_ args: String...) -> (exitCode: Int32, output: String, isError: Bool, streamed: Bool) {
        CLI.run(args, context: context)
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
    }

    func testDefaultIsAPOToStdoutForTheCurrentDevice() throws {
        let result = runCLI("export")
        XCTAssertEqual(result.exitCode, 0, result.output)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.hasPrefix("# Exported by eq for MacBook Pro Speakers, 2026-09-28\nPreamp: 0 dB\nFilter 1: ON PK Fc 32 Hz Gain 4.8 dB Q 1.41"),
                      result.output)
        XCTAssertEqual(try EQFormats.parse(Data(result.output.utf8)).bands, Config.screenshotCurve)
    }

    func testDeviceWithoutItsOwnProfileExportsTheDefault() {
        _ = runCLI("set", "--device", "JBL", "1khz", "+2")
        let jbl = runCLI("export", "--device", "JBL", "--format", "eqmac")
        XCTAssertTrue(jbl.output.contains("\"name\" : \"JBL Big\""), jbl.output)
        XCTAssertTrue(jbl.output.contains("2"), jbl.output)
        XCTAssertEqual(runCLI("export", "--device", "nope").exitCode, 1)
    }

    func testOutWritesTheFileAndRefusesToOverwrite() throws {
        let target = dir.appendingPathComponent("config.txt")
        let first = runCLI("export", "--out", target.path)
        XCTAssertEqual(first.exitCode, 0, first.output)
        XCTAssertTrue(first.output.contains("wrote \(target.path)"), first.output)
        let written = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(written.hasSuffix("Q 1.41\n"))

        _ = runCLI("preamp", "-2")
        let again = runCLI("export", "--out", target.path)
        XCTAssertEqual(again.exitCode, 1)
        XCTAssertTrue(again.isError)
        XCTAssertTrue(again.output.contains("exists — add --force"), again.output)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), written)

        let forced = runCLI("export", "--out", target.path, "--force")
        XCTAssertEqual(forced.exitCode, 0, forced.output)
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("Preamp: -2 dB"))
        XCTAssertEqual(try leftovers(), [])
    }

    func testOutIntoAMissingDirectoryFailsCleanly() throws {
        let result = runCLI("export", "--out", dir.appendingPathComponent("no/such/dir.txt").path)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.hasPrefix("error: export failed: cannot write"), result.output)
        XCTAssertEqual(try leftovers(), [])
    }

    func testOutOntoADirectoryIsRefusedEvenWithForce() {
        let result = runCLI("export", "--out", dir.path, "--force")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.output.contains("is a directory"), result.output)
    }

    func testEveryFormatExports() {
        for format in ExportFormat.allCases {
            let result = runCLI("export", "--format", format.rawValue.uppercased())
            XCTAssertEqual(result.exitCode, 0, "\(format): \(result.output)")
        }
    }

    func testEqMacRefusalIsAnErrorWithItsCode() {
        _ = runCLI("filter", "add", "peak", "3k", "-2")
        let text = runCLI("export", "--format", "eqmac")
        XCTAssertEqual(text.exitCode, 1)
        XCTAssertTrue(text.output.contains("not exported: eqMac's preset holds ten band gains"), text.output)
        let json = runCLI("export", "--format", "eqmac", "--json")
        XCTAssertTrue(json.output.contains("\"code\" : \"exportRefused\""), json.output)
    }

    func testJSONReportCarriesTheContentOrThePath() throws {
        let inline = runCLI("export", "--json")
        let report = try JSONSerialization.jsonObject(with: Data(inline.output.utf8)) as? [String: Any]
        XCTAssertEqual(report?["format"] as? String, "apo")
        XCTAssertEqual(report?["source"] as? String, "device")
        XCTAssertTrue((report?["content"] as? String)?.contains("Filter 10:") == true)

        let path = dir.appendingPathComponent("p.json").path
        let file = runCLI("export", "--format", "json", "--out", path, "--json")
        let fileReport = try JSONSerialization.jsonObject(with: Data(file.output.utf8)) as? [String: Any]
        XCTAssertEqual(fileReport?["path"] as? String, path)
        XCTAssertNil(fileReport?["content"])
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: Data(contentsOf: URL(fileURLWithPath: path))).bands, Config.screenshotCurve)
    }

    func testUsageErrors() {
        XCTAssertEqual(runCLI("export", "--format", "wav").exitCode, 2)
        XCTAssertTrue(runCLI("export", "--format", "wav").output.contains("apo graphiceq eqmac camilla json"))
        XCTAssertEqual(runCLI("export", "--format").exitCode, 2)
        XCTAssertEqual(runCLI("export", "--out").exitCode, 2)
        XCTAssertEqual(runCLI("export", "--force").exitCode, 2)
        XCTAssertEqual(runCLI("export", "extra").exitCode, 2)
    }

    func testHelpHasTheExportBlock() {
        let help = runCLI("export", "--help")
        XCTAssertTrue(help.output.contains("eq export"), help.output)
        XCTAssertTrue(help.output.contains("graphiceq"), help.output)
    }
}
