import Foundation

/// Finds a headphone by name across AutoEq and OPRA. AutoEq answers first; OPRA's 12 MB
/// database is only downloaded when AutoEq has nothing, when `--source opra` asks for it, or
/// for `--search`.
enum HeadphoneLookup {
    static func opraDirectory(_ ctx: CLIContext) -> URL {
        ctx.cacheDirectory.deletingLastPathComponent().appendingPathComponent("opra")
    }

    static func loadAutoEq(refresh: Bool, _ ctx: CLIContext) throws -> [AutoEqEntry] {
        do { return try AutoEqCache(directory: ctx.cacheDirectory).load(fetch: ctx.fetch, refresh: refresh) }
        catch {
            let cachePath = ctx.cacheDirectory.appendingPathComponent("INDEX.md").path
            throw CLIError.network("\(error) — the last index is kept in \(cachePath); pass --refresh to retry")
        }
    }

    static func loadOPRA(refresh: Bool, _ ctx: CLIContext) throws -> [OPRAEntry] {
        do { return try OPRACache(directory: opraDirectory(ctx)).load(fetch: ctx.fetch, refresh: refresh) }
        catch {
            let cachePath = opraDirectory(ctx).appendingPathComponent("database_v1.jsonl").path
            throw CLIError.network("OPRA: \(error) — the last database is kept in \(cachePath); pass --refresh to retry")
        }
    }

    static func isOPRA(_ source: String?) -> Bool { source?.lowercased() == "opra" }

    static func resolve(
        _ query: String, source: String?, variant: String?,
        autoEq: () throws -> [AutoEqEntry], opra: () throws -> [OPRAEntry]
    ) throws -> CatalogueEntry {
        var missed: CLIError?
        if !isOPRA(source) {
            switch AutoEqIndex.match(query, in: try autoEq(), source: source, variant: variant) {
            case .one(let entry): return .autoEq(entry)
            case .variants(let model, let keys): throw CLIError.importVariant(model, keys, asked: variant)
            case .ambiguous(let names): throw ambiguous(names)
            case .didYouMean(let names): missed = .importSuggest(query, names)
            case .none: missed = .importNotFound(source.map { "\(query) from \($0)" } ?? query)
            }
            // An AutoEq reviewer was named; OPRA has none of that name, so looking there only
            // turns "not from crinacle" into a confusing OPRA answer.
            if source != nil, let missed { throw missed }
        }

        let entries: [OPRAEntry]
        do { entries = try opra() }
        catch { throw missed ?? error }
        switch HeadphoneMatch.match(query, in: entries, source: nil, variant: variant, rank: OPRA.rank) {
        case .one(let entry): return .opra(entry)
        case .variants(let model, let keys): throw CLIError.importVariant(model, keys, asked: variant)
        case .ambiguous(let names): throw ambiguous(names)
        case .didYouMean(let names):
            if let missed, case .importSuggest = missed { throw missed }
            throw CLIError.importSuggest(query, names)
        case .none: throw missed ?? CLIError.importNotFound("\(query) in OPRA")
        }
    }

    static func search(_ query: String, source: String?, refresh: Bool, _ ctx: CLIContext) throws -> Output {
        var warnings: [String] = []
        var failures: [Error] = []
        var autoEq: [AutoEqEntry] = []
        var opra: [OPRAEntry] = []
        if !isOPRA(source) {
            do { autoEq = try loadAutoEq(refresh: refresh, ctx) } catch { failures.append(error); warnings.append("\(error)") }
            if let source { autoEq = autoEq.filter { $0.source.lowercased() == source.lowercased() } }
        }
        if source == nil || isOPRA(source) {
            do { opra = try loadOPRA(refresh: refresh, ctx) } catch { failures.append(error); warnings.append("\(error)") }
        }
        if autoEq.isEmpty, opra.isEmpty, let failure = failures.first { throw failure }

        let catalogue = autoEq.map(CatalogueEntry.autoEq) + opra.map(CatalogueEntry.opra)
        let found = HeadphoneMatch.search(query, in: catalogue, rank: CatalogueEntry.rank)
        var pick: CatalogueEntry?
        var hint: [String] = []
        do {
            pick = try resolve(query, source: source, variant: nil, autoEq: { autoEq }, opra: { opra })
        } catch CLIError.importVariant(_, let keys, _) {
            hint = keys
        } catch {}
        let rows = found.hits.map {
            ImportSearch.Row(name: $0.name, source: $0.source, database: $0.database, pick: $0 == pick, credit: $0.credit)
        }
        return ImportSearch.output(query: query, rows: rows, suggestions: found.suggestions, variants: hint, warnings: warnings)
    }

    private static func ambiguous(_ names: [String]) -> CLIError {
        let shown = 20
        return .importAmbiguous(names.count > shown ? Array(names.prefix(shown)) + ["… and \(names.count - shown) more"] : names)
    }
}
