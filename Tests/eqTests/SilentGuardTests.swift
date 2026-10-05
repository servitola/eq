import XCTest
@testable import eq

/// Output mutes as Core Audio keeps them, per device and element, never a real device's.
final class FakeMute: MuteControl {
    var elements: [String: [UInt32]] = [:]
    var muted: [String: [UInt32: Bool]] = [:]
    var refuses: Set<String> = []
    private(set) var watchers: [String: () -> Void] = [:]
    private(set) var sets: [String] = []

    func connect(_ uid: String, elements: [UInt32] = [0], muted: Bool = false) {
        self.elements[uid] = elements
        self.muted[uid] = Dictionary(uniqueKeysWithValues: elements.map { ($0, muted) })
    }

    func disconnect(_ uid: String) {
        elements[uid] = nil
    }

    func muteElements(_ uid: String) -> [UInt32]? { elements[uid] }

    func isMuted(_ uid: String, _ element: UInt32) -> Bool? { elements[uid] == nil ? nil : muted[uid]?[element] }

    func setMuted(_ uid: String, _ element: UInt32, _ value: Bool) -> Bool {
        guard elements[uid] != nil, !refuses.contains(uid) else { return false }
        sets.append("\(uid)/\(element)=\(value)")
        let changed = muted[uid]?[element] != value
        muted[uid, default: [:]][element] = value
        if changed { watchers[uid]?() }
        return true
    }

    func watch(_ uid: String, _ elements: [UInt32], _ changed: @escaping () -> Void) { watchers[uid] = changed }

    func unwatch(_ uid: String) { watchers[uid] = nil }

    /// Volume keys or Control Center, behind eq's back.
    func userUnmutes(_ uid: String) {
        for element in elements[uid] ?? [] { muted[uid]?[element] = false }
        watchers[uid]?()
    }
}

final class SilentGuardTests: XCTestCase {
    private var dir: URL!
    private var mute: FakeMute!
    private var actions: [String] = []
    private var logs: [String] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("eq-silent-guard-\(UUID().uuidString)")
        mute = FakeMute()
        actions = []
        logs = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appendingPathComponent("silent-mutes.json") }

    private func make() -> SilentGuard {
        SilentGuard(control: mute, file: file, log: { [unowned self] in self.logs.append($0) },
                    onAction: { [unowned self] uid, action in self.actions.append("\(uid) \(action.rawValue)") })
    }

    func testHoldsTheMuteOfASilentDeviceThatIsNotPlayingAndLeavesOthersAlone() {
        mute.connect("STUDIO", elements: [0, 1, 2])
        mute.connect("HEADPHONES")
        let guarding = make()
        guarding.update(["STUDIO"])
        XCTAssertEqual(mute.muted["STUDIO"], [0: true, 1: true, 2: true])
        XCTAssertEqual(mute.muted["HEADPHONES"], [0: false])
        XCTAssertFalse(mute.sets.contains { $0.hasPrefix("HEADPHONES") })
        XCTAssertEqual(guarding.states["STUDIO"], SilentGuard.State(connected: true, muted: true))
        XCTAssertEqual(actions, ["STUDIO muted"])
        XCTAssertNotNil(mute.watchers["STUDIO"])
        XCTAssertNil(mute.watchers["HEADPHONES"])
    }

    func testAnUnmuteIsUndoneAtOnce() {
        mute.connect("STUDIO")
        let guarding = make()
        guarding.update(["STUDIO"])
        mute.userUnmutes("STUDIO")
        XCTAssertEqual(mute.muted["STUDIO"], [0: true])
        XCTAssertEqual(actions, ["STUDIO muted", "STUDIO remuted"])
        mute.userUnmutes("STUDIO")
        XCTAssertEqual(actions.last, "STUDIO remuted")
        XCTAssertEqual(guarding.states["STUDIO"]?.muted, true)
    }

    func testUnsilencingPutsBackTheMuteItHadBefore() {
        mute.connect("STUDIO")
        mute.connect("KITCHEN", elements: [1, 2])
        mute.muted["KITCHEN"] = [1: true, 2: false]
        let guarding = make()
        guarding.update(["STUDIO", "KITCHEN"])
        XCTAssertEqual(mute.muted["KITCHEN"], [1: true, 2: true])
        guarding.update([])
        XCTAssertEqual(mute.muted["STUDIO"], [0: false])
        XCTAssertEqual(mute.muted["KITCHEN"], [1: true, 2: false])
        XCTAssertNil(mute.watchers["STUDIO"])
        XCTAssertEqual(actions.suffix(2), ["KITCHEN restored", "STUDIO restored"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        mute.userUnmutes("STUDIO")
        XCTAssertEqual(actions.count, 4)
    }

    /// The daemon restarting while it holds a mute must not take that mute for the device's own.
    func testTheMuteToPutBackSurvivesARestart() {
        mute.connect("STUDIO")
        make().update(["STUDIO"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let again = make()
        again.update(["STUDIO"])
        again.update([])
        XCTAssertEqual(mute.muted["STUDIO"], [0: false])
    }

    func testAGoneDeviceIsPutBackWhenItReturns() {
        mute.connect("STUDIO")
        let guarding = make()
        guarding.update(["STUDIO"])
        mute.disconnect("STUDIO")
        guarding.update(["STUDIO"])
        XCTAssertEqual(guarding.states["STUDIO"], SilentGuard.State(connected: false, muted: nil))
        XCTAssertNil(mute.watchers["STUDIO"])
        guarding.update([])
        XCTAssertFalse(actions.contains("STUDIO restored"))
        mute.connect("STUDIO", muted: true)
        guarding.update([])
        XCTAssertEqual(mute.muted["STUDIO"], [0: false])
        XCTAssertEqual(actions.last, "STUDIO restored")
    }

    func testADeviceComingBackIsMutedAndWatchedAgain() {
        let guarding = make()
        guarding.update(["STUDIO"])
        XCTAssertEqual(actions, [])
        mute.connect("STUDIO")
        guarding.update(["STUDIO"])
        XCTAssertEqual(mute.muted["STUDIO"], [0: true])
        XCTAssertNotNil(mute.watchers["STUDIO"])
        XCTAssertEqual(actions, ["STUDIO muted"])
        guarding.update(["STUDIO"])
        XCTAssertEqual(actions, ["STUDIO muted"])
    }

    func testADeviceWithoutAMuteIsSaidOnce() {
        mute.connect("HDMI", elements: [])
        let guarding = make()
        guarding.update(["HDMI"])
        guarding.update(["HDMI"])
        XCTAssertEqual(guarding.states["HDMI"], SilentGuard.State(connected: true, muted: nil))
        XCTAssertEqual(actions, ["HDMI unmutable"])
        XCTAssertEqual(mute.sets, [])
    }

    func testAMuteThatWillNotSetIsLoggedAndNotHeld() {
        mute.connect("STUDIO")
        mute.refuses = ["STUDIO"]
        let guarding = make()
        guarding.update(["STUDIO"])
        XCTAssertEqual(guarding.states["STUDIO"]?.muted, false)
        XCTAssertEqual(actions, [])
        XCTAssertTrue(logs.contains { $0.contains("cannot mute STUDIO") }, "\(logs)")
    }
}

final class SilentEventTests: XCTestCase {
    func testTheEventLineAndOneOutputEventPerStretch() throws {
        let line = String(decoding: try DaemonEvent.encodeLine(.silent(device: "Mac Studio Speakers", uid: "BUILTIN", action: "remuted"), at: 1.5),
                          as: UTF8.self)
        XCTAssertEqual(line, #"{"action":"remuted","device":"Mac Studio Speakers","event":"silent","t":1.5,"uid":"BUILTIN"}"# + "\n")

        var published: [DaemonEvent] = []
        let tracker = EventTracker(enabled: true, hooks: Hooks(schedule: { _, _ in }, run: { _ in })) { published.append($0) }
        XCTAssertTrue(tracker.silent(device: "S", uid: "BUILTIN", action: EventTracker.silentOutput))
        XCTAssertFalse(tracker.silent(device: "S", uid: "BUILTIN", action: EventTracker.silentOutput))
        XCTAssertTrue(tracker.silent(device: "S", uid: "BUILTIN", action: "remuted"))
        XCTAssertTrue(tracker.silent(device: "S", uid: "BUILTIN", action: "remuted"))
        tracker.notSilent()
        XCTAssertTrue(tracker.silent(device: "S", uid: "BUILTIN", action: EventTracker.silentOutput))
        XCTAssertEqual(published.count, 4)
        let entry = try XCTUnwrap(EventEntry.decode(String(line.dropLast())))
        XCTAssertEqual(entry.kind, "silent")
        XCTAssertEqual(entry.text, "Mac Studio Speakers was unmuted: muted again")
    }
}
