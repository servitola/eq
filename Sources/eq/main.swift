import Darwin
import Foundation

func paintStderrError(_ text: String) -> String {
    let prefix = "error: "
    guard text.hasPrefix(prefix), Paint.enabled(fd: 2) else { return text }
    return "\u{1B}[\(Paint.Ink.red.rawValue)merror:\u{1B}[0m " + text.dropFirst(prefix.count)
}

if let invoked = Bundle.main.executablePath, let real = LiveLaunchAgent.realExecutable(invoked: invoked) {
    execv(real, CommandLine.unsafeArgv)
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "daemon" && !arguments.contains("--help") && !arguments.contains("-h") && !arguments.contains("--dry-run") {
    if let log = ProcessInfo.processInfo.environment["EQ_LOG"], !log.isEmpty { Log.redirect(to: log) }
    let daemon = Daemon(store: ConfigStore(url: ConfigStore.defaultURL), statusURL: Status.defaultURL)
    daemon.run()
}

let result = CLI.run(arguments, context: .live())
if result.isError && !arguments.contains("--json") {
    FileHandle.standardError.write(Data((paintStderrError(result.output) + "\n").utf8))
} else if !(result.streamed && result.output.isEmpty) {
    print(result.output)
}
exit(result.exitCode)
