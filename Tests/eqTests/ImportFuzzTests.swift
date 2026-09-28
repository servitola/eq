import XCTest
@testable import eq

/// Every importer takes files from the internet. Mutated fixtures go through the real entry point:
/// each case must return promptly, never trap, and anything it returns must be a curve eq can run.
final class ImportFuzzTests: XCTestCase {
    /// SplitMix64: the same cases on every run, so a failure names a case that can be replayed.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    static let blowUps = ["1e308", "-1e308", "1e999", "99999999999999999999999", "nan", "-inf", ".inf", "0", "-0", "1e-320",
                          "true", "\"7\"", "[]", "{}", "null", "-", "1,5", "0x10"]

    static let numberPattern = try! NSRegularExpression(pattern: #"-?[0-9]+(\.[0-9]+)?"#)

    static func mutate(_ data: Data, _ random: inout Random) -> Data {
        var bytes = [UInt8](data)
        guard !bytes.isEmpty else { return data }
        switch random.below(5) {
        case 0:
            for _ in 0...random.below(8) { bytes[random.below(bytes.count)] = UInt8(truncatingIfNeeded: random.next()) }
        case 1:
            bytes = Array(bytes.prefix(random.below(bytes.count)))
        case 2:
            // A number somewhere in the file becomes a hostile one.
            let text = String(decoding: bytes, as: UTF8.self)
            let numbers = numberPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard !numbers.isEmpty else { return data }
            var mutated = text as NSString
            for _ in 0...random.below(4) {
                let match = numbers[random.below(numbers.count)]
                guard match.range.location + match.range.length <= mutated.length else { continue }
                mutated = mutated.replacingCharacters(in: match.range, with: blowUps[random.below(blowUps.count)]) as NSString
            }
            bytes = Array((mutated as String).utf8)
        case 3:
            let start = random.below(bytes.count), length = random.below(min(64, bytes.count - start) + 1)
            let chunk = bytes[start..<(start + length)]
            let at = random.below(bytes.count)
            bytes.insert(contentsOf: Array(repeating: chunk, count: 1 + random.below(3)).joined(), at: at)
        default:
            let start = random.below(bytes.count)
            bytes.removeSubrange(start..<min(bytes.count, start + 1 + random.below(32)))
        }
        return Data(bytes)
    }

    static func checkValid(_ result: ImportResult, _ label: String) {
        XCTAssertTrue(result.preamp.isFinite && Config.preampRange.contains(result.preamp), "\(label): preamp \(result.preamp)")
        if let bands = result.bands {
            XCTAssertEqual(bands.count, Config.bandFrequencies.count, label)
            XCTAssertTrue(bands.allSatisfy { $0.isFinite && Config.gainRange.contains($0) }, "\(label): bands \(bands)")
        }
        XCTAssertFalse(result.filters.isEmpty && result.bands == nil, "\(label): nothing imported yet no error")
        for filter in result.filters {
            XCTAssertTrue(Config.filterFrequencyRange.contains(filter.frequency) && Config.filterGainRange.contains(filter.gain)
                && Config.filterQRange.contains(filter.q), "\(label): \(filter)")
        }
        XCTAssertNil(Config.firstUnstableFilter(result.filters, sampleRate: Config.stabilityCheckRate), label)
    }

    /// Runs `perFixture` mutations of every fixture; returns the number of cases and the slowest one.
    @discardableResult
    static func fuzz(perFixture: Int, seed: UInt64) throws -> (cases: Int, slowest: Double) {
        var random = Random(state: seed)
        var cases = 0, slowest = 0.0
        for (file, _) in FormatSniffTests.fixtures {
            let original = try formatFixture(file)
            for n in 0..<perFixture {
                // Mutations stack now and then, so damage compounds the way a bad download's does.
                var data = mutate(original, &random)
                if random.below(4) == 0 { data = mutate(data, &random) }
                let start = Date()
                let result = try? EQFormats.parse(data, filename: file)
                let elapsed = Date().timeIntervalSince(start)
                slowest = max(slowest, elapsed)
                XCTAssertLessThan(elapsed, 0.25, "\(file) case \(n) took \(elapsed) s")
                if let result { checkValid(result, "\(file) case \(n)") }
                cases += 1
            }
        }
        return (cases, slowest)
    }

    // 22 400 cases over ten seeds ran clean in review (slowest 34 ms, a GraphicEQ fit); the suite keeps a slice that fits in 2 s of a debug build.
    func testMutatedFixturesImportOrRefuseQuickly() throws {
        let start = Date()
        let run = try Self.fuzz(perFixture: 50, seed: 0x5EED)
        XCTAssertEqual(run.cases, 50 * FormatSniffTests.fixtures.count)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
