import Foundation

struct AutoEqEntry: Equatable {
    var name: String
    var path: String
    var source: String
}

enum AutoEqIndex {
    static let indexURL = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/INDEX.md")!
    static let base = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    static let cacheMaxAge: TimeInterval = 7 * 24 * 3600
    static let preferredSources = ["oratory1990", "crinacle", "Rtings"]

    enum Match: Equatable {
        case one(AutoEqEntry)
        case none
        case ambiguous([String])
    }

    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^- \[([^\]]+)\]\(\./(.+)\) by (.+?)(?: on .*)?$"#
    )

    static func parse(_ markdown: String) -> [AutoEqEntry] {
        markdown.components(separatedBy: .newlines).compactMap { line in
            let ns = line as NSString
            guard let m = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let name = ns.substring(with: m.range(at: 1))
            let encodedPath = ns.substring(with: m.range(at: 2))
            guard let path = encodedPath.removingPercentEncoding else { return nil }
            guard let source = path.split(separator: "/").first else { return nil }
            return AutoEqEntry(name: name, path: path, source: String(source))
        }
    }

    static func match(_ query: String, in entries: [AutoEqEntry], source: String?) -> Match {
        let lowerQuery = query.lowercased()
        var candidates = entries.filter { $0.name.lowercased().contains(lowerQuery) }
        let exact = candidates.filter { $0.name.lowercased() == lowerQuery }
        if !exact.isEmpty { candidates = exact }

        let uniqueNames = Set(candidates.map { $0.name.lowercased() })
        if uniqueNames.count > 1 {
            let names = Array(Set(candidates.map { $0.name })).sorted()
            return .ambiguous(names)
        }
        guard !candidates.isEmpty else { return .none }

        if let source {
            let bySource = candidates.filter { $0.source.lowercased() == source.lowercased() }
            guard let first = bySource.first else { return .none }
            return .one(first)
        }

        func rank(_ entry: AutoEqEntry) -> Int {
            preferredSources.firstIndex { $0.lowercased() == entry.source.lowercased() } ?? preferredSources.count
        }
        let ranked = candidates.sorted {
            let r0 = rank($0), r1 = rank($1)
            if r0 != r1 { return r0 < r1 }
            return $0.source < $1.source
        }
        return .one(ranked[0])
    }

    static func fileURL(for entry: AutoEqEntry) -> URL {
        let suffix = "\(entry.path)/\(entry.name) ParametricEQ.txt"
        let encoded = suffix.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? suffix
        return URL(string: base + encoded)!
    }
}

struct AutoEqCache {
    var directory: URL

    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["EQ_CACHE"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("autoeq")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/eq/autoeq")
    }

    private var indexFile: URL { directory.appendingPathComponent("INDEX.md") }

    func load(fetch: (URL) throws -> Data, refresh: Bool, now: Date = Date()) throws -> [AutoEqEntry] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: indexFile.path)
        let modified = attributes?[.modificationDate] as? Date
        let isFresh = modified.map { now.timeIntervalSince($0) < AutoEqIndex.cacheMaxAge } ?? false

        if isFresh, !refresh, let cached = try? String(contentsOf: indexFile) {
            return AutoEqIndex.parse(cached)
        }

        do {
            let data = try fetch(AutoEqIndex.indexURL)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: indexFile, options: .atomic)
            return AutoEqIndex.parse(String(decoding: data, as: UTF8.self))
        } catch {
            if let stale = try? String(contentsOf: indexFile) {
                return AutoEqIndex.parse(stale)
            }
            throw error
        }
    }
}
