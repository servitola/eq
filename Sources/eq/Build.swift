import Foundation

enum Build {
    // Bundle.main looks next to the invoked path, and /opt/homebrew/bin/eq is a symlink with no
    // Info.plist beside it — so resolve to the real binary inside EQ.app first.
    static let version: String = {
        let argv0 = CommandLine.arguments.first ?? ""
        // A PATH lookup leaves argv[0] as a bare "eq", which would resolve against the cwd.
        let invoked = argv0.contains("/") ? URL(fileURLWithPath: argv0) : Bundle.main.executableURL
        guard let exe = invoked?.resolvingSymlinksInPath() else { return "dev" }
        let macOS = exe.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS" else { return "dev" }
        let plist = macOS.deletingLastPathComponent().appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String ?? "dev"
    }()
}
