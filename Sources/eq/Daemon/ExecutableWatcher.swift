import Darwin
import Foundation

/// `brew upgrade` moves the old EQ.app out of /Applications and the new one in: the path keeps
/// its name but names another file, and the daemon would run the old binary until logout.
/// Renaming the bundle tells the binary's own descriptor nothing, so the folder holding the
/// bundle is watched too, and every event ends in comparing the path's file with the one that
/// started. A path missing for `patience` checks in a row is an uninstall.
final class ExecutableWatcher {
    enum Change: Equatable {
        case replaced
        case removed
    }

    private struct Identity: Equatable {
        var device: dev_t
        var inode: ino_t
        var modified: timespec

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            modified = info.st_mtimespec
        }

        static func == (a: Identity, b: Identity) -> Bool {
            a.device == b.device && a.inode == b.inode
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    private let path: String
    private let queue: DispatchQueue
    private let patience: Int
    private let onChange: (Change) -> Void
    private var original: Identity?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var missing = 0
    private lazy var settle = Debouncer(delay: settleDelay, queue: queue) { [weak self] in self?.check() }
    private let settleDelay: TimeInterval

    init(path: String, queue: DispatchQueue, settle: TimeInterval = 2, patience: Int = 30, onChange: @escaping (Change) -> Void) {
        self.path = path
        self.queue = queue
        self.settleDelay = settle
        self.patience = patience
        self.onChange = onChange
    }

    /// The folder holding the .app for a bundled binary, the binary's own folder otherwise.
    static func watchedDirectory(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let app = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = app.pathExtension == "app" ? app.deletingLastPathComponent() : url.deletingLastPathComponent()
        return folder.path
    }

    func start() {
        guard sources.isEmpty, let identity = Identity(path: path) else { return }
        original = identity
        watch(path, events: [.delete, .rename, .write, .link, .revoke])
        watch(Self.watchedDirectory(for: path), events: [.write])
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
        settle.cancel()
    }

    private func watch(_ target: String, events: DispatchSource.FileSystemEvent) {
        let descriptor = open(target, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.write("executable watcher: cannot open \(target) (errno \(errno))")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: events, queue: queue)
        source.setEventHandler { [weak self] in self?.settle.trigger() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources.append(source)
    }

    private func check() {
        guard !sources.isEmpty else { return }
        guard let now = Identity(path: path) else {
            missing += 1
            if missing >= patience { fire(.removed) } else { settle.trigger() }
            return
        }
        missing = 0
        if now != original { fire(.replaced) }
    }

    private func fire(_ change: Change) {
        stop()
        onChange(change)
    }
}
