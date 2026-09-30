import EQTerm
import XCTest
@testable import eq

final class KeyTableTests: XCTestCase {
    override func setUp() { Paint.forced = false }
    override func tearDown() { Paint.forced = nil }

    /// A key's action in `context` as the table has it on a US layout: the context's own, then
    /// every view's.
    private func direct(_ key: Key, in context: KeyContext) -> WatchAction?? {
        let lists = context == .global || !context.isView ? [KeyTable.bindings(in: context)]
            : [KeyTable.bindings(in: context), KeyTable.bindings(in: .global)]
        for list in lists {
            if let owner = list.first(where: { $0.keys.contains(key) }) { return .some(owner.action(at: owner.keys.firstIndex(of: key)!)) }
        }
        return nil
    }

    private func landings() -> [(context: KeyContext, key: Key, twinOf: Key)] {
        var result: [(KeyContext, Key, Key)] = []
        for context in KeyContext.allCases {
            for binding in KeyTable.effective(context) {
                for (index, key) in binding.keys.enumerated() {
                    guard let twin = PhysicalKeys.twin(key), let owner = direct(twin, in: context) else { continue }
                    if owner != binding.action(at: index) { result.append((context, twin, key)) }
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
        XCTAssertEqual(KeyTable.action(for: .char("Ш"), in: .meter), .go(.instruments))
        XCTAssertEqual(KeyTable.action(for: .char("ж"), in: .events), .palette, "every view's key, on every layout")
        XCTAssertEqual(KeyTable.action(for: .char("у"), in: .go), .go(.events))
        XCTAssertEqual(KeyTable.action(for: .char("л"), in: .help), .scrollUp, "k's twin scrolls the overlay")
    }

    func testEveryMeterActionHasAKey() {
        let reachable = Set(KeyTable.bindings.flatMap { binding in binding.keys.indices.compactMap { binding.action(at: $0).map { "\($0)" } } })
        let needed: [WatchAction] = [.bandStep(0, 0.5), .bandStep(9, -0.5), .preamp(0.5), .preamp(-0.5), .bass(0.5), .treble(-0.5),
                                     .cyclePreset, .previousPreset, .undo, .startSave, .zones, .help, .quit,
                                     .focusNext, .focusPrevious, .unfocus, .listen, .knob(0.5), .knob(-0.5), .cycleComp, .cycleColour,
                                     .colourAmount, .mouse, .palette, .closeModal, .scrollUp, .scrollDown, .pageUp, .pageDown, .top, .bottom,
                                     .goMenu, .go(.meter), .go(.instruments), .go(.events), .back, .focusInMeter, .pause, .filter, .stop,
                                     .suspend, .nextLook, .nextPalette]
        for action in needed { XCTAssertTrue(reachable.contains("\(action)"), "\(action)") }
    }

    func testBarLabelsFitTwelveColumns() {
        for binding in KeyTable.bindings {
            guard let bar = binding.bar else { continue }
            let states = binding.state.map { [$0(KeyState()), $0(KeyState(strip: true, listening: true, mouse: true, following: true, driver: true))] }
            for state in states ?? [""] {
                XCTAssertLessThanOrEqual(TerminalText.width(([bar.key, bar.text, state]).filter { !$0.isEmpty }.joined(separator: " ")), 16, binding.label)
            }
            XCTAssertLessThanOrEqual(TerminalText.width(bar.text), 12, binding.label)
        }
    }

    func testKeybarKeepsKeysAndQuitAndDropsWholeEntries() {
        let full = Keybar.line(.meter, state: KeyState(), width: 400)
        XCTAssertEqual(full, "1…0 band  ⇧ down  z zones off  i instruments  [ ] focus  +− preamp  p preset  u undo  s save  "
                       + "y look  b t bass/treble  c comp  v color  m mouse off  g go  ; cmd  ? keys  q quit")
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
        XCTAssertEqual(Keybar.line(.help, state: KeyState(), width: 80), "↑↓ scroll  / filter  Esc close")
        XCTAssertEqual(Keybar.line(.prompt, state: KeyState(), width: 80), "Enter save  Esc cancel")
        XCTAssertEqual(Keybar.line(.go, state: KeyState(), width: 200),
                       "m meter  t tune  i instruments  p presets  d devices  f filters  a apps  s system  h history  e events  Esc cancel")
        XCTAssertEqual(Keybar.line(.palette, state: KeyState(), width: 80), "Tab complete  ↑↓ choose  Enter run  Esc close")
        XCTAssertEqual(Keybar.line(.instruments, state: KeyState(back: true), width: 200),
                       "↑↓ move  Enter focus  ← → knob  l listen off  Esc back  u undo  y look  m mouse off  g go  ; cmd  ? keys  q quit")
        XCTAssertEqual(Keybar.line(.events, state: KeyState(paused: true, back: true), width: 80),
                       "↑↓ scroll  Space pause  / filter  Esc back  u undo  y look  ? keys  q quit")
        XCTAssertTrue(Keybar.line(.pane, state: KeyState(running: true), width: 80).contains("Ctrl-C stop"))
        XCTAssertFalse(Keybar.line(.pane, state: KeyState(), width: 80).contains("Ctrl-C"), "only while it runs")
    }

    func testReadmeKeysSectionIsTheTable() throws {
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("README.md")
        var text = try String(contentsOf: readme, encoding: .utf8)
        if ProcessInfo.processInfo.environment["EQ_UPDATE_GOLDEN"] != nil, let start = text.range(of: "### Keys\n\n"),
           let end = text.range(of: "\n\n", range: start.upperBound..<text.endIndex) {
            text.replaceSubrange(start.upperBound..<end.lowerBound, with: KeyHelp.markdown())
            try text.write(to: readme, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(text.contains("### Keys\n\n" + KeyHelp.markdown() + "\n"),
                      "README \"Keys\" must be KeyHelp.markdown():\n" + KeyHelp.markdown())
    }

    func testManKeysSectionIsTheTable() {
        let page = ManPage.render(version: "2026.09.30")
        XCTAssertTrue(page.contains("\n" + KeyHelp.man().joined(separator: "\n") + "\n.SH ENVIRONMENT\n"), "KEYS comes from KeyHelp.man(), before ENVIRONMENT")
        for context in KeyHelp.contexts {
            for binding in KeyTable.bindings(in: context) {
                XCTAssertTrue(page.contains(".B " + ManPage.escape(binding.label) + "\n" + ManPage.escape(binding.help)), "\(context) \(binding.label)")
            }
        }
        XCTAssertTrue(page.contains(".SS After g\n"))
        XCTAssertTrue(page.contains(ManPage.escape("the command palette: any eq command, run beside the screen (Russian: ж)")))
        XCTAssertFalse(page.split(separator: "\n").contains { $0.hasPrefix(".") && !$0.hasPrefix(".SH") && !$0.hasPrefix(".SS") && !$0.hasPrefix(".TP")
            && !$0.hasPrefix(".B") && !$0.hasPrefix(".TH") && !$0.hasPrefix(".nf") && !$0.hasPrefix(".fi") && !$0.hasPrefix(".RS")
            && !$0.hasPrefix(".RE") && !$0.hasPrefix(".br") && !$0.hasPrefix(".PP") && !$0.hasPrefix(".I") }, "no text line reads as a request")
    }

    func testHelpListsTheViewsKeysThenEveryViewsAndTheMenus() {
        for view in TUIView.allCases {
            let lines = KeyHelp.lines(view: view.context)
            for context in [view.context, .global, .go, .palette, .pane] {
                for binding in KeyTable.bindings(in: context) {
                    XCTAssertTrue(lines.contains { $0.key == binding.label && $0.text == binding.help }, "\(view) \(binding.label)")
                }
            }
            let others = TUIView.allCases.filter { $0 != view }.flatMap { KeyTable.bindings(in: $0.context) }
                .filter { other in !KeyTable.bindings(in: view.context).contains { $0.help == other.help } }
            for binding in others { XCTAssertFalse(lines.contains { $0.text == binding.help }, "\(view) shows \(binding.label)") }
            XCTAssertEqual(lines.first?.key, KeyTable.bindings(in: view.context).first?.group, "the view's own keys come first")
        }
        let meter = KeyHelp.lines(view: .meter)
        for collision in KeyTable.collisions where collision.context == .meter { XCTAssertTrue(meter.contains { $0.text == collision.note }) }
    }

    func testThePaletteNamesComeFromTheTable() {
        let names = KeyTable.named.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        for name in ["zones", "look", "keys", "quit", "go meter", "go instruments", "go events"] { XCTAssertTrue(names.contains(name), name) }
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
