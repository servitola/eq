import CryptoKit
import Foundation

struct ConfigStore {
    let url: URL
    /// The path messages name: a dry run's sandbox copy still speaks of the real file.
    var displayPath: String

    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["EQ_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/eq/eq.json")
    }

    init(url: URL, displayPath: String? = nil) {
        self.url = url
        self.displayPath = displayPath ?? url.path
    }

    func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static let backupCount = 10

    func backupURL(_ index: Int) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(index)")
    }

    func backups() -> [(index: Int, url: URL, date: Date)] {
        (1...Self.backupCount).compactMap { index in
            let backup = backupURL(index)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: backup.path),
                  let date = attributes[.modificationDate] as? Date else { return nil }
            return (index, backup, date)
        }
    }

    func load() throws -> Config {
        try load(at: url)
    }

    func load(backup index: Int) throws -> Config {
        try load(at: backupURL(index))
    }

    func load(at fileURL: URL) throws -> Config {
        try Self.decode(Data(contentsOf: fileURL))
    }

    private static func decode(_ data: Data) throws -> Config {
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigError.invalidJSON(String(describing: error))
        }
        try config.validate()
        return config
    }

    /// What a save is for decides what it does to undo state.
    enum SaveKind {
        /// A user's change: the previous file becomes `.1` and a redo branch in progress ends.
        case edit
        /// A later save of one `eq watch` session, which folds into the session's one backup —
        /// unless an `eq undo` elsewhere moved the file meanwhile; then it is an `edit`, or the
        /// next redo would overwrite it with the stashed latest.
        case sessionEdit
        /// The daemon's own upkeep (a device rename, seeding presets): the undo position stays.
        case bookkeeping
    }

    func save(_ config: Config, as kind: SaveKind = .edit) throws {
        try config.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = try? Data(contentsOf: url)
        // A no-op save must not touch undo state: `eq on` while already on would otherwise drop redo.
        // Decoded, not bytes: a backup written by an older version or by hand is formatted differently.
        if let previous, (try? JSONDecoder().decode(Config.self, from: previous)) == config { return }
        let position = historyPosition()
        switch position > 0 && kind == .sessionEdit ? .edit : kind {
        case .edit:
            // `.pos` goes first: a crash while the chain rotates then leaves a `.redo` at position 0,
            // which `reconcileHistory` pushes into the chain instead of trusting a shifted position.
            try? FileManager.default.removeItem(at: positionURL)
            if previous != nil {
                // The abandoned latest version goes into the chain first, so `eq history` still shows it
                // and the version being edited lands on top as `.1` — what the next `eq undo` returns to.
                if position > 0 { try pushRedoIntoChain() }
                // Copied, not moved: the daemon's watcher must never catch the directory without a config.
                // copyItem also keeps the version's own modification time, which `eq history` shows.
                try pushBackup(url, move: false)
            }
        case .sessionEdit:
            break
        case .bookkeeping:
            // Recording the new content keeps it from reading as a hand edit; a hand edit already on
            // disk stays detectable.
            if position > 0, liveMatchesPosition() { try setHistoryPosition(position, content: data) }
        }
        try data.write(to: url, options: .atomic)
    }

    /// Runs after each file the chain rotation moves; tests throw from it to simulate a crash.
    var afterRotationStep: () throws -> Void = {}

    private func rotateBackups() throws {
        let files = FileManager.default
        try? files.removeItem(at: backupURL(Self.backupCount))
        for index in stride(from: Self.backupCount - 1, through: 1, by: -1) where files.fileExists(atPath: backupURL(index).path) {
            try files.moveItem(at: backupURL(index), to: backupURL(index + 1))
            try afterRotationStep()
        }
    }

    private func pushBackup(_ file: URL, move: Bool) throws {
        try rotateBackups()
        if move {
            try FileManager.default.moveItem(at: file, to: backupURL(1))
        } else {
            try FileManager.default.copyItem(at: file, to: backupURL(1))
        }
    }

    private func pushRedoIntoChain() throws {
        guard FileManager.default.fileExists(atPath: redoURL.path) else { return }
        try pushBackup(redoURL, move: true)
    }

    private func sibling(_ suffix: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(suffix)")
    }

    /// Line 1: how many steps back; line 2: SHA-256 of the `eq.json` that step wrote, which is how a
    /// hand edit made mid-undo is told apart from the daemon's own bookkeeping saves.
    var positionURL: URL { sibling("pos") }
    /// Holds the content `eq.json` had before the first `eq undo` in the current chain, so `eq redo`
    /// can reach it again — the backup files themselves are never touched by undo/redo.
    var redoURL: URL { sibling("redo") }

    private func positionRecord() -> (raw: String, position: Int?, digest: String?)? {
        guard let text = try? String(contentsOf: positionURL, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let raw = lines.first ?? ""
        return (raw, Int(raw), lines.count > 1 ? lines[1] : nil)
    }

    /// How many steps `eq.json` currently sits back from the latest edit; 0 means `eq undo` has
    /// not been used, or `eq redo` has walked all the way back to it.
    func historyPosition() -> Int {
        guard let n = positionRecord()?.position, n > 0 else { return 0 }
        return n
    }

    private func setHistoryPosition(_ n: Int, content: Data) throws {
        if n <= 0 {
            try? FileManager.default.removeItem(at: positionURL)
        } else {
            try "\(n)\n\(Self.digest(content))\n".write(to: positionURL, atomically: true, encoding: .utf8)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A `.pos` without a digest predates it; the backup it points at is then the reference.
    private func liveMatchesPosition() -> Bool {
        guard let record = positionRecord(), let n = record.position,
              let live = try? Data(contentsOf: url) else { return false }
        if let digest = record.digest { return Self.digest(live) == digest }
        return (try? Data(contentsOf: backupURL(n))) == live
    }

    /// Brings the undo bookkeeping back in line with the files before a step, without losing a
    /// version: an out-of-range `.pos` or an `eq.json` edited by hand mid-undo resets to position 0,
    /// pushing the stashed latest version (and the version the edit started from) into the chain.
    /// Returns a note for the user when it had to do that.
    @discardableResult
    func reconcileHistory() throws -> String? {
        let files = FileManager.default
        guard let record = positionRecord() else {
            // Position 0 with a leftover stash: a step toward the latest edit stopped between writing
            // `.pos` and `eq.json`. Keep that version unless it is the live file anyway.
            guard files.fileExists(atPath: redoURL.path) else { return nil }
            if (try? Data(contentsOf: redoURL)) == (try? Data(contentsOf: url)) {
                try? files.removeItem(at: redoURL)
            } else {
                try pushRedoIntoChain()
            }
            return nil
        }
        guard let n = record.position, n > 0, n <= Self.backupCount, files.fileExists(atPath: backupURL(n).path) else {
            try pushRedoIntoChain()
            try? files.removeItem(at: positionURL)
            return "\(positionURL.lastPathComponent) says \u{201C}\(record.raw)\u{201D}, which is not a saved version; "
                + "treated the live config as the latest (the stashed latest, if any, is now eq.json.1)"
        }
        guard !liveMatchesPosition() else { return nil }
        let staged = sibling("base")
        try? files.removeItem(at: staged)
        try files.copyItem(at: backupURL(n), to: staged)
        try pushRedoIntoChain()
        try pushBackup(staged, move: true)
        try? files.removeItem(at: positionURL)
        return "\(url.lastPathComponent) was changed by hand \(n) step\(n == 1 ? "" : "s") back; kept it as the latest "
            + "version — the version it started from and the previous latest are in eq history"
    }

    /// The version `eq history` shows at position 0: whatever is live when nothing has been undone,
    /// or the stashed pre-undo content while a chain is in progress.
    func latestVersion() -> (url: URL, date: Date)? {
        let source = historyPosition() == 0 ? url : redoURL
        guard let date = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date else { return nil }
        return (source, date)
    }

    /// Steps `eq.json` one version further into the backup chain — `.1` first, then `.2`, and so
    /// on with each further call. Returns `nil` once there is nothing further back. Throws
    /// `ConfigError` and leaves every file untouched if the backup is not valid JSON.
    func stepBack() throws -> (index: Int, date: Date)? {
        try reconcileHistory()
        let position = historyPosition()
        let target = position + 1
        guard let backup = backups().first(where: { $0.index == target }) else { return nil }
        let data = try Data(contentsOf: backup.url)
        _ = try Self.decode(data)
        if position == 0 {
            try? FileManager.default.removeItem(at: redoURL)
            try FileManager.default.copyItem(at: url, to: redoURL)
        }
        // `.pos` first: a crash in between then reads as a hand edit, which keeps every version.
        try setHistoryPosition(target, content: data)
        try data.write(to: url, options: .atomic)
        return (target, backup.date)
    }

    /// The inverse of `stepBack()`: walks back toward the latest edit. Returns `nil` at position 0.
    func stepForward() throws -> (index: Int, date: Date)? {
        try reconcileHistory()
        let position = historyPosition()
        guard position > 0 else { return nil }
        let target = position - 1
        let data: Data
        let date: Date
        if target == 0 {
            guard let redone = try? Data(contentsOf: redoURL),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: redoURL.path),
                  let redoDate = attrs[.modificationDate] as? Date else {
                // The stash is missing — nothing sane to redo to; drop the stale position rather
                // than leave `eq undo`/`eq redo` disagreeing about where they are.
                try? FileManager.default.removeItem(at: positionURL)
                return nil
            }
            data = redone
            date = redoDate
        } else {
            guard let backup = backups().first(where: { $0.index == target }) else { return nil }
            data = try Data(contentsOf: backup.url)
            date = backup.date
        }
        _ = try Self.decode(data)
        try setHistoryPosition(target, content: data)
        try data.write(to: url, options: .atomic)
        if target == 0 { try? FileManager.default.removeItem(at: redoURL) }
        return (target, date)
    }

    /// A missing file stands for the config `eq init` would write; it stays in memory until
    /// something changes it, and that save creates the file.
    func loadOrDefault(builtIn: () -> (uid: String, name: String)?) throws -> Config {
        if exists() { return try load() }
        let device = builtIn()
        return Config.initial(builtInUID: device?.uid, builtInName: device?.name)
    }

    func loadOrCreate(builtInUID: String?, builtInName: String?) throws -> Config {
        if exists() { return try load() }
        let config = Config.initial(builtInUID: builtInUID, builtInName: builtInName)
        try save(config)
        return config
    }
}
