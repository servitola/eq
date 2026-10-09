import Darwin
import Foundation
import UserNotifications

/// The daemon's one notification per newer driver EQ.app carries; clicking it installs that driver
/// through the macOS administrator dialog, as `eq mode driver` run without a terminal does.
struct DriverUpdateNotice: Equatable {
    static let category = "driver-update"

    var title: String
    var body: String

    /// Only while the driver plays (the caller is the daemon in driver mode), only for an installed
    /// driver older than the bundled one, and once per bundled revision.
    static func due(_ files: DriverFiles, notified: Int?) -> DriverUpdateNotice? {
        guard let installed = files.installed, let bundled = files.bundled, installed.revision < bundled.revision,
              (notified ?? Int.min) < bundled.revision else { return nil }
        let what = DriverUpdate.summary(from: installed.revision, to: bundled.revision).map { ": \($0)." } ?? "."
        return DriverUpdateNotice(title: "EQ driver update", body: "Build \(installed.revision) → \(bundled.revision)\(what) Click to install.")
    }

    static func isInstallClick(category: String, action: String) -> Bool {
        category == Self.category && action == UNNotificationDefaultActionIdentifier
    }

    /// What the user sees once the click's `eq mode driver` is done.
    static func result(status: Int32, output: String) -> DriverUpdateNotice {
        guard status != 0 else { return DriverUpdateNotice(title: "EQ driver updated", body: "Driver mode plays through the new driver.") }
        let why = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return DriverUpdateNotice(title: "EQ driver not updated", body: (why ?? "eq mode driver exited with status \(status)") + " — run eq mode driver in a terminal.")
    }
}

/// Remembers, before posting, the revision it notified about: a failed post is not retried on every
/// daemon start, and a file it cannot write means no notification rather than one per start.
final class DriverUpdateNotifier {
    private let marker: RevisionMarker
    private let post: (DriverUpdateNotice) -> Void

    init(marker: RevisionMarker, post: @escaping (DriverUpdateNotice) -> Void) {
        self.marker = marker
        self.post = post
    }

    func check(_ files: DriverFiles) {
        guard let notice = DriverUpdateNotice.due(files, notified: marker.read()), let revision = files.bundled?.revision else { return }
        do {
            try marker.write(revision)
        } catch {
            Log.write("driver update: cannot remember the notification (\(error)); not posting it")
            return
        }
        post(notice)
    }
}

/// Notification Center as EQ.app: UNUserNotificationCenter raises outside an app bundle, so a daemon
/// run from a build folder posts nothing. A click goes to the running process of the bundle that posted,
/// or LaunchServices starts EQ.app without arguments to take it (see `awaitClick`).
enum UserNotices {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    private static let responder = NoticeResponder()

    static func listen(onInstall: @escaping () -> Void) {
        guard available else { return }
        responder.onInstall = onInstall
        UNUserNotificationCenter.current().delegate = responder
    }

    /// The first request shows macOS's prompt to allow EQ's notifications; a refusal is final until
    /// the user changes it in System Settings, so it is only logged.
    static func post(_ notice: DriverUpdateNotice) {
        guard available else {
            Log.write("driver update: \(notice.body) (no notification outside EQ.app)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                Log.write("driver update: EQ may not post notifications" + (error.map { " (\($0.localizedDescription))" } ?? ""))
                return
            }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.categoryIdentifier = DriverUpdateNotice.category
            center.add(UNNotificationRequest(identifier: DriverUpdateNotice.category, content: content, trigger: nil)) { error in
                if let error { Log.write("driver update: cannot post the notification: \(error.localizedDescription)") }
            }
        }
    }

    /// LaunchServices starts an app without arguments to hand it a click, and launchd is its parent;
    /// `eq` typed in a shell has a terminal, and the LaunchAgent passes `daemon`.
    static func launchedForClick(arguments: [String], parent: pid_t, stdinIsTTY: Bool, inApp: Bool = available) -> Bool {
        arguments.isEmpty && parent == 1 && !stdinIsTTY && inApp
    }

    /// Waits a few seconds for the click that launched this process; once one arrives, until its
    /// install is done, however long the password dialog stays open.
    static func awaitClick(seconds: TimeInterval) -> Never {
        let state = ClickState()
        listen {
            state.started()
            DriverUpdateInstaller.run()
            state.finished()
        }
        let deadline = Date().addingTimeInterval(seconds)
        while state.waiting(until: deadline) { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        exit(0)
    }
}

private final class ClickState {
    private let lock = NSLock()
    private var running = false
    private var done = false

    func started() { lock.lock(); running = true; lock.unlock() }
    func finished() { lock.lock(); done = true; lock.unlock() }

    func waiting(until deadline: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !done && (running || Date() < deadline)
    }
}

final class NoticeResponder: NSObject, UNUserNotificationCenterDelegate {
    var onInstall: () -> Void = {}

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        if DriverUpdateNotice.isInstallClick(category: content.categoryIdentifier, action: response.actionIdentifier) { onInstall() }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

/// `eq mode driver` in a session of its own: with no controlling terminal it takes the dialog, never a
/// sudo prompt on a terminal the daemon may have been started from. One at a time.
enum DriverUpdateInstaller {
    private static let lock = NSLock()
    private static var running = false

    static func run() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }
        guard let executable = Bundle.main.executablePath else { return }
        let (status, output) = spawn(executable, ["mode", "driver"])
        Log.write("driver update: eq mode driver exited with status \(status)" + (output.isEmpty ? "" : ": " + output.replacingOccurrences(of: "\n", with: "; ")))
        UserNotices.post(DriverUpdateNotice.result(status: status, output: output))
    }

    private static func spawn(_ executable: String, _ words: [String]) -> (Int32, String) {
        var pipes: [Int32] = [-1, -1]
        guard pipe(&pipes) == 0 else { return (1, "cannot open a pipe") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipes[1], 1)
        posix_spawn_file_actions_adddup2(&actions, pipes[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        let argv = ([executable] + words).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var child: pid_t = 0
        let spawned = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        close(pipes[1])
        defer { close(pipes[0]) }
        guard spawned == 0 else { return (1, "cannot run \(executable): \(String(cString: strerror(spawned)))") }
        let output = FileHandle(fileDescriptor: pipes[0], closeOnDealloc: false).readDataToEndOfFile()
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return (code, String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
