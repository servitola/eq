import Foundation

struct ConfigStore {
    let url: URL

    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["EQ_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/eq/eq.json")
    }

    init(url: URL) {
        self.url = url
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

    func save(_ config: Config, backup: Bool = true) throws {
        try config.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backup, let previous = try? Data(contentsOf: url), previous != data {
            try rotateBackups()
            // Copied, not moved: the daemon's watcher must never catch the directory without a config.
            // copyItem also keeps the version's own modification time, which `eq history` shows.
            try FileManager.default.copyItem(at: url, to: backupURL(1))
        }
        try data.write(to: url, options: .atomic)
        // A real edit abandons whatever `eq undo` chain was in progress — there is nothing left to redo.
        clearHistoryPosition()
    }

    private func rotateBackups() throws {
        let files = FileManager.default
        try? files.removeItem(at: backupURL(Self.backupCount))
        for index in stride(from: Self.backupCount - 1, through: 1, by: -1) where files.fileExists(atPath: backupURL(index).path) {
            try files.moveItem(at: backupURL(index), to: backupURL(index + 1))
        }
    }

    var positionURL: URL { url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).pos") }
    /// Holds the content `eq.json` had before the first `eq undo` in the current chain, so `eq redo`
    /// can reach it again — the backup files themselves are never touched by undo/redo.
    var redoURL: URL { url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).redo") }

    /// How many steps `eq.json` currently sits back from the latest edit; 0 means `eq undo` has
    /// not been used, or `eq redo` has walked all the way back to it.
    func historyPosition() -> Int {
        guard let raw = try? String(contentsOf: positionURL, encoding: .utf8),
              let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 else { return 0 }
        return n
    }

    private func setHistoryPosition(_ n: Int) throws {
        if n <= 0 {
            try? FileManager.default.removeItem(at: positionURL)
        } else {
            try String(n).write(to: positionURL, atomically: true, encoding: .utf8)
        }
    }

    private func clearHistoryPosition() {
        try? FileManager.default.removeItem(at: positionURL)
        try? FileManager.default.removeItem(at: redoURL)
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
        let target = historyPosition() + 1
        guard let backup = backups().first(where: { $0.index == target }) else { return nil }
        let data = try Data(contentsOf: backup.url)
        _ = try Self.decode(data)
        if historyPosition() == 0 {
            try? FileManager.default.removeItem(at: redoURL)
            try FileManager.default.copyItem(at: url, to: redoURL)
        }
        try data.write(to: url, options: .atomic)
        try setHistoryPosition(target)
        return (target, backup.date)
    }

    /// The inverse of `stepBack()`: walks back toward the latest edit. Returns `nil` at position 0.
    func stepForward() throws -> (index: Int, date: Date)? {
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
        try data.write(to: url, options: .atomic)
        try setHistoryPosition(target)
        if target == 0 { try? FileManager.default.removeItem(at: redoURL) }
        return (target, date)
    }

    func loadOrCreate(builtInUID: String?, builtInName: String?) throws -> Config {
        if exists() { return try load() }
        let config = Config.initial(builtInUID: builtInUID, builtInName: builtInName)
        try save(config)
        return config
    }
}
