import Darwin
import Foundation

// isatty(2) here, not Paint.enabled (which reads fd 1) — stderr can be a TTY while stdout is piped.
func paintStderrError(_ text: String) -> String {
    let prefix = "error: "
    guard text.hasPrefix(prefix), isatty(2) == 1, ProcessInfo.processInfo.environment["NO_COLOR"] == nil else { return text }
    return "\u{1B}[\(Paint.Ink.red.rawValue)merror:\u{1B}[0m " + text.dropFirst(prefix.count)
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "daemon" {
    let daemon = Daemon(store: ConfigStore(url: ConfigStore.defaultURL), statusURL: Status.defaultURL)
    daemon.run()
}

let result = CLI.run(arguments, context: .live())
if result.exitCode == 0 || arguments.contains("--json") {
    print(result.output)
} else {
    FileHandle.standardError.write(Data((paintStderrError(result.output) + "\n").utf8))
}
exit(result.exitCode)
