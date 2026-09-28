import Foundation

/// The YAML a CamillaDSP config is written in: block mappings and sequences, one-line flow
/// `{…}`/`[…]`, plain and quoted scalars, comments. Anchors, tags and multi-line strings are
/// refused rather than guessed at; eq has no dependencies, so no YAML library.
indirect enum YAML: Equatable {
    case scalar(String)
    case map([(key: String, value: YAML)])
    case list([YAML])

    static func == (a: YAML, b: YAML) -> Bool {
        switch (a, b) {
        case (.scalar(let x), .scalar(let y)): return x == y
        case (.list(let x), .list(let y)): return x == y
        case (.map(let x), .map(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    subscript(key: String) -> YAML? {
        guard case .map(let entries) = self else { return nil }
        return entries.first { $0.key == key }?.value
    }

    var string: String? {
        guard case .scalar(let s) = self else { return nil }
        return s
    }

    /// Finite only; YAML's `.inf` and `.nan` are not numbers here, and neither is Swift's `inf`.
    var number: Double? {
        guard let s = string, s.allSatisfy({ "0123456789+-.eE".contains($0) }), let d = Double(s), d.isFinite else { return nil }
        return d
    }

    var list: [YAML]? {
        guard case .list(let items) = self else { return nil }
        return items
    }

    var entries: [(key: String, value: YAML)]? {
        guard case .map(let entries) = self else { return nil }
        return entries
    }

    struct SyntaxError: Error, CustomStringConvertible {
        var line: Int
        var message: String
        var description: String { "line \(line): \(message)" }
    }

    static func parse(_ text: String) throws -> YAML {
        var parser = Parser(text)
        if let tab = parser.tabLine { throw SyntaxError(line: tab, message: "tab in indentation") }
        guard let first = parser.lines.first else { return .map([]) }
        let value = try parser.block(indent: first.indent, depth: 0)
        if parser.index < parser.lines.count {
            throw SyntaxError(line: parser.lines[parser.index].number, message: "unexpected indentation")
        }
        return value
    }

    private struct Line {
        var number: Int
        var indent: Int
        var text: Substring
    }

    // Nesting deeper than any config needs is refused, so hostile input cannot exhaust the stack.
    private static let maxDepth = 64

    private struct Parser {
        var lines: [Line] = []
        var index = 0
        var tabLine: Int?

        init(_ text: String) {
            for (i, raw) in APOFormat.lines(text).enumerated() {
                let body = Parser.stripComment(raw)
                let trimmed = body.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == "---" || trimmed.hasPrefix("%") { continue }
                if trimmed == "..." { break }
                if body.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") { tabLine = tabLine ?? i + 1 }
                let indent = body.prefix { $0 == " " }.count
                lines.append(Line(number: i + 1, indent: indent, text: body.dropFirst(indent).trimmingSuffix()))
            }
        }

        /// A `#` starts a comment at the start of a line or after a space, outside quotes.
        static func stripComment(_ line: Substring) -> Substring {
            var quote: Character?
            var previous: Character = " "
            for i in line.indices {
                let c = line[i]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    if previous == " " || previous == "[" || previous == "{" || previous == "," || previous == ":" { quote = c }
                } else if c == "#", previous == " " || previous == "\t" {
                    return line[..<i]
                }
                previous = c
            }
            return line
        }

        mutating func block(indent: Int, depth: Int) throws -> YAML {
            guard depth < YAML.maxDepth else { throw SyntaxError(line: lines[index].number, message: "nested too deeply") }
            let line = lines[index]
            return line.text == "-" || line.text.hasPrefix("- ") ? try list(indent: indent, depth: depth) : try map(indent: indent, depth: depth)
        }

        mutating func list(indent: Int, depth: Int) throws -> YAML {
            var items: [YAML] = []
            while index < lines.count, lines[index].indent == indent, lines[index].text == "-" || lines[index].text.hasPrefix("- ") {
                let line = lines[index]
                let content = line.text.dropFirst().drop { $0 == " " }
                if content.isEmpty {
                    index += 1
                    items.append(try child(of: indent, depth: depth))
                } else if Parser.keyValue(content) != nil {
                    // `- key: value` opens a mapping whose keys line up with `key`.
                    let column = indent + (line.text.count - content.count)
                    lines[index] = Line(number: line.number, indent: column, text: content)
                    items.append(try map(indent: column, depth: depth + 1))
                } else {
                    index += 1
                    items.append(try YAML.inline(content, line: line.number, depth: depth))
                }
            }
            return .list(items)
        }

        mutating func map(indent: Int, depth: Int) throws -> YAML {
            var entries: [(key: String, value: YAML)] = []
            while index < lines.count, lines[index].indent == indent {
                let line = lines[index]
                if line.text == "-" || line.text.hasPrefix("- ") { break }
                guard let (key, rest) = Parser.keyValue(line.text) else {
                    throw SyntaxError(line: line.number, message: "expected \u{201C}key: value\u{201D}")
                }
                index += 1
                if rest.isEmpty {
                    // A sequence may sit at its key's own indentation: `pipeline:` then `- type: …`.
                    if index < lines.count, lines[index].indent == indent, lines[index].text == "-" || lines[index].text.hasPrefix("- ") {
                        entries.append((key, try list(indent: indent, depth: depth + 1)))
                    } else {
                        entries.append((key, try child(of: indent, depth: depth)))
                    }
                } else {
                    if rest.first == "|" || rest.first == ">" { throw SyntaxError(line: line.number, message: "multi-line strings are not supported") }
                    entries.append((key, try YAML.inline(rest, line: line.number, depth: depth)))
                }
            }
            return .map(entries)
        }

        mutating func child(of indent: Int, depth: Int) throws -> YAML {
            guard index < lines.count, lines[index].indent > indent else { return .scalar("") }
            return try block(indent: lines[index].indent, depth: depth + 1)
        }

        /// `key: rest`, the key plain or quoted; a colon only separates when a space or the end follows it.
        static func keyValue(_ text: Substring) -> (String, Substring)? {
            if let q = text.first, q == "\"" || q == "'" {
                guard let close = text.dropFirst().firstIndex(of: q) else { return nil }
                let after = text[text.index(after: close)...]
                guard after.hasPrefix(":"), after.count == 1 || after.dropFirst().first == " " else { return nil }
                return (String(text[text.index(after: text.startIndex)..<close]), after.dropFirst().drop { $0 == " " })
            }
            guard text.first != "{", text.first != "[" else { return nil }
            var i = text.startIndex
            while i < text.endIndex {
                if text[i] == ":" {
                    let next = text.index(after: i)
                    if next == text.endIndex || text[next] == " " {
                        let key = text[..<i].trimmingCharacters(in: .whitespaces)
                        return key.isEmpty ? nil : (key, text[next...].drop { $0 == " " })
                    }
                }
                i = text.index(after: i)
            }
            return nil
        }
    }

    /// A scalar or a flow collection that ends on its own line.
    static func inline(_ text: Substring, line: Int, depth: Int) throws -> YAML {
        if let c = text.first, c == "&" || c == "*" || c == "!" {
            throw SyntaxError(line: line, message: "anchors, aliases and tags are not supported")
        }
        guard text.first == "{" || text.first == "[" else { return .scalar(unquote(text)) }
        var flow = Flow(chars: Array(text), line: line)
        let value = try flow.value(depth: depth)
        flow.skipSpaces()
        guard flow.position == flow.chars.count else { throw SyntaxError(line: line, message: "text after a closing bracket") }
        return value
    }

    static func unquote(_ text: Substring) -> String {
        let s = text.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, let q = s.first, q == "\"" || q == "'", s.last == q { return String(s.dropFirst().dropLast()) }
        return s
    }

    private struct Flow {
        var chars: [Character]
        var line: Int
        var position = 0

        mutating func skipSpaces() { while position < chars.count, chars[position] == " " { position += 1 } }

        mutating func value(depth: Int) throws -> YAML {
            guard depth < YAML.maxDepth else { throw SyntaxError(line: line, message: "nested too deeply") }
            skipSpaces()
            guard position < chars.count else { throw SyntaxError(line: line, message: "unclosed bracket") }
            switch chars[position] {
            case "[":
                position += 1
                var items: [YAML] = []
                while true {
                    skipSpaces()
                    guard position < chars.count else { throw SyntaxError(line: line, message: "unclosed [") }
                    if chars[position] == "]" { position += 1; return .list(items) }
                    items.append(try value(depth: depth + 1))
                    try separator("]")
                }
            case "{":
                position += 1
                var entries: [(key: String, value: YAML)] = []
                while true {
                    skipSpaces()
                    guard position < chars.count else { throw SyntaxError(line: line, message: "unclosed {") }
                    if chars[position] == "}" { position += 1; return .map(entries) }
                    guard case .scalar(let key) = try scalar(stopAtColon: true) else { throw SyntaxError(line: line, message: "bad key") }
                    skipSpaces()
                    guard position < chars.count, chars[position] == ":" else { throw SyntaxError(line: line, message: "expected : after \(key)") }
                    position += 1
                    entries.append((key, try value(depth: depth + 1)))
                    try separator("}")
                }
            default:
                return try scalar(stopAtColon: false)
            }
        }

        mutating func separator(_ close: Character) throws {
            skipSpaces()
            guard position < chars.count else { throw SyntaxError(line: line, message: "unclosed \(close == "]" ? "[" : "{")") }
            if chars[position] == "," { position += 1 } else if chars[position] != close {
                throw SyntaxError(line: line, message: "expected , or \(close)")
            }
        }

        mutating func scalar(stopAtColon: Bool) throws -> YAML {
            if let q = chars[safe: position], q == "\"" || q == "'" {
                guard let close = chars[(position + 1)...].firstIndex(of: q) else { throw SyntaxError(line: line, message: "unclosed quote") }
                defer { position = close + 1 }
                return .scalar(String(chars[(position + 1)..<close]))
            }
            let start = position
            while position < chars.count, !",]}".contains(chars[position]),
                  !(stopAtColon && chars[position] == ":" && (position + 1 == chars.count || chars[position + 1] == " ")) {
                position += 1
            }
            return .scalar(String(chars[start..<position]).trimmingCharacters(in: .whitespaces))
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

private extension Substring {
    func trimmingSuffix() -> Substring {
        var s = self
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return s
    }
}
