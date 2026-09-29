import Darwin
import Foundation
import Security

/// A driver bundle as its Info.plist describes it.
struct DriverBuild: Equatable, Encodable {
    var version: String
    /// Counts only the commits that change what goes into the bundle; 0 for a driver built before
    /// eq carried one, so any bundled driver replaces it.
    var revision: Int
    /// The settings record it speaks; nil for a driver built before the key existed.
    var protocolVersion: Int?

    enum CodingKeys: String, CodingKey { case version, revision, protocolVersion = "protocol" }

    init(version: String, revision: Int, protocolVersion: Int? = nil) {
        self.version = version
        self.revision = revision
        self.protocolVersion = protocolVersion
    }

    init?(bundle: URL) {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == DriverInstall.bundleID else { return nil }
        version = info["CFBundleShortVersionString"] as? String ?? "?"
        revision = (info["EQDriverRevision"] as? NSNumber)?.intValue ?? 0
        protocolVersion = (info["EQDriverProtocol"] as? NSNumber)?.intValue
    }

    var label: String { "build \(revision) (\(version))" }
}

/// The driver in /Library and the one inside this EQ.app.
struct DriverFiles: Equatable {
    var installed: DriverBuild?
    var bundled: DriverBuild?
    var bundledURL: URL?

    static func live(app: URL = Bundle.main.bundleURL) -> DriverFiles {
        let bundledURL = app.appendingPathComponent("Contents/PlugIns/EQDriver.driver")
        let bundled = app.pathExtension == "app" ? DriverBuild(bundle: bundledURL) : nil
        return DriverFiles(installed: DriverBuild(bundle: DriverInstall.installedURL), bundled: bundled,
                           bundledURL: bundled == nil ? nil : bundledURL)
    }

    /// The installed driver is older than the one this eq carries, and still works.
    var updateNote: String? {
        guard let installed, let bundled, installed.revision < bundled.revision else { return nil }
        return "the EQ driver is \(installed.label), this eq carries \(bundled.label) — run `eq mode driver` to update it"
    }
}

/// Getting the driver this eq carries into /Library/Audio/Plug-Ins/HAL and out again. Only `eq mode
/// driver` and `eq driver uninstall` do it, with one administrator prompt each; the daemon never asks.
enum DriverInstall {
    static let bundleID = "com.servitola.eq.driver"
    static let installedURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/EQDriver.driver")

    /// What the plug-in coreaudiod runs says, from ModeSwitch.ready().
    enum Runtime: Equatable {
        case absent
        case incompatible(Int?)
        case disabled
        case ready
    }

    enum Need: String, Encodable { case none, install, update, replace }

    enum Elevation: String, Encodable { case sudo, dialog }

    enum Role: Equatable {
        case cli(Elevation)
        case daemon
    }

    enum Plan: Equatable {
        case use
        /// The daemon plays the installed driver; the note says an update waits.
        case useOutdated(String)
        case install(Need, Elevation)
        /// Why driver mode cannot start, and what to run: the daemon's reason for the tap, the CLI's error.
        case unavailable(String)
    }

    /// A kill file is the user's own recovery step, so a disabled driver is never replaced behind their back.
    static func need(_ runtime: Runtime, installed: DriverBuild?, bundled: DriverBuild?) -> Need {
        switch runtime {
        case .absent: return .install
        case .incompatible: return .replace
        case .disabled: return .none
        case .ready:
            guard let installed, let bundled, installed.revision < bundled.revision else { return .none }
            return .update
        }
    }

    static func plan(_ runtime: Runtime, installed: DriverBuild?, bundled: DriverBuild?, role: Role) -> Plan {
        let need = need(runtime, installed: installed, bundled: bundled)
        switch (need, role) {
        case (.none, _): return .use
        case (.update, .daemon): return DriverFiles(installed: installed, bundled: bundled).updateNote.map(Plan.useOutdated) ?? .use
        case (_, .daemon):
            switch runtime {
            case .incompatible(let version): return .unavailable("\(ModeSwitch.Failure.tooOld(version))")
            case .absent where installed != nil: return .unavailable("the EQ device is missing")
            default: return .unavailable("\(ModeSwitch.Failure.notInstalled)")
            }
        case (_, .cli(let elevation)):
            guard bundled != nil else {
                let what: String
                if case .incompatible(let version) = runtime { what = tooOld(version) } else { what = "the EQ driver is not installed" }
                return .unavailable("\(what), and this eq carries no driver to install — build EQ.app with scripts/build-app.sh, or: sudo Driver/dev-install.sh")
            }
            return .install(need, elevation)
        }
    }

    static func tooOld(_ version: Int?) -> String {
        "the EQ driver speaks settings protocol \(version.map(String.init) ?? "0"), this eq needs \(DriverControl.requiredVersion)"
    }

    // MARK: - The privileged step

    enum Action: Equatable {
        case install(URL)
        case uninstall
    }

    /// Run as root, and only ever as `/bin/sh -c script eq-driver <arguments>`: every value arrives as
    /// its own argument and is only ever expanded in double quotes. It lives in the signed binary, not
    /// in a file beside it, so nothing can swap it between eq checking it and root running it. The copy
    /// is checked against the requirement after it is root-owned, for the same reason.
    static let script = #"""
        set -eu
        hal=/Library/Audio/Plug-Ins/HAL
        dst=$hal/EQDriver.driver
        stage=/Library/Audio/Plug-Ins/.EQDriver.driver.staging
        old=/Library/Audio/Plug-Ins/.EQDriver.driver.old
        case ${1-} in
          install)
            [ $# -eq 3 ] || { echo "usage: install <EQDriver.driver> <requirement>" >&2; exit 64; }
            case $2 in /*/EQDriver.driver) ;; *) echo "not an EQDriver.driver: $2" >&2; exit 64 ;; esac
            case $3 in 'identifier "com.servitola.eq.driver"'*) ;; *) echo "not a requirement for the EQ driver: $3" >&2; exit 64 ;; esac
            ;;
          uninstall) [ $# -eq 1 ] || { echo "usage: uninstall" >&2; exit 64; } ;;
          *) echo "usage: install <EQDriver.driver> <requirement> | uninstall" >&2; exit 64 ;;
        esac
        [ "$(/usr/bin/id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 77; }
        if [ "$1" = install ]; then
          /bin/rm -rf "$stage" "$old"
          /usr/bin/ditto "$2" "$stage"
          /usr/sbin/chown -R root:wheel "$stage"
          /bin/chmod -R go-w "$stage"
          if ! /usr/bin/codesign --verify --strict --test-requirement="=$3" "$stage"; then
            /bin/rm -rf "$stage"
            echo "the driver is not signed as eq requires: $3" >&2
            exit 65
          fi
          /bin/mkdir -p "$hal"
          if [ -e "$dst" ]; then /bin/mv "$dst" "$old"; fi
          /bin/mv "$stage" "$dst"
          /bin/rm -rf "$old"
        else
          [ -e "$dst" ] || exit 0
          /bin/rm -rf "$dst"
        fi
        /usr/bin/killall coreaudiod || :
        """#

    /// The driver must come from eq's own team; an ad-hoc eq (a local build) can only ask for the identifier.
    static func requirement(team: String?) -> String {
        let identifier = "identifier \"\(bundleID)\""
        guard let team, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return identifier }
        return identifier + " and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func arguments(_ action: Action, requirement: String) -> [String] {
        switch action {
        case .install(let source): return ["install", source.path, requirement]
        case .uninstall: return ["uninstall"]
        }
    }

    static func sudoCommand(_ action: Action, requirement: String) -> [String] {
        let prompt = action == .uninstall ? "Password to remove the EQ driver (%u): " : "Password to install the EQ driver (%u): "
        return ["/usr/bin/sudo", "-p", prompt, "/bin/sh", "-c", script, "eq-driver"] + arguments(action, requirement: requirement)
    }

    /// `quoted form of` quotes each argument for the shell `do shell script` starts, so no value is ever
    /// spliced into the command text.
    static func dialogCommand(_ action: Action, requirement: String) -> [String] {
        let prompt = action == .uninstall ? "eq wants to remove its audio driver." : "eq wants to install its audio driver."
        let applescript = """
            on run argv
              set command to "/bin/sh -c " & quoted form of item 1 of argv & " eq-driver"
              repeat with i from 3 to count of argv
                set command to command & " " & quoted form of item i of argv
              end repeat
              do shell script command with prompt (item 2 of argv) with administrator privileges
            end run
            """
        return ["/usr/bin/osascript", "-e", applescript, script, prompt] + arguments(action, requirement: requirement)
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case cancelled
        case failed(String)

        var description: String {
            switch self {
            case .cancelled: return "cancelled at the password prompt"
            case .failed(let why): return why
            }
        }
    }

    /// A terminal gets sudo, which asks on it; anything else (a launcher, a script without a terminal)
    /// gets the macOS dialog, which needs no terminal but does need someone at the screen.
    static func liveElevation() -> Elevation {
        let tty = open("/dev/tty", O_RDWR | O_NOCTTY)
        guard tty >= 0 else { return .dialog }
        close(tty)
        return .sudo
    }

    static func run(_ action: Action, _ elevation: Elevation) throws {
        let requirement = requirement(team: ownTeam())
        let command = elevation == .sudo ? sudoCommand(action, requirement: requirement) : dialogCommand(action, requirement: requirement)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let errors = Pipe()
        if elevation == .dialog { process.standardError = errors }
        do { try process.run() } catch { throw Failure.failed("cannot run \(command[0]): \(error)") }
        let message = elevation == .dialog ? String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) : ""
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        if message.contains("(-128)") { throw Failure.cancelled }
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        throw Failure.failed("\(command[0]) exited with status \(process.terminationStatus)" + (detail.isEmpty ? "" : ": \(detail)"))
    }

    static func ownTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Which `brew` command runs eq's cask uninstall step: Homebrew runs the same step on `brew upgrade`
/// and `brew reinstall`, and passes the step nothing that tells them apart, so eq reads the command
/// line of the nearest brew process above it.
enum BrewParent {
    /// Only these remove eq for good; anything else keeps the driver.
    static let removals: Set<String> = ["uninstall", "uninstal", "rm", "remove"]

    /// `uninstall` in `ruby -W1 --disable=gems,rubyopt …/Homebrew/brew.rb uninstall eq`: the first
    /// argument after brew.rb that is not a help flag, as brew.rb itself picks it.
    static func command(argv: [String]) -> String? {
        guard let script = argv.firstIndex(where: { $0.hasSuffix("/Homebrew/brew.rb") }) else { return nil }
        return argv[(script + 1)...].first { !["-h", "--help", "--usage", "-?"].contains($0) }
    }

    static func removes(_ command: String?) -> Bool { command.map(removals.contains) ?? false }

    static func live() -> String? {
        var pid = getppid()
        for _ in 0..<16 where pid > 1 {
            if let argv = arguments(of: pid), let command = command(argv: argv) { return command }
            guard let parent = parent(of: pid) else { return nil }
            pid = parent
        }
        return nil
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// KERN_PROCARGS2: argc, the executable path, padding, then argv.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var argv: [String] = []
        while argv.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            argv.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return argv
    }
}
