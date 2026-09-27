import Darwin
import Foundation

// isatty(2) here, not Paint.enabled (which reads fd 1) — stderr can be a TTY while stdout is piped.
func paintStderrError(_ text: String) -> String {
    let prefix = "error: "
    let environment = ProcessInfo.processInfo.environment
    guard text.hasPrefix(prefix), isatty(2) == 1, environment["NO_COLOR"] == nil, environment["TERM"] != "dumb" else { return text }
    return "\u{1B}[\(Paint.Ink.red.rawValue)merror:\u{1B}[0m " + text.dropFirst(prefix.count)
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "daemon" {
    let daemon = Daemon(store: ConfigStore(url: ConfigStore.defaultURL), statusURL: Status.defaultURL)
    daemon.run()
}

let result = CLI.run(arguments, context: .live())
if result.isError && !arguments.contains("--json") {
    FileHandle.standardError.write(Data((paintStderrError(result.output) + "\n").utf8))
} else {
    print(result.output)
}
exit(result.exitCode)
