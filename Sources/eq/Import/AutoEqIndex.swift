import Foundation

struct AutoEqEntry: Headphone {
    var name: String
    var path: String
    var source: String
}

enum AutoEqIndex {
    static let indexURL = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/INDEX.md")!
    static let base = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    static let cacheMaxAge: TimeInterval = 7 * 24 * 3600
    static let preferredSources = ["oratory1990", "crinacle", "Rtings"]

    typealias Match = HeadphoneMatch.Match<AutoEqEntry>

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

    static func match(_ query: String, in entries: [AutoEqEntry], source: String?, variant: String? = nil) -> Match {
        HeadphoneMatch.match(query, in: entries, source: source, variant: variant, rank: rank)
    }

    static func rank(_ entry: AutoEqEntry) -> Int {
        preferredSources.firstIndex { $0.lowercased() == entry.source.lowercased() } ?? preferredSources.count
    }

    static func fileURL(for entry: AutoEqEntry) -> URL {
        let suffix = "\(entry.path)/\(entry.name) ParametricEQ.txt"
        let encoded = suffix.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? suffix
        return URL(string: base + encoded)!
    }
}

struct AutoEqCache {
    var directory: URL

    static var defaultDirectory: URL { CachedDownload.root.appendingPathComponent("autoeq") }

    func load(fetch: (URL) throws -> Data, refresh: Bool, now: Date = Date()) throws -> [AutoEqEntry] {
        try CachedDownload(file: directory.appendingPathComponent("INDEX.md"), url: AutoEqIndex.indexURL, maxAge: AutoEqIndex.cacheMaxAge)
            .load(fetch: fetch, refresh: refresh, now: now) { AutoEqIndex.parse(String(decoding: $0, as: UTF8.self)) }
    }
}

/// One downloaded file kept for `maxAge`, re-fetched after that, and served stale when the
/// network is down — a week-old index beats no import at all.
struct CachedDownload {
    var file: URL
    var url: URL
    var maxAge: TimeInterval

    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["EQ_CACHE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/eq")
    }

    func load<T>(fetch: (URL) throws -> Data, refresh: Bool, now: Date = Date(), parse: (Data) -> [T]) throws -> [T] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let modified = attributes?[.modificationDate] as? Date
        let isFresh = modified.map { now.timeIntervalSince($0) < maxAge } ?? false

        if isFresh, !refresh, let cached = try? Data(contentsOf: file) {
            return parse(cached)
        }

        do {
            let data = try fetch(url)
            let entries = parse(data)
            // A captive portal or an error page answers 200 with HTML; caching it would hide every
            // model for a week, so a file with no entries counts as a failed fetch.
            guard !entries.isEmpty else { throw URLError(.cannotParseResponse) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return entries
        } catch {
            if let stale = try? Data(contentsOf: file) {
                return parse(stale)
            }
            throw error
        }
    }
}
