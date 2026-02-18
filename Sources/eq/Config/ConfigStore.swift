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

    func load() throws -> Config {
        let data = try Data(contentsOf: url)
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigError.invalidJSON(String(describing: error))
        }
        try config.validate()
        return config
    }

    func save(_ config: Config) throws {
        try config.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func loadOrCreate(builtInUID: String?, builtInName: String?) throws -> Config {
        if exists() { return try load() }
        let config = Config.initial(builtInUID: builtInUID, builtInName: builtInName)
        try save(config)
        return config
    }
}
