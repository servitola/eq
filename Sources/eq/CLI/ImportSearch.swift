import Foundation

enum ImportSearch {
    struct Row {
        var name: String
        var source: String
        var database: String
        var pick: Bool
        var credit: String? = nil
    }

    struct Report: Encodable {
        struct Result: Encodable {
            var name: String; var model: String; var variant: String?; var variantKey: String?
            var source: String; var database: String; var credit: String?; var pick: Bool
            enum CodingKeys: String, CodingKey { case name, model, variant, variantKey, source, database, credit, pick }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                try container.encode(model, forKey: .model)
                try container.encode(variant, forKey: .variant)
                try container.encode(variantKey, forKey: .variantKey)
                try container.encode(source, forKey: .source)
                try container.encode(database, forKey: .database)
                try container.encode(credit, forKey: .credit)
                try container.encode(pick, forKey: .pick)
            }
        }
        var query: String
        var results: [Result]
        var suggestions: [String]
        var variants: [String]
        var warnings: [String]
    }

    static let shownRows = 40

    static func output(query: String, rows: [Row], suggestions: [String], variants: [String], warnings: [String] = []) -> Output {
        let results = rows.map { row -> Report.Result in
            let name = HeadphoneName(row.name)
            return Report.Result(name: row.name, model: name.model, variant: name.variant, variantKey: name.variantKey,
                                 source: row.source, database: row.database, credit: row.credit, pick: row.pick)
        }
        var lines = warnings.map { "\(Paint.ink(.yellow, "warning:")) \($0)" }
        if results.isEmpty {
            let lead = "no headphone matches \"\(query)\""
            lines.append(suggestions.isEmpty ? lead : "\(lead) — did you mean: " + suggestions.map { Paint.ink(.bold, $0) }.joined(separator: ", "))
        } else {
            lines.append(Paint.ink(.dim, "\(results.count) \(results.count == 1 ? "match" : "matches") for \"\(query)\""))
            lines += table(Array(results.prefix(shownRows)))
            if results.count > shownRows {
                lines.append(Paint.ink(.dim, "… and \(results.count - shownRows) more — narrow the name, or add --json for all"))
            }
            if results.contains(where: \.pick) {
                lines.append(Paint.ink(.dim, "* is what eq import \"\(query)\" applies"))
            } else if !variants.isEmpty {
                lines.append(Paint.ink(.dim, "several variants — add --variant ") + variants.map { Paint.ink(.yellow, $0) }.joined(separator: Paint.ink(.dim, " | ")))
            }
        }
        var output = Output(lines.joined(separator: "\n"),
                            Report(query: query, results: results, suggestions: suggestions, variants: variants, warnings: warnings))
        output.exitCode = results.isEmpty ? 1 : 0
        return output
    }

    private static func table(_ results: [Report.Result]) -> [String] {
        let variantText = results.map { $0.variantKey ?? "—" }
        let sourceText = results.map { result in result.credit.map { "\(result.source) · \($0)" } ?? result.source }
        let modelWidth = results.map(\.model.count).max() ?? 0
        let variantWidth = variantText.map(\.count).max() ?? 0
        let sourceWidth = sourceText.map(\.count).max() ?? 0
        return results.indices.map { i in
            let result = results[i]
            let marker = result.pick ? Paint.ink(.green, "*") + " " : "  "
            let model = Paint.ink(.bold, pad(result.model, modelWidth))
            let variant = Paint.ink(result.variantKey == nil ? .dim : .yellow, pad(variantText[i], variantWidth))
            let source = Paint.ink(.cyan, pad(sourceText[i], sourceWidth))
            return "\(marker)\(model)  \(variant)  \(source)  \(Paint.ink(.dim, result.database))"
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(width - text.count, 0))
    }
}
