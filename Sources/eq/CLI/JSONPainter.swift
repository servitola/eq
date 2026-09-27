import Foundation

/// Colours already-encoded JSON the way `jq` does. It only inserts escapes around tokens and never
/// re-encodes, so stripping the escapes gives back the exact bytes a pipe would get. It walks
/// scalars, not Characters: a combining mark right after a quote would fuse with it into one
/// Character and hide the quote.
enum JSONPainter {
    static func paint(_ json: String) -> String {
        let scalars = Array(json.unicodeScalars)
        var out = ""
        var i = 0
        func emit(_ ink: Paint.Ink, _ from: Int, _ to: Int) {
            out += Paint.ink(ink, text(scalars[from..<to]), on: true)
        }
        while i < scalars.count {
            let c = scalars[i]
            switch c {
            case "\"":
                var end = i + 1
                while end < scalars.count && scalars[end] != "\"" {
                    end += scalars[end] == "\\" ? 2 : 1
                }
                end = min(end + 1, scalars.count)
                var next = end
                while next < scalars.count && scalars[next].properties.isWhitespace { next += 1 }
                let isKey = next < scalars.count && scalars[next] == ":"
                emit(isKey ? .blue : .green, i, end)
                i = end
            case "{", "}", "[", "]", ",", ":":
                emit(.dim, i, i + 1)
                i += 1
            case "-", "0"..."9":
                var end = i + 1
                while end < scalars.count && "0123456789.eE+-".unicodeScalars.contains(scalars[end]) { end += 1 }
                emit(.yellow, i, end)
                i = end
            case "t", "f", "n":
                var end = i
                while end < scalars.count && ("a"..."z").contains(scalars[end]) { end += 1 }
                let word = text(scalars[i..<end])
                if word == "null" { emit(.dim, i, end) } else if word == "true" || word == "false" { emit(.cyan, i, end) } else { out += word }
                i = max(end, i + 1)
            default:
                out.unicodeScalars.append(c)
                i += 1
            }
        }
        return out
    }

    private static func text(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var string = ""
        string.unicodeScalars.append(contentsOf: scalars)
        return string
    }
}
