import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "daemon" {
    Daemon(store: ConfigStore(url: ConfigStore.defaultURL), statusURL: Status.defaultURL).run()
}

let result = CLI.run(arguments, context: .live())
print(result.output)
exit(result.exitCode)
