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
        try Self.decode(Data(contentsOf: url))
    }

    func load(backup index: Int) throws -> Config {
        try Self.decode(Data(contentsOf: backupURL(index)))
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
            // copyItem also keeps the version's own modification time, which `eq undo --list` shows.
            try FileManager.default.copyItem(at: url, to: backupURL(1))
        }
        try data.write(to: url, options: .atomic)
    }

    private func rotateBackups() throws {
        let files = FileManager.default
        try? files.removeItem(at: backupURL(Self.backupCount))
        for index in stride(from: Self.backupCount - 1, through: 1, by: -1) where files.fileExists(atPath: backupURL(index).path) {
            try files.moveItem(at: backupURL(index), to: backupURL(index + 1))
        }
    }

    /// Injectable so tests can simulate a filesystem where the syscall lies (see below).
    static var swap: (_ from: String, _ to: String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_SWAP)) }

    /// Swaps rather than rotates, so restoring `.1` twice returns to where it started.
    func restore(backup index: Int) throws {
        let backup = backupURL(index)
        let restored = try Data(contentsOf: backup)
        _ = try Self.decode(restored)
        // Read before the swap: on FAT/exFAT volumes renamex_np(RENAME_SWAP) has been observed
        // to return 0 (success) while actually performing a plain rename — which moves the backup
        // onto the current path and leaves nothing at the backup path, silently destroying the
        // current config. Keeping our own copy of it lets us recover from exactly that case.
        let current = try? Data(contentsOf: url)
        if Self.swap(backup.path, url.path) == 0 {
            if !FileManager.default.fileExists(atPath: backup.path), let current {
                try current.write(to: backup, options: .atomic)
            }
            return
        }
        guard let current else {
            try restored.write(to: url, options: .atomic)
            return
        }
        try current.write(to: backup, options: .atomic)
        try restored.write(to: url, options: .atomic)
    }

    func loadOrCreate(builtInUID: String?, builtInName: String?) throws -> Config {
        if exists() { return try load() }
        let config = Config.initial(builtInUID: builtInUID, builtInName: builtInName)
        try save(config)
        return config
    }
}
