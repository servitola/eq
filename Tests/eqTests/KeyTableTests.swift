import XCTest
@testable import eq

final class KeyTableTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    private func landings() -> [(context: KeyContext, key: Key, twinOf: Key)] {
        var result: [(KeyContext, Key, Key)] = []
        for context in KeyContext.allCases {
            let bound = Set(KeyTable.bindings(in: context).flatMap(\.keys))
            for binding in KeyTable.bindings(in: context) {
                for key in binding.keys {
                    guard let twin = PhysicalKeys.twin(key), bound.contains(twin) else { continue }
                    let owner = KeyTable.bindings(in: context).first { $0.keys.contains(twin) }!
                    let ownerAction = owner.action(at: owner.keys.firstIndex(of: twin)!)
                    if ownerAction != binding.action(at: binding.keys.firstIndex(of: key)!) { result.append((context, twin, key)) }
                }
            }
        }
        return result
    }

    func testEveryRussianTwinThatLandsOnAnotherBindingIsDeclared() {
        let found = landings().map { "\($0.context) \($0.key.name) ← \($0.twinOf.name)" }.sorted()
        let declared = KeyTable.collisions.map { "\($0.context) \($0.key.name) ← \($0.twinOf.name)" }.sorted()
        XCTAssertEqual(found, declared)
    }

    func testTheUSKeyWinsADeclaredCollision() {
        XCTAssertEqual(KeyTable.action(for: .char("?"), in: .meter), .help)
        XCTAssertEqual(KeyTable.action(for: .char(";"), in: .meter), .palette)
        XCTAssertEqual(KeyTable.action(for: .char(","), in: .meter), .knob(-0.5))
    }

    func testNoKeyIsBoundTwiceInOneContext() {
        for context in KeyContext.allCases {
            var seen: [Key: String] = [:]
            for binding in KeyTable.bindings(in: context) {
                for key in binding.keys {
                    XCTAssertNil(seen[key], "\(context): \(key.name) in \(seen[key] ?? "") and \(binding.label)")
                    seen[key] = binding.label
                }
            }
        }
    }

    func testTwinsAreDerivedFromThePhysicalKeys() {
        XCTAssertEqual(PhysicalKeys.us.count, PhysicalKeys.ru.count)
        XCTAssertEqual(Set(PhysicalKeys.us).count, PhysicalKeys.us.count)
        for (us, ru) in [("q", "й"), ("z", "я"), ("[", "х"), ("]", "ъ"), (";", "ж"), ("^", ":"), ("&", "?"), ("$", ";"), ("B", "И")] {
            XCTAssertEqual(PhysicalKeys.twin(.char(Character(us))), .char(Character(ru)), us)
        }
        XCTAssertNil(PhysicalKeys.twin(.char("1")), "a digit is the same on both layouts")
        XCTAssertNil(PhysicalKeys.twin(.up))
        XCTAssertEqual(KeyTable.action(for: .char("Ш"), in: .meter), .instruments)
        XCTAssertEqual(KeyTable.action(for: .char("л"), in: .help), .scrollUp, "k's twin scrolls the overlay")
    }

    func testEveryMeterActionHasAKey() {
        let reachable = Set(KeyTable.bindings.flatMap { binding in binding.keys.indices.compactMap { binding.action(at: $0).map { "\($0)" } } })
        let needed: [WatchAction] = [.bandStep(0, 0.5), .bandStep(9, -0.5), .preamp(0.5), .preamp(-0.5), .bass(0.5), .treble(-0.5),
                                     .cyclePreset, .previousPreset, .undo, .startSave, .zones, .instruments, .help, .quit,
                                     .focusNext, .focusPrevious, .unfocus, .listen, .knob(0.5), .knob(-0.5), .cycleComp, .cycleColour,
                                     .colourAmount, .mouse, .palette, .closeModal, .scrollUp, .scrollDown]
        for action in needed { XCTAssertTrue(reachable.contains("\(action)"), "\(action)") }
    }

    func testBarLabelsFitTwelveColumns() {
        for binding in KeyTable.bindings {
            guard let bar = binding.bar else { continue }
            let longest = [bar.text] + (binding.state.map { [$0(KeyState()), $0(KeyState(strip: true, listening: true, mouse: true))] } ?? [])
            XCTAssertLessThanOrEqual(TerminalText.width(bar.key + " " + longest.joined(separator: " ")), 16, binding.label)
            XCTAssertLessThanOrEqual(TerminalText.width(bar.text), 12, binding.label)
        }
    }

    func testKeybarKeepsKeysAndQuitAndDropsWholeEntries() {
        let full = Keybar.line(.meter, state: KeyState(), width: 400)
        XCTAssertEqual(full, "1…0 band  ⇧ down  z zones off  i instruments  [ ] focus  +− preamp  p preset  u undo  s save  "
                       + "b t bass/treble  c comp  v color  m mouse off  ? keys  q quit")
        let entries = full.components(separatedBy: "  ")
        for width in 14..<TerminalText.width(full) {
            let line = Keybar.line(.meter, state: KeyState(), width: width)
            XCTAssertLessThanOrEqual(TerminalText.width(line), width, "\(width)")
            XCTAssertTrue(line.hasSuffix("? keys  q quit"), line)
            XCTAssertTrue(line.components(separatedBy: "  ").allSatisfy(entries.contains), line)
        }
        XCTAssertEqual(Keybar.line(.meter, state: KeyState(), width: 80, compact: true), "? keys  q quit")
        XCTAssertEqual(Keybar.line(.meter, state: KeyState(), width: 8), "q quit")
    }

    func testKeybarFollowsTheState() {
        let focused = Keybar.line(.meter, state: KeyState(strip: true, focused: true, listening: true), width: 120)
        XCTAssertTrue(focused.contains("z zones on"), focused)
        XCTAssertTrue(focused.contains("← → knob  l listen on  Esc unfocus"), focused)
        XCTAssertFalse(Keybar.line(.meter, state: KeyState(), width: 400).contains("listen"), "l needs a focus")
        XCTAssertEqual(Keybar.line(.help, state: KeyState(), width: 80), "↑↓ scroll  Esc close")
        XCTAssertEqual(Keybar.line(.prompt, state: KeyState(), width: 80), "Enter save  Esc cancel")
    }

    func testReadmeKeysSectionIsTheTable() throws {
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        XCTAssertTrue(text.contains("### Keys\n\n" + KeyHelp.markdown() + "\n"),
                      "README \"Keys\" must be KeyHelp.markdown():\n" + KeyHelp.markdown())
    }

    func testHelpListsEveryMeterBinding() {
        let lines = KeyHelp.lines()
        for binding in KeyTable.bindings(in: .meter) {
            XCTAssertTrue(lines.contains { $0.key == binding.label && $0.text == binding.help }, binding.label)
        }
        for collision in KeyTable.collisions { XCTAssertTrue(lines.contains { $0.text == collision.note }) }
    }

    func testWidthCountsColumnsNotCharacters() {
        TerminalText.useUTF8Widths()
        XCTAssertEqual(TerminalText.width("BE-RCA"), 6)
        XCTAssertEqual(TerminalText.width("Наушники"), 8)
        XCTAssertEqual(TerminalText.width("耳机"), 4)
        XCTAssertEqual(TerminalText.width("🎧 AirPods"), 10)
        XCTAssertEqual(TerminalText.width("❤️"), 2, "a text heart made emoji by U+FE0F")
        XCTAssertEqual(TerminalText.width("e\u{301}"), 1, "a combining accent adds nothing")
        XCTAssertEqual(TerminalText.width("█▁⇧←…"), 5)
        XCTAssertEqual(TerminalText.prefix("耳机耳机", columns: 5), "耳机 ", "a wide glyph never straddles the edge")
    }
}
