// Vendored from zollans/OnlyEQ @ 6569655 (Unlicense), trimmed for eq.
import Foundation

/// Equalizer APO's `config.txt` grammar, which AutoEq, REW, squig.link, peqdb and SoundSource
/// all write or write a subset of. Filter semantics follow APO's own source
/// (`filters/BiQuadFilterFactory.cpp`, `BiQuadFilter.cpp`, `BiQuad.cpp`), not only its wiki.
enum APOFormat: EQFormat {
    static let name = "Equalizer APO / AutoEq / REW / squig.link text"
    static let maxIncludeDepth = 4
    // Depth alone still lets a file include another one hundreds of times over.
    static let maxIncludedFiles = 64
    // A config is a few kilobytes; the cap keeps a device file or a FIFO from being read forever.
    static let maxIncludeBytes = 1 << 20

    static func sniff(_ data: Data, filename: String?) -> Bool {
        guard let text = ImportText.decode(data) else { return false }
        // A YAML key (CamillaDSP names a Gain filter `preamp:`) has nothing or a flow collection
        // after its colon; an APO command always has parameters. `Channel:` alone imports nothing.
        return lines(text).contains {
            guard let line = Line(String($0)), ["filter", "preamp", "graphiceq", "include"].contains(line.command) else { return false }
            let parameters = line.parameters.trimmingCharacters(in: .whitespaces)
            return !parameters.isEmpty && !parameters.hasPrefix("{") && !parameters.hasPrefix("[")
        }
    }

    static func parse(_ data: Data) throws -> ImportResult { try parse(data, context: .detached) }

    static func parse(_ data: Data, context: ImportContext) throws -> ImportResult {
        guard let text = ImportText.decode(data) else { throw ImportError.unrecognized }
        var parser = Parser()
        let root = context.file.map { $0.absoluteURL.standardizedFileURL.resolvingSymlinksInPath() }
        parser.folder = root?.deletingLastPathComponent().path
        parser.read(text, file: root, label: nil, depth: 0)
        return try parser.finish(isREW: text.contains("Room EQ") || text.contains("Filter Settings file"))
    }

    /// For a format that wraps APO lines (Peace): `places[i]` names line i in warnings instead of its number.
    static func parse(text: String, places: [String]) throws -> ImportResult {
        var parser = Parser()
        parser.places = places
        parser.read(text, file: nil, label: nil, depth: 0)
        return try parser.finish(isREW: false)
    }

    // MARK: - Lines

    /// Swift reads CRLF as one character, so squig.link's and Windows' line numbers stay right.
    static func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    struct Line {
        /// Lowercased; `Filter 3` and `Filter` both become `filter`.
        var command: String
        var parameters: String

        init?(_ raw: String) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return nil }
            var command = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if command.hasPrefix("filter"), command.dropFirst("filter".count).allSatisfy({ $0.isNumber || $0 == " " || $0 == "\t" }) {
                command = "filter"
            }
            guard !command.isEmpty else { return nil }
            self.command = command
            parameters = String(line[line.index(after: colon)...])
        }
    }

    /// APO's own number syntax (`[-+0-9.eE]+` read by `wcstod`), after its comma-to-period swap.
    static func number(_ s: String) -> Double? {
        let s = s.replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty, s.allSatisfy({ "0123456789+-.eE".contains($0) }), let value = Double(s), value.isFinite else { return nil }
        return value
    }

    // MARK: - Filters

    private struct Refusal: Error, CustomStringConvertible { var description: String }

    enum FilterLine {
        case filter(Filter)
        /// OFF, and REW's `ON None` for an unused slot: nothing to say about either.
        case silent
        case skipped(String)
    }

    private static let numberPattern = #"([-+0-9.,eE]+)"#
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    private static let typeRegex = regex(#"^\s*(ON|OFF)?\s*([A-Za-z]+)"#)
    private static let slopeRegex = regex(#"^\s*"# + numberPattern + #"\s*dB"#)
    private static let freqRegex = regex(#"(?:^|\s)Fc\s*"# + numberPattern + #"\s*(k?)\s*(?:H\s*z)?"#)
    private static let gainRegex = regex(#"(?:^|\s)Gain\s*"# + numberPattern + #"\s*(?:dB)?"#)
    private static let qRegex = regex(#"(?:^|\s)Q\s*"# + numberPattern)
    private static let bwRegex = regex(#"(?:^|\s)BW\s+Oct\s*"# + numberPattern)
    private static let preampRegex = regex(#"^\s*"# + numberPattern + #"\s*dB"#)

    private static func capture(_ regex: NSRegularExpression, _ text: String, _ group: Int = 1) -> String? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.range(at: group).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    static func filter(_ parameters: String) -> FilterLine {
        let ns = parameters as NSString
        guard let m = typeRegex.firstMatch(in: parameters, range: NSRange(location: 0, length: ns.length)) else {
            return .skipped("no filter type")
        }
        if m.range(at: 1).location != NSNotFound, ns.substring(with: m.range(at: 1)).uppercased() == "OFF" { return .silent }
        let token = ns.substring(with: m.range(at: 2)).uppercased()
        let rest = ns.substring(from: m.range.location + m.range.length)

        let type: FilterType
        switch token {
        case "PK", "PEQ", "MODAL": type = .peak
        case "LS", "LSC", "LSQ": type = .lowShelf
        case "HS", "HSC", "HSQ": type = .highShelf
        case "LP", "LPQ": type = .lowPass
        case "HP", "HPQ": type = .highPass
        case "BP": type = .bandPass
        case "NO", "NOTCH": type = .notch
        case "NONE": return .silent
        case "AP": return .skipped("an all-pass filter is not supported")
        case "IIR": return .skipped("an IIR filter's raw coefficients are not supported")
        default: return .skipped("unknown filter type \u{201C}\(token)\u{201D}")
        }

        func value(_ regex: NSRegularExpression, _ what: String) throws -> Double? {
            guard let raw = capture(regex, rest) else { return nil }
            guard let v = number(raw) else { throw Refusal(description: "\(what) \u{201C}\(raw)\u{201D} is not a number") }
            return v
        }
        let fcValue: Double?, gainValue: Double?, qValue: Double?, bwValue: Double?, slopeValue: Double?
        do {
            fcValue = try value(freqRegex, "frequency")
            gainValue = try value(gainRegex, "gain")
            qValue = try value(qRegex, "Q")
            bwValue = try value(bwRegex, "bandwidth")
            slopeValue = try value(slopeRegex, "slope")
        } catch {
            return .skipped("\(error)")
        }
        guard var fc = fcValue else { return .skipped("no frequency (Fc)") }
        if capture(freqRegex, rest, 2)?.isEmpty == false {
            fc *= 1000
        } else if let raw = capture(freqRegex, rest), isThousands(raw) {
            fc *= 1000
        }

        let isShelf = type == .lowShelf || type == .highShelf
        let takesGain = type == .peak || isShelf
        let gain = takesGain ? gainValue : 0
        guard let gain else { return .skipped("no gain") }
        guard Config.filterFrequencyRange.contains(fc) else { return .skipped(outside("frequency", fc, "Hz", Config.filterFrequencyRange)) }
        guard Config.filterGainRange.contains(gain) else { return .skipped(outside("gain", gain, "dB", Config.filterGainRange)) }

        // APO reads 0 as "not given" for Q, bandwidth and slope alike.
        let q = qValue.flatMap { $0 == 0 ? nil : $0 }
        let bw = bwValue.flatMap { $0 == 0 ? nil : $0 }
        let resolvedQ: Double
        var frequency = fc
        if isShelf {
            let a = pow(10, gain / 40)
            let slope = slopeValue.flatMap { $0 == 0 ? nil : $0 }
            // APO's default for a shelf with neither, "found out by experimentation with RoomEQWizard".
            let s: Double? = slope.map { $0 / 12 } ?? (q == nil ? 0.9 : nil)
            if let s {
                let radicand = (a + 1 / a) * (1 / s - 1) + 2
                guard s > 0 else { return .skipped(String(format: "a %g dB/oct slope is not positive", s * 12)) }
                guard radicand > 0 else {
                    return .skipped(String(format: "a %g dB/oct slope is too steep for %g dB of gain", s * 12, gain))
                }
                resolvedQ = 1 / radicand.squareRoot()
            } else {
                resolvedQ = q ?? 0
            }
            // LS/HS with a slope or a Q name the corner; LSC/HSC, and LS/HS with neither, the centre.
            let centred = token.hasSuffix("C") || token.hasSuffix("Q") || (slope == nil && q == nil)
            if !centred {
                // APO's DCX2496 correction: the named frequency is the corner, the biquad wants the centre.
                let cornerS = s ?? 1 / ((1 / (resolvedQ * resolvedQ) - 2) / (a + 1 / a) + 1)
                guard cornerS > 0, cornerS.isFinite else {
                    return .skipped(String(format: "Q %g cannot shape a corner-frequency shelf", resolvedQ))
                }
                let factor = pow(10, abs(gain) / 80 / cornerS)
                frequency = type == .lowShelf ? fc * factor : fc / factor
                guard Config.filterFrequencyRange.contains(frequency) else {
                    return .skipped(outside("centre frequency", frequency, "Hz", Config.filterFrequencyRange))
                }
            }
        } else if let q {
            resolvedQ = q
        } else if let bw {
            guard bw > 0 else { return .skipped(String(format: "bandwidth %g octaves is not positive", bw)) }
            resolvedQ = qFromBandwidth(bw, frequency: fc)
        } else {
            switch type {
            case .peak: return .skipped("no Q or bandwidth")
            case .notch: resolvedQ = 30
            default: resolvedQ = 0.5.squareRoot()
            }
        }
        guard resolvedQ.isFinite, Config.filterQRange.contains(resolvedQ) else {
            return .skipped(outside("Q", resolvedQ, "", Config.filterQRange))
        }
        let result = Filter(type: type, frequency: frequency, gain: gain, q: resolvedQ)
        guard Config.firstUnstableFilter([result], sampleRate: Config.stabilityCheckRate) == nil else {
            return .skipped("it would be unstable at \(Int(Config.stabilityCheckRate / 1000)) kHz")
        }
        return .filter(result)
    }

    /// REW writes `1.911` for 1911 Hz in some locales; APO multiplies any Fc with exactly three
    /// digits after its only separator (and five characters or more) by 1000, and so do we.
    private static func isThousands(_ raw: String) -> Bool {
        let s = raw.replacingOccurrences(of: ",", with: ".")
        guard s.count >= 5, !s.contains(where: { $0 == "e" || $0 == "E" }), let dot = s.lastIndex(of: ".") else { return false }
        return s.distance(from: dot, to: s.endIndex) == 4
    }

    /// RBJ's digital bandwidth relation, `alpha = sin w0 · sinh(ln2/2 · BW · w0/sin w0)`, as APO
    /// computes it. The w0/sin w0 warp depends on the sample rate, so it is taken at the rate
    /// most outputs run at; without it, a 10 kHz BW filter would come out a third too narrow.
    static func qFromBandwidth(_ bw: Double, frequency: Double, sampleRate: Double = Config.stabilityCheckRate) -> Double {
        let w0 = 2 * Double.pi * frequency / sampleRate
        return 1 / (2 * sinh(log(2) / 2 * bw * w0 / sin(w0)))
    }

    private static func outside(_ what: String, _ value: Double, _ unit: String, _ range: ClosedRange<Double>) -> String {
        let suffix = unit.isEmpty ? "" : " \(unit)"
        return String(format: "%@ %g%@ is outside %g–%g%@", what, value, suffix, range.lowerBound, range.upperBound, suffix)
    }

    // MARK: - GraphicEQ

    /// Log-frequency interpolation onto `frequencies` (our ten centres unless given), flat beyond
    /// the first and last points.
    static func graphic(_ parameters: String, at frequencies: [Double] = Config.bandFrequencies) -> (bands: [Double], points: Int, dropped: Int)? {
        var points: [(f: Double, g: Double)] = []
        var dropped = 0
        for pair in parameters.components(separatedBy: ";") where !pair.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = pair.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count == 2, let f = number(parts[0]), let g = number(parts[1]), f > 0 {
                points.append((f, g))
            } else {
                dropped += 1
            }
        }
        guard points.count >= 2 else { return nil }
        points.sort { $0.f < $1.f }

        func interpolate(_ f: Double) -> Double {
            if f <= points[0].f { return points[0].g }
            if f >= points[points.count - 1].f { return points[points.count - 1].g }
            for i in 1..<points.count where points[i].f >= f {
                let (f0, g0) = points[i - 1], (f1, g1) = points[i]
                guard f1 > f0 else { return g1 }
                let t = (log(f) - log(f0)) / (log(f1) - log(f0))
                return g0 + t * (g1 - g0)
            }
            return 0
        }
        return (frequencies.map(interpolate), points.count, dropped)
    }

    /// Where a GraphicEQ curve is compared with the ten bands: 128 points, 20 Hz–20 kHz, even in octaves.
    static let fitFrequencies: [Double] = (0..<128).map { 20 * pow(1000, Double($0) / 127) }

    /// A GraphicEQ line is the response itself, preamp included, and flat beyond its last point.
    /// Setting each band to the curve's value at its centre misses both: neighbouring peaks add up
    /// between centres, and a level the whole curve sits at falls back to 0 dB past the outer
    /// bands. So the preamp and the ten gains are fitted together to the whole curve (least
    /// squares on `fitFrequencies`, Gauss–Newton because a peak's dB is not quite linear in its
    /// gain), each kept inside its range.
    static func fitBands(_ target: [Double], levelRange: ClosedRange<Double>) -> (level: Double, bands: [Double], limited: Bool) {
        let rate = Config.stabilityCheckRate
        let points = fitFrequencies.count, bands = Config.bandFrequencies.count
        func peak(_ index: Int, _ gain: Double) -> [Double] {
            let biquad = BiquadCoefficients.make(type: .peak, frequency: Config.bandFrequencies[index], gainDB: gain, q: fixedBandQ, sampleRate: rate)
            return fitFrequencies.map { biquad.magnitudeDB(at: $0, sampleRate: rate) }
        }
        func clamp(_ level: Double, _ gains: [Double]) -> (level: Double, gains: [Double]) {
            (min(max(level, levelRange.lowerBound), levelRange.upperBound),
             gains.map { min(max($0, Config.gainRange.lowerBound), Config.gainRange.upperBound) })
        }
        func residual(_ level: Double, _ shapes: [[Double]]) -> [Double] {
            var r = target
            for i in 0..<points {
                r[i] -= level
                for shape in shapes { r[i] -= shape[i] }
            }
            return r
        }
        func cost(_ r: [Double]) -> Double { r.reduce(0) { $0 + $1 * $1 } }

        var level = 0.0
        var gains = Array(repeating: 0.0, count: bands)
        var shapes = gains.indices.map { peak($0, gains[$0]) }
        var r = residual(level, shapes)
        for _ in 0..<20 {
            // Column 0 is the level; column j the slope of band j at its current gain.
            var columns = [Array(repeating: 1.0, count: points)]
            for j in 0..<bands {
                let nudged = peak(j, gains[j] + 0.05)
                columns.append((0..<points).map { (nudged[$0] - shapes[j][$0]) / 0.05 })
            }
            var normal = Array(repeating: Array(repeating: 0.0, count: bands + 1), count: bands + 1)
            var right = Array(repeating: 0.0, count: bands + 1)
            for a in 0...bands {
                for i in 0..<points { right[a] += columns[a][i] * r[i] }
                for b in a...bands {
                    var sum = 0.0
                    for i in 0..<points { sum += columns[a][i] * columns[b][i] }
                    normal[a][b] = sum
                    normal[b][a] = sum
                }
                // A little damping: the level and the ten bands together can nearly draw the same offset twice.
                normal[a][a] *= 1.001
            }
            // A value held at its limit that the step would push further out stays there; the rest
            // are solved for without it, or a level stuck at the preamp's limit would never let
            // the bands take up what it cannot.
            let values = [level] + gains
            let limits = [levelRange] + Array(repeating: Config.gainRange, count: bands)
            var free = Array(0...bands)
            var step: [Double] = []
            while !free.isEmpty {
                guard let solved = solve(free.map { a in free.map { normal[a][$0] } }, free.map { right[$0] }) else { break }
                step = Array(repeating: 0, count: bands + 1)
                for (k, index) in free.enumerated() { step[index] = solved[k] }
                let pinned = free.filter { index in
                    (values[index] >= limits[index].upperBound && step[index] > 0) || (values[index] <= limits[index].lowerBound && step[index] < 0)
                }
                if pinned.isEmpty { break }
                free.removeAll { pinned.contains($0) }
                step = []
            }
            guard !step.isEmpty else { break }
            var scale = 1.0, improved = false
            let before = cost(r)
            while scale > 1.0 / 64 {
                let next = clamp(level + scale * step[0], zip(gains, step.dropFirst()).map { $0 + scale * $1 })
                let nextShapes = next.gains.indices.map { peak($0, next.gains[$0]) }
                let nextResidual = residual(next.level, nextShapes)
                if cost(nextResidual) < before {
                    (level, gains, shapes, r, improved) = (next.level, next.gains, nextShapes, nextResidual, true)
                    break
                }
                scale /= 2
            }
            // Done when a step no longer moves anything by a hundredth of the 0.1 dB the result is rounded to.
            if !improved || step.allSatisfy({ abs($0) * scale < 1e-3 }) || before - cost(r) < 1e-6 * Double(points) { break }
        }
        // A level at the preamp's limit is not a loss while the bands still take up the rest.
        return (level, gains, gains.contains { abs($0) == Config.gainRange.upperBound })
    }

    /// Gaussian elimination with partial pivoting; nil for a singular system.
    private static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        var a = zip(matrix, vector).map { $0 + [$1] }
        let n = vector.count
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }), abs(a[pivot][column]) > 1e-12 else { return nil }
            a.swapAt(column, pivot)
            for row in 0..<n where row != column {
                let factor = a[row][column] / a[column][column]
                if factor != 0 { for k in column...n { a[row][k] -= factor * a[column][k] } }
            }
        }
        let x = (0..<n).map { a[$0][n] / a[$0][$0] }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    // MARK: - FixedBandEQ

    // AutoEq's fixed bands are 31.25·2^i Hz written as integers, so 31 and 62 Hz sit 3 % below
    // our 32 and 64. A sixteenth of an octave (4.4 %) takes them; a Q 1.41 peak is an octave
    // wide, so moving it that far shifts its shape by a sixteenth of its width.
    static let fixedBandTolerance = pow(2, 1.0 / 16)
    static let fixedBandQ = 1.41

    /// Ten peaks at our centres with our Q are our ten bands, so they import as bands.
    static func fixedBands(_ filters: [Filter]) -> [Double]? {
        guard filters.count == Config.bandFrequencies.count else { return nil }
        let sorted = filters.sorted { $0.frequency < $1.frequency }
        for (filter, centre) in zip(sorted, Config.bandFrequencies) {
            let ratio = filter.frequency / centre
            guard filter.type == .peak, abs(filter.q - fixedBandQ) <= 0.01,
                  ratio <= fixedBandTolerance, ratio >= 1 / fixedBandTolerance,
                  Config.gainRange.contains(filter.gain) else { return nil }
        }
        return sorted.map(\.gain)
    }

    // MARK: - Parser

    private struct Chain: Equatable {
        var filters: [Filter] = []
        var graphics: [[Double]] = []
        var preamp = 0.0
        var preampLines = 0
    }

    private struct Parser {
        var left = Chain(), right = Chain()
        var scope = (left: true, right: true)
        var elsewhere = 0
        var warnings: [String] = []
        var ignoredCommands: Set<String> = []
        /// Paths, not URLs: a URL made relative to its includer never equals the same file reached otherwise.
        var stack: [String] = []
        var includedFiles = 0
        var places: [String] = []
        /// The imported file's folder. A relative `Include:` in a downloaded config stays inside it;
        /// an absolute path is the file's author naming the file outright, as APO allows.
        var folder: String?

        static let ignored: [String: String] = [
            "device": "Device: ignored, every filter is imported whatever device it names",
            "copy": "Copy: ignored, eq does not mix channels",
            "stage": "Stage: ignored, every filter is imported into one stage",
            "eval": "Eval: ignored, expressions are not evaluated",
            "if": "If:/Else: ignored, filters from every branch are imported",
            "elseif": "If:/Else: ignored, filters from every branch are imported",
            "else": "If:/Else: ignored, filters from every branch are imported",
            "endif": "If:/Else: ignored, filters from every branch are imported",
            "delay": "Delay: ignored, eq has no delay",
            "convolution": "Convolution: ignored, eq has no convolution",
            "vstplugin": "VSTPlugin: ignored, eq hosts no plugins",
            "loudnesscorrection": "LoudnessCorrection: ignored",
        ]

        mutating func warn(_ place: String, _ message: String) { warnings.append("\(place): \(message)") }

        mutating func add(_ edit: (inout Chain) -> Void) {
            if scope.left { edit(&left) }
            if scope.right { edit(&right) }
            if !scope.left && !scope.right { elsewhere += 1 }
        }

        mutating func read(_ text: String, file: URL?, label: String?, depth: Int) {
            if let file { stack.append(file.path) }
            defer { if file != nil { stack.removeLast() } }
            for (index, raw) in lines(text).enumerated() {
                guard let line = Line(String(raw)) else { continue }
                let place = depth == 0 && index < places.count ? places[index] : (label.map { "\($0) " } ?? "") + "line \(index + 1)"
                switch line.command {
                case "filter":
                    switch APOFormat.filter(line.parameters) {
                    case .filter(let filter): add { $0.filters.append(filter) }
                    case .silent: break
                    case .skipped(let why): warn(place, "skipped a filter: \(why)")
                    }
                case "preamp":
                    guard let raw = capture(preampRegex, line.parameters), let value = number(raw) else {
                        warn(place, "skipped a Preamp: line without a number in dB"); continue
                    }
                    add { $0.preamp += value; $0.preampLines += 1 }
                case "graphiceq":
                    guard let reduced = graphic(line.parameters, at: fitFrequencies) else { warn(place, "skipped a GraphicEQ: line with fewer than two points"); continue }
                    if reduced.dropped > 0 { warn(place, "skipped \(reduced.dropped) malformed GraphicEQ points") }
                    warnings.append("GraphicEQ has \(reduced.points) points; reduced to 10 bands \u{2014} the model's ParametricEQ.txt is exact")
                    add { $0.graphics.append(reduced.bands) }
                case "channel":
                    let names = line.parameters.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.uppercased() }
                    let all = names.contains("ALL")
                    scope = (all || names.contains("L") || names.contains("1"), all || names.contains("R") || names.contains("2"))
                case "include":
                    include(line.parameters.trimmingCharacters(in: .whitespaces), from: file, place: place, depth: depth)
                default:
                    if let message = Self.ignored[line.command], ignoredCommands.insert(message).inserted { warnings.append(message) }
                }
            }
        }

        mutating func include(_ path: String, from file: URL?, place: String, depth: Int) {
            guard !path.isEmpty else { warn(place, "skipped an Include: line without a file name"); return }
            guard let file else {
                warn(place, "not following Include: \(path), only a file import can include other files"); return
            }
            guard depth < maxIncludeDepth else {
                warn(place, "not following Include: \(path), includes nest deeper than \(maxIncludeDepth)"); return
            }
            guard includedFiles < maxIncludedFiles else {
                warn(place, "not following Include: \(path), already read \(maxIncludedFiles) included files"); return
            }
            let target = URL(fileURLWithPath: path, relativeTo: file.deletingLastPathComponent())
                .absoluteURL.standardizedFileURL.resolvingSymlinksInPath()
            if !path.hasPrefix("/"), let folder, target.path != folder, !target.path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") {
                warn(place, "not following Include: \(path), it leads outside the imported file's folder"); return
            }
            guard !stack.contains(target.path) else { warn(place, "not following Include: \(path), it includes itself"); return }
            let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
            if let attributes, attributes[.type] as? FileAttributeType != .typeRegular {
                warn(place, "not following Include: \(path), \(target.path) is not a regular file"); return
            }
            if let size = attributes?[.size] as? Int, size > maxIncludeBytes {
                warn(place, "not following Include: \(path), \(target.path) is larger than \(maxIncludeBytes >> 20) MB"); return
            }
            guard let data = try? Data(contentsOf: target), let text = ImportText.decode(data) else {
                warn(place, "not following Include: \(path), cannot read \(target.path)"); return
            }
            includedFiles += 1
            read(text, file: target, label: target.lastPathComponent, depth: depth + 1)
        }

        mutating func finish(isREW: Bool) throws -> ImportResult {
            if left != right { warnings.append("left and right channels differ; imported the left channel") }
            if elsewhere > 0 { warnings.append("skipped \(elsewhere) \(elsewhere == 1 ? "line" : "lines") for channels other than left and right") }
            let chain = left
            var bands: [Double]?
            // What the GraphicEQ lines put into the preamp: the level their curve sits at.
            var level = 0.0
            if !chain.graphics.isEmpty {
                let summed = fitFrequencies.indices.map { i in chain.graphics.reduce(0) { $0 + $1[i] } }
                // 0 always fits, so a file preamp already out of range is refused below, not hidden in the fit.
                let room = min(0, Config.preampRange.lowerBound - chain.preamp)...max(0, Config.preampRange.upperBound - chain.preamp)
                let fit = fitBands(summed, levelRange: room)
                if fit.limited {
                    warnings.append(String(format: "GraphicEQ gains beyond ±%g dB were limited to it", Config.gainRange.upperBound))
                }
                level = min(max((fit.level * 10).rounded() / 10, room.lowerBound), room.upperBound)
                bands = fit.bands.map { ($0 * 10).rounded() / 10 }
            }
            var filters = chain.filters
            var format = isREW ? "REW filter settings" : "AutoEq / Equalizer APO parametric"
            if bands == nil, let fixed = fixedBands(filters) {
                bands = fixed
                filters = []
                format = "AutoEq FixedBandEQ (10 bands)"
            } else if bands != nil {
                format = filters.isEmpty ? "GraphicEQ (reduced to 10 bands)" : "Equalizer APO GraphicEQ + filters"
            }
            guard !filters.isEmpty || bands != nil else {
                throw warnings.isEmpty ? ImportError.unrecognized : ImportError.nothingUsable(warnings)
            }
            // GraphicEQ.txt has no Preamp: line, AutoEq bakes it into the curve; APO plays the curve
            // as written, so its level is the preamp here, not a guess at headroom.
            let preamp = chain.preamp + level
            guard preamp.isFinite, Config.preampRange.contains(preamp) else { throw ImportError.preampOutOfRange(preamp) }
            return ImportResult(filters: filters, bands: bands, preamp: preamp, format: format, warnings: warnings)
        }
    }
}
