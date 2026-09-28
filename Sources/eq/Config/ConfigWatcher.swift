import Foundation

/// Watches the config's directory, not the file: `Data.write(options: .atomic)` replaces the
/// inode, so a file-level vnode source would go stale after the first save. Until the directory
/// exists it watches the nearest ancestor that does, stepping down as each level appears, so a
/// config first written long after the daemon started is still picked up.
final class ConfigWatcher {
    private let directory: URL
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var watched: URL?
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, queue: DispatchQueue, debounce: TimeInterval = 0.1, onChange: @escaping () -> Void) {
        self.directory = url.deletingLastPathComponent().standardizedFileURL
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        follow()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        watched = nil
    }

    private func nearestExisting() -> URL {
        var candidate = directory
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    private func watch(_ target: URL) {
        source?.cancel()
        source = nil
        watched = target
        let descriptor = open(target.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.write("config watcher: cannot open \(target.path) (errno \(errno))")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func changed() {
        follow()
        schedule()
    }

    /// Re-checked after every switch: a level can appear between finding it missing and opening its parent.
    private func follow() {
        var target = nearestExisting()
        while target.path != watched?.path {
            watch(target)
            target = nearestExisting()
        }
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
