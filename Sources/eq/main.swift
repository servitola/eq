import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "daemon" {
    let daemon = Daemon(store: ConfigStore(url: ConfigStore.defaultURL), statusURL: Status.defaultURL)
    daemon.run()
}

let result = CLI.run(arguments, context: .live())
if result.exitCode == 0 || arguments.contains("--json") {
    print(result.output)
} else {
    FileHandle.standardError.write(Data((result.output + "\n").utf8))
}
exit(result.exitCode)
