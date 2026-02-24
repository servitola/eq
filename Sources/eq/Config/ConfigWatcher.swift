import Foundation

/// Watches the config's directory, not the file: `Data.write(options: .atomic)` replaces the
/// inode, so a file-level vnode source would go stale after the first save.
final class ConfigWatcher {
    private let directory: URL
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var descriptor: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, queue: DispatchQueue, debounce: TimeInterval = 0.1, onChange: @escaping () -> Void) {
        self.directory = url.deletingLastPathComponent()
        self.queue = queue
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.write("config watcher: cannot open \(directory.path) (errno \(errno))")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
