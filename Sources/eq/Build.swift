import Foundation

enum Build {
    static let bundleID = "com.servitola.eq"
    static let version = info["CFBundleShortVersionString"] as? String ?? "dev"
    /// The commit count build-app.sh stamps in; none outside EQ.app.
    static let build = info["CFBundleVersion"] as? String

    // Bundle.main looks next to the invoked path, and /opt/homebrew/bin/eq is a symlink with no
    // Info.plist beside it — so resolve to the real binary inside EQ.app first.
    private static let info: NSDictionary = {
        let argv0 = CommandLine.arguments.first ?? ""
        // A PATH lookup leaves argv[0] as a bare "eq", which would resolve against the cwd.
        let invoked = argv0.contains("/") ? URL(fileURLWithPath: argv0) : Bundle.main.executableURL
        guard let exe = invoked?.resolvingSymlinksInPath() else { return [:] }
        let macOS = exe.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS" else { return [:] }
        let plist = macOS.deletingLastPathComponent().appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: plist) ?? [:]
    }()
}
