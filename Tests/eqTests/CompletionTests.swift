import XCTest
@testable import eq

final class CompletionTests: XCTestCase {
    private var dir: URL!
    private var context: CLIContext!

    override func setUpWithError() throws {
        Paint.forced = false
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        context = CLIContext(
            store: ConfigStore(url: dir.appendingPathComponent("eq.json")),
            statusURL: dir.appendingPathComponent("status.json"),
            connectedDevices: { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("BT-1", "JBL Big", "bluetooth")] },
            defaultOutput: { ("BUILTIN", "MacBook Pro Speakers") },
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            cacheDirectory: dir.appendingPathComponent("cache"),
            today: { "2026-09-28" })
    }

    override func tearDownWithError() throws {
        Paint.forced = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ shell: String) -> String {
        let result = CLI.run(["completions", shell], context: context)
        XCTAssertEqual(result.exitCode, 0, result.output)
        return result.output
    }

    private func shell(_ path: String, _ arguments: [String], input: String? = nil) throws -> (status: Int32, output: String)? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - Scripts

    func testEveryScriptNamesEveryCommandAndFlag() {
        let forms = CommandHelp.all.flatMap(\.forms).filter { !$0.path.isEmpty }
        for shell in ["zsh", "bash", "fish"] {
            let text = script(shell)
            for form in forms {
                for word in form.path { XCTAssertTrue(text.contains(word), "\(shell) lacks \(word)") }
                for flag in form.flags { XCTAssertTrue(text.contains(flag.name), "\(shell) lacks \(flag.name)") }
            }
            XCTAssertTrue(text.contains("--dry-run"), shell)
            XCTAssertTrue(text.contains("__complete devices"), shell)
            XCTAssertTrue(text.contains("__complete presets"), shell)
            XCTAssertTrue(text.contains("__complete instruments"), shell)
            XCTAssertTrue(text.contains("__complete formats"), shell)
        }
        XCTAssertTrue(script("zsh").hasPrefix("#compdef eq\n"))
        XCTAssertTrue(script("bash").contains("complete -F _eq eq"))
        XCTAssertTrue(script("fish").contains("complete -c eq"))
    }

    func testEachShellIsASubcommand() {
        let paths = CommandHelp.all.flatMap(\.forms).map(\.path)
        for shell in Completions.Shell.allCases { XCTAssertTrue(paths.contains(["completions", shell.rawValue]), shell.rawValue) }
    }

    func testUnknownShellIsAUsageError() {
        XCTAssertEqual(CLI.run(["completions", "tcsh"], context: context).exitCode, 2)
        XCTAssertEqual(CLI.run(["completions"], context: context).exitCode, 2)
    }

    func testScriptsParse() throws {
        for (shell, path, flag) in [("zsh", "/bin/zsh", "-n"), ("bash", "/bin/bash", "-n"), ("bash", "/opt/homebrew/bin/bash", "-n"),
                                    ("fish", "/opt/homebrew/bin/fish", "--no-execute")] {
            let file = dir.appendingPathComponent("eq.\(shell)")
            try script(shell).write(to: file, atomically: true, encoding: .utf8)
            guard let result = try self.shell(path, [flag, file.path]) else { continue }
            XCTAssertEqual(result.status, 0, "\(path): \(result.output)")
        }
    }

    /// Runs the bash function the way readline would, with `eq` stubbed to answer `__complete`.
    private func bashComplete(_ words: [String], bash: String = "/bin/bash") throws -> [String]? {
        let file = dir.appendingPathComponent("eq.bash")
        try script("bash").write(to: file, atomically: true, encoding: .utf8)
        let quoted = words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let driver = """
        eq() {
          case $2 in
            devices) printf '%s\\n' 'JBL Big' 'MacBook Pro Speakers' 'Old Speakers' ;;
            outputs) printf '%s\\n' 'JBL Big' 'MacBook Pro Speakers' ;;
            presets) printf '%s\\n' favourite flat 'club mix' ;;
            instruments) printf '%s\\n' kick voice ;;
            formats) printf '%s\\n' apo json ;;
          esac
        }
        source '\(file.path)'
        COMP_WORDS=(\(quoted))
        COMP_CWORD=\(words.count - 1)
        _eq
        printf '%s\\n' "${COMPREPLY[@]}"
        """
        guard let result = try shell(bash, ["-c", driver]) else { return nil }
        XCTAssertEqual(result.status, 0, result.output)
        return result.output.split(separator: "\n").map(String.init)
    }

    func testBashCompletesCommandsSubcommandsFlagsAndValues() throws {
        guard let top = try bashComplete(["eq", "pr"]) else { throw XCTSkip("no bash") }
        XCTAssertEqual(Set(top), ["preamp", "preset"])
        XCTAssertEqual(Set(try XCTUnwrap(bashComplete(["eq", "device", ""]))), ["list", "use", "copy"])
        XCTAssertEqual(try bashComplete(["eq", "set", "--device", "J"]), ["JBL\\ Big"])
        XCTAssertEqual(Set(try XCTUnwrap(bashComplete(["eq", "device", "use", ""]))), ["JBL\\ Big", "MacBook\\ Pro\\ Speakers"])
        XCTAssertEqual(try bashComplete(["eq", "preset", "use", "cl"]), ["club\\ mix"])
        XCTAssertEqual(try bashComplete(["eq", "boost", "v"]), ["voice"])
        XCTAssertEqual(try bashComplete(["eq", "export", "--format", "j"]), ["json"])
        XCTAssertEqual(try bashComplete(["eq", "set", "1k"]), ["1khz"])
        XCTAssertEqual(try bashComplete(["eq", "set", "1khz", "+2", "16"]), ["16khz"])
        XCTAssertEqual(try bashComplete(["eq", "filter", "add", "high"]).map(Set.init), ["highshelf", "highpass"])
        XCTAssertTrue(try XCTUnwrap(bashComplete(["eq", "flat", "--"])).contains("--dry-run"))
        XCTAssertFalse(try XCTUnwrap(bashComplete(["eq", "status", "--"])).contains("--dry-run"))
        XCTAssertEqual(try bashComplete(["eq", "set", "--device", "JBL\\ B"]), ["JBL\\ Big"])
        XCTAssertEqual(try bashComplete(["eq", "copy", "--to", "Mac"]), ["MacBook\\ Pro\\ Speakers"])
    }

    func testDeviceUseCompletesOnlyConnectedDevices() throws {
        _ = CLI.run(["init"], context: context)
        _ = CLI.run(["set", "--device", "jbl", "1khz", "0"], context: context)
        context.connectedDevices = { [("BUILTIN", "MacBook Pro Speakers", "builtin")] }
        XCTAssertEqual(CLI.run(["__complete", "outputs"], context: context).output, "MacBook Pro Speakers")
        for shell in ["zsh", "bash", "fish"] { XCTAssertTrue(script(shell).contains("__complete outputs"), shell) }
        guard let words = try bashComplete(["eq", "device", "use", ""]) else { throw XCTSkip("no bash") }
        XCTAssertFalse(words.contains("Old\\ Speakers"), "\(words)")
    }

    func testBash5Too() throws {
        guard let words = try bashComplete(["eq", "device", "copy", "--device", "J"], bash: "/opt/homebrew/bin/bash") else {
            throw XCTSkip("no Homebrew bash")
        }
        XCTAssertEqual(words, ["JBL\\ Big"])
    }

    /// zsh's completion system needs a live line editor, so this calls `_eq` with `words` and `CURRENT`
    /// set by hand and `compadd`/`_describe`/`_files` stubbed to print what they are given.
    private func zshComplete(_ line: String) throws -> [String]? {
        let file = dir.appendingPathComponent("_eq")
        try script("zsh").write(to: file, atomically: true, encoding: .utf8)
        let driver = #"""
        compdef() { }
        compadd() {
          local -a out
          while (( $# )); do
            case $1 in
              (-a) shift; out+=("${(@P)1}") ;;
              (--) shift; out+=("$@"); break ;;
              (*) out+=("$1") ;;
            esac
            shift
          done
          print -rl -- $out
        }
        _describe() { local -a c; c=("${(@P)4}"); print -rl -- ${c%%:*} }
        _files() { print -r -- FILES }
        eq() { case $2 in devices) print -l 'JBL Big' 'MacBook Pro Speakers';; presets) print -l favourite 'club mix';; instruments) print -l kick voice;; esac }
        source $1
        words=(${(z)2})
        [[ $2 == *' ' ]] && words+=('')
        CURRENT=$#words
        _eq
        """#
        guard let result = try shell("/bin/zsh", ["-f", "-c", driver, "zsh", file.path, line]) else { return nil }
        XCTAssertEqual(result.status, 0, result.output)
        return result.output.split(separator: "\n").map(String.init)
    }

    func testZshCompletesCommandsSubcommandsFlagsAndValues() throws {
        guard let top = try zshComplete("eq p") else { throw XCTSkip("no zsh") }
        XCTAssertTrue(top.contains("preset") && top.contains("device") && top.contains("set"), "\(top)")
        XCTAssertEqual(try zshComplete("eq device "), ["list", "use", "copy"])
        XCTAssertEqual(try zshComplete("eq set --device J"), ["JBL Big", "MacBook Pro Speakers"])
        XCTAssertEqual(try zshComplete("eq preset use cl"), ["favourite", "club mix"])
        XCTAssertEqual(try zshComplete("eq set 1khz -3 1"), Config.bandLabels.map { $0.lowercased() })
        XCTAssertEqual(try zshComplete("eq copy --to M"), ["JBL Big", "MacBook Pro Speakers"])
        XCTAssertEqual(try zshComplete("eq import "), ["FILES"])
        XCTAssertTrue(try XCTUnwrap(zshComplete("eq device copy --")).contains("--device"))
        XCTAssertFalse(try XCTUnwrap(zshComplete("eq devices --")).contains("--dry-run"))
    }

    // MARK: - The hidden listing

    func testCompleteListsWithoutADaemon() throws {
        XCTAssertEqual(CLI.run(["__complete", "devices"], context: context).output, "JBL Big\nMacBook Pro Speakers")
        _ = CLI.run(["init"], context: context)
        _ = CLI.run(["set", "--device", "jbl", "1khz", "0"], context: context)
        context.connectedDevices = { [("BUILTIN", "MacBook Pro Speakers", "builtin"), ("USB-1", "Scarlett 2i2", "usb")] }
        XCTAssertEqual(CLI.run(["__complete", "devices"], context: context).output, "JBL Big\nMacBook Pro Speakers\nScarlett 2i2")
        XCTAssertEqual(CLI.run(["__complete", "presets"], context: context).output, "favourite\nflat")
        XCTAssertTrue(CLI.run(["__complete", "instruments"], context: context).output.hasPrefix("kick\nbass\n"))
        XCTAssertEqual(CLI.run(["__complete", "formats"], context: context).output, "apo\ngraphiceq\neqmac\ncamilla\njson")
        XCTAssertEqual(CLI.run(["__complete", "nonsense"], context: context).output, "")
        XCTAssertEqual(CLI.run(["__complete", "nonsense"], context: context).exitCode, 0)
    }

    func testCompleteIsHiddenFromHelp() {
        XCTAssertFalse(HelpRenderer.plain(width: 200).contains("__complete"))
    }

    // MARK: - Man page

    func testManPageComesFromTheTable() throws {
        let result = CLI.run(["man"], context: context)
        XCTAssertEqual(result.exitCode, 0)
        let page = result.output
        XCTAssertTrue(page.hasPrefix(".TH EQ 1"), page)
        for section in ["NAME", "SYNOPSIS", "COMMANDS", "OPTIONS", "FILES", "ENVIRONMENT"] {
            XCTAssertTrue(page.contains(".SH \(section)"), section)
        }
        for entry in CommandHelp.all { XCTAssertTrue(page.contains(ManPage.escape(entry.usage)), entry.usage) }
        XCTAssertFalse(page.unicodeScalars.contains { !$0.isASCII }, "roff wants ASCII; non-ASCII becomes \\[uXXXX]")
        XCTAssertTrue(page.contains("\\-\\-dry\\-run"))
    }

    func testManPageLints() throws {
        let file = dir.appendingPathComponent("eq.1")
        try CLI.run(["man"], context: context).output.write(to: file, atomically: true, encoding: .utf8)
        guard let result = try shell("/usr/bin/mandoc", ["-T", "lint", "-W", "warning", file.path]) else { throw XCTSkip("no mandoc") }
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "")
    }
}
