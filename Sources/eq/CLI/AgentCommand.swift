import Foundation

/// `eq agent install|uninstall|status`: hidden, for the cask and for troubleshooting. Every other
/// command already registers the agent on its own when nothing runs the daemon.
extension CLI {
    struct AgentReport: Encodable {
        var launcher: Launcher
        var service: AgentServiceStatus
        var loaded: Bool
        var pid: Int32?
        var path: String?
        var bundle: String?
        var action: String?
        var setAside: String?
    }

    static func agent(_ args: [String], _ ctx: CLIContext) throws -> Output {
        let usage = "eq agent install [--replace-legacy] | eq agent uninstall [--for-upgrade] | eq agent status"
        guard let agent = ctx.agent else { throw CLIError.agent("not available here") }
        // LaunchServices may still append a process serial number when the cask opens EQ.app.
        let args = args.filter { !$0.hasPrefix("-psn_") }
        switch (args.first, Array(args.dropFirst())) {
        case ("status", let rest) where rest.isEmpty:
            let report = agentReport(agent)
            return Output(agentLines(report).joined(separator: "\n"), report)
        case ("install", let rest) where rest.isEmpty || rest == ["--replace-legacy"]:
            try? FileManager.default.removeItem(at: ctx.agentOptOutMarker)
            let result = try LaunchAgent.install(agent, replaceLegacy: !rest.isEmpty)
            var report = agentReport(agent)
            let aside: URL?
            switch result {
            case .alreadyRunning:
                report.action = "none"
                return Output("the eq daemon already runs as login item \"\(LaunchAgent.loginItemName)\"", report)
            case .started(let moved): report.action = "started"; aside = moved
            case .restarted(let moved): report.action = "restarted"; aside = moved
            }
            report.setAside = aside?.path
            var lines = aside.map { ["moved the legacy plist to " + Paint.ink(.dim, LaunchAgent.abbreviate($0.path))] } ?? []
            lines.append(Paint.ink(.green, "started") + " the eq daemon (login item \"\(LaunchAgent.loginItemName)\") — \(LaunchAgent.permissionPrompt)")
            return Output(lines.joined(separator: "\n"), report)
        // The cask's uninstall step runs on every upgrade too, so it leaves eq free to start again.
        case ("uninstall", let rest) where rest.isEmpty || rest == ["--for-upgrade"]:
            if rest.isEmpty { try optOut(ctx) }
            let removed = try LaunchAgent.uninstall(agent)
            var report = agentReport(agent)
            report.action = removed ? "removed" : "none"
            var text = removed ? Paint.ink(.green, "removed") + " the login item; the eq daemon is stopped"
                               : "the bundled login item was not registered"
            if rest.isEmpty { text += "; it stays off until eq agent install" }
            return Output(text, report)
        default:
            throw CLIError.usage(usage)
        }
    }

    private static func optOut(_ ctx: CLIContext) throws {
        do {
            try FileManager.default.createDirectory(at: ctx.stateDirectory, withIntermediateDirectories: true)
            try Data().write(to: ctx.agentOptOutMarker)
        } catch {
            throw CLIError.agent("cannot write \(LaunchAgent.abbreviate(ctx.agentOptOutMarker.path)), so the next eq command would start it again: "
                + LaunchAgent.describe(error))
        }
    }

    private static func agentReport(_ agent: LaunchAgentControl) -> AgentReport {
        let job = agent.loadedJob()
        let launcher = LaunchAgent.launcher(agent)
        return AgentReport(launcher: launcher, service: agent.serviceStatus, loaded: job != nil, pid: job?.pid,
                           path: job?.path ?? (agent.legacyPlistExists() ? agent.legacyPlist.path : nil), bundle: agent.bundlePath)
    }

    private static func agentLines(_ report: AgentReport) -> [String] {
        func label(_ text: String) -> String { Paint.ink(.dim, text + ":") }
        return [
            "\(label("launcher")) \(LaunchAgent.summary(report.launcher).detail)",
            "\(label("service")) \(report.service.rawValue)",
            "\(label("job")) " + (report.loaded ? "loaded" + (report.pid.map { ", pid \($0)" } ?? ", not running") : "not loaded"),
            "\(label("bundle")) \(report.bundle ?? "none (not running from EQ.app)")",
        ]
    }
}
