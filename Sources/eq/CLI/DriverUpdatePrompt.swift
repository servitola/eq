import Darwin
import Foundation

/// Asks once, in a terminal, to install the newer driver this eq carries, before the command the user ran.
/// A no is remembered per driver revision, so only a newer one asks again.
extension CLI {
    struct DriverPrompt {
        var interactive: () -> Bool
        var environment: [String: String]
        /// Shows the question on stderr and reads one line; nil at the end of input.
        var ask: (String) -> String?

        static func live() -> DriverPrompt {
            DriverPrompt(interactive: { isatty(0) == 1 && isatty(2) == 1 },
                         environment: ProcessInfo.processInfo.environment,
                         ask: { question in
                             FileHandle.standardError.write(Data(question.utf8))
                             let line = readLine()
                             if line == nil { FileHandle.standardError.write(Data("\n".utf8)) }
                             return line
                         })
        }
    }

    /// Completion runs on every Tab, help, the man page and the version have no side effects, `eq mode`
    /// installs or leaves on its own, and an uninstall must not be met with an offer to install.
    private static let skipsDriverPrompt: Set<String> = ["__complete", "completions", "man", "help", "-h", "--help", "mode", "daemon", "version"]

    static func driverPromptApplies(to args: [String], environment: [String: String]) -> Bool {
        if let off = environment["EQ_NO_DRIVER_PROMPT"], !off.isEmpty, off != "0" { return false }
        if skipsDriverPrompt.contains(args.first ?? "show") || args.contains("--help") || args.contains("-h") { return false }
        return !args.starts(with: ["driver", "uninstall"])
    }

    static func driverPromptQuestion(from installed: DriverBuild, to bundled: DriverBuild, paint: Bool) -> String {
        let what = DriverUpdate.summary(from: installed.revision, to: bundled.revision).map { ": \($0)." } ?? "."
        return "A newer EQ driver is in this eq (" + Paint.ink(.bold, "build \(installed.revision) → \(bundled.revision)", on: paint) + ")" + what + "\n"
            + Paint.ink(.yellow, "Update it now?", on: paint) + " sudo asks for your password; sound drops for about a second. [y/N] "
    }

    static func offerDriverUpdate(_ args: [String], _ ctx: CLIContext) {
        guard let prompt = ctx.driverPrompt, driverPromptApplies(to: args, environment: prompt.environment), prompt.interactive() else { return }
        let files = ctx.driverFiles()
        let declined = RevisionMarker(url: ctx.stateDirectory.appendingPathComponent(DriverUpdate.declinedName))
        guard let installed = files.installed, let bundled = files.bundled, installed.revision < bundled.revision,
              !declined.covers(bundled.revision),
              (try? loadConfig(ctx))?.audioMode == .driver,
              let runtime = try? driverRuntime(ctx),
              [.update, .replace].contains(DriverInstall.need(runtime, installed: installed, bundled: bundled)) else { return }
        let paint = Paint.enabled(fd: 2)
        let answer = prompt.ask(driverPromptQuestion(from: installed, to: bundled, paint: paint))?.trimmingCharacters(in: .whitespaces).lowercased()
        guard answer == "y" || answer == "yes" else {
            do { try declined.write(bundled.revision) } catch { ctx.warn(Paint.ink(.yellow, "warning:", on: paint) + " cannot remember the answer: \(error)") }
            return
        }
        do {
            ctx.warn(try mode(["driver"], ctx).text)
        } catch {
            ctx.warn(Paint.ink(.red, "error:", on: paint) + " \(error)")
        }
    }
}
