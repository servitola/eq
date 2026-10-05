import Foundation

/// Holds the hardware mute of every silent output that is connected, whether it plays or not, so that
/// sound macOS moves onto it (headphones dropping) is muted from the first sample, before the daemon
/// has even heard of the switch. Anything that unmutes it, volume keys or Control Center, is undone
/// at once. The mute each device had before eq first set it is kept on disk, and put back when it is
/// no longer silent: at once if it is connected, else when it next appears. Devices that were never
/// silent are never touched.
final class SilentGuard {
    enum Action: String, Codable, Equatable {
        /// eq set its mute.
        case muted
        /// Something unmuted it; eq muted it again.
        case remuted
        /// No longer silent; its mute is what it was before.
        case restored
        /// It has no mute eq can set; only the zeros eq plays keep it silent.
        case unmutable
    }

    struct State: Equatable {
        var connected: Bool
        /// nil: no mute eq can set.
        var muted: Bool?
    }

    private let control: MuteControl
    private let file: URL
    private let log: (String) -> Void
    private let onAction: (String, Action) -> Void
    private var silent: Set<String> = []
    /// What each element was before eq muted it, by UID and element.
    private var before: [String: [String: Bool]]
    private var watched: Set<String> = []
    private var unmutable: Set<String> = []
    private(set) var states: [String: State] = [:]

    init(control: MuteControl, file: URL, log: @escaping (String) -> Void = Log.write,
         onAction: @escaping (String, Action) -> Void = { _, _ in }) {
        self.control = control
        self.file = file
        self.log = log
        self.onAction = onAction
        before = (try? JSONDecoder().decode([String: [String: Bool]].self, from: Data(contentsOf: file))) ?? [:]
    }

    /// The config's silent outputs, or the devices, changed.
    func update(_ uids: Set<String>) {
        silent = uids
        for uid in silent.sorted() { hold(uid) }
        for uid in Set(before.keys).subtracting(silent).sorted() { restore(uid) }
        for uid in watched.subtracting(silent) {
            control.unwatch(uid)
            watched.remove(uid)
        }
        states = states.filter { silent.contains($0.key) }
        unmutable.formIntersection(silent)
    }

    private func hold(_ uid: String) {
        guard let elements = control.muteElements(uid) else {
            states[uid] = State(connected: false, muted: nil)
            if watched.remove(uid) != nil { control.unwatch(uid) }
            return
        }
        guard !elements.isEmpty else {
            states[uid] = State(connected: true, muted: nil)
            if unmutable.insert(uid).inserted {
                log("silent: \(uid) has no mute eq can set — only the zeros eq plays keep it silent")
                onAction(uid, .unmutable)
            }
            return
        }
        if before[uid] == nil {
            before[uid] = Dictionary(uniqueKeysWithValues: elements.map { (String($0), control.isMuted(uid, $0) ?? false) })
            save()
        }
        if mute(uid, elements) { onAction(uid, .muted) }
        // Again on every update: a device that left and came back between two of them has a new ID.
        watched.insert(uid)
        control.watch(uid, elements) { [weak self] in self?.enforce(uid) }
    }

    /// Mutes every element that is not; true when it changed one.
    private func mute(_ uid: String, _ elements: [UInt32]) -> Bool {
        var changed = false
        for element in elements where control.isMuted(uid, element) != true {
            if control.setMuted(uid, element, true) { changed = true } else { log("silent: cannot mute \(uid) (element \(element))") }
        }
        states[uid] = State(connected: true, muted: elements.allSatisfy { control.isMuted(uid, $0) == true })
        return changed
    }

    private func enforce(_ uid: String) {
        guard silent.contains(uid), let elements = control.muteElements(uid), !elements.isEmpty else { return }
        guard mute(uid, elements) else { return }
        log("silent: \(uid) was unmuted — muted again")
        onAction(uid, .remuted)
    }

    private func restore(_ uid: String) {
        guard let elements = control.muteElements(uid), let was = before[uid] else { return }
        for element in elements {
            guard let muted = was[String(element)] else { continue }
            if !control.setMuted(uid, element, muted) { log("silent: cannot put back the mute of \(uid) (element \(element))") }
        }
        before[uid] = nil
        save()
        onAction(uid, .restored)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if before.isEmpty {
                try? FileManager.default.removeItem(at: file)
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(before).write(to: file, options: .atomic)
            }
        } catch {
            log("silent: cannot keep the mutes to put back in \(file.path): \(error)")
        }
    }
}
