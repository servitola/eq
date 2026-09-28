import CoreAudio
import EQCore
import XCTest
@testable import eq

final class ModeSwitchTests: XCTestCase {
    private var journal: Journal!
    private var driver: FakeDriver!
    private var system: FakeAudioSystem!
    private var present = true

    override func setUp() {
        journal = Journal()
        driver = FakeDriver()
        driver.journal = journal
        driver.names = ["BT-RCA": "BE-RCA", "BUILTIN": "MacBook Pro Speakers"]
        system = FakeAudioSystem()
        system.journal = journal
        present = true
    }

    private func switcher(deadline: TimeInterval = 1) -> ModeSwitch {
        ModeSwitch(system: system, driver: { [unowned self] in self.present ? self.driver : nil }, deadline: deadline, wait: { _ in })
    }

    func testReadyRefusesAMissingOldOrDisabledDriver() {
        present = false
        XCTAssertThrowsError(try switcher().ready()) { XCTAssertEqual($0 as? ModeSwitch.Failure, .notInstalled) }
        present = true
        driver.state["settingsVersion"] = nil
        XCTAssertThrowsError(try switcher().ready()) { XCTAssertEqual($0 as? ModeSwitch.Failure, .tooOld(nil)) }
        driver.state["settingsVersion"] = 0
        XCTAssertThrowsError(try switcher().ready()) { XCTAssertEqual($0 as? ModeSwitch.Failure, .tooOld(0)) }
        driver.state["settingsVersion"] = 1
        driver.state["killed"] = true
        XCTAssertThrowsError(try switcher().ready()) { XCTAssertEqual($0 as? ModeSwitch.Failure, .disabled) }
        driver.state["killed"] = false
        XCTAssertEqual(try switcher().ready().health.settingsVersion, 1)
        XCTAssertTrue("\(ModeSwitch.Failure.notInstalled)".contains("sudo Driver/dev-install.sh"))
    }

    func testTheTargetIsTheRealDefaultElseTheDriversOwn() throws {
        let health = DriverHealth(driver.state)
        XCTAssertEqual(try switcher().target(health), FakeAudioSystem.speaker)
        for other in [FakeAudioSystem.eq, FakeAudioSystem.proxy, FakeAudioSystem.aggregate, FakeAudioSystem.airplay] {
            system.current = other.uid
            XCTAssertEqual(try switcher().target(health), FakeAudioSystem.builtIn, other.name)
        }
        var lost = health
        lost.target = "GONE"
        XCTAssertThrowsError(try switcher().target(lost)) { XCTAssertEqual($0 as? ModeSwitch.Failure, .noTarget) }
    }

    func testEnterShowsTargetsPushesThenTakesTheDefault() throws {
        driver.state["hidden"] = true
        let (port, health) = try switcher().ready()
        try switcher().enter(target: FakeAudioSystem.speaker, port: port, health: health) { port, uid in
            try port.write(settings: DriverControl.record(EQProcessor.settings(profile: .flat, enabled: true), targetUID: uid, serial: 1)!)
        }
        XCTAssertEqual(journal.all, ["hidden false", "target BT-RCA", "push BT-RCA", "default \(DriverControl.deviceUID)"])
        XCTAssertEqual(system.current, DriverControl.deviceUID)
    }

    /// A device shown a moment ago may not take the default at once.
    func testMakingTheDefaultRetriesUntilItReadsBack() throws {
        system.refusesFirst = 3
        try switcher().makeDefault(DriverControl.deviceUID, "the EQ device")
        XCTAssertEqual(system.current, DriverControl.deviceUID)
        system.current = "BT-RCA"
        system.refuses = [DriverControl.deviceUID]
        XCTAssertThrowsError(try switcher().makeDefault(DriverControl.deviceUID, "the EQ device"))
    }

    func testLeaveRestoresTheDefaultBeforeHiding() {
        system.current = DriverControl.deviceUID
        driver.state["target"] = "BT-RCA"
        let left = switcher().leave(remembered: nil)
        XCTAssertEqual(left, ModeSwitch.Left(output: FakeAudioSystem.speaker, hidden: true, problems: []))
        XCTAssertEqual(journal.all, ["default BT-RCA", "hidden true"])
    }

    func testLeaveOnARealDefaultOnlyHides() {
        system.current = "USB-DAC"
        XCTAssertEqual(switcher().leave(remembered: nil), ModeSwitch.Left(output: FakeAudioSystem.headphones, hidden: true, problems: []))
        XCTAssertEqual(journal.all, ["hidden true"])
    }

    /// The escape hatch with the plug-in wedged: the default output belongs to the system, so it
    /// still goes back, to the device the daemon remembered.
    func testLeaveRestoresSoundPastAWedgedDriver() {
        system.current = DriverControl.deviceUID
        driver.hangs = 0.5
        let started = Date()
        let left = switcher(deadline: 0.1).leave(remembered: "BT-RCA")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.45)
        XCTAssertEqual(left.output, FakeAudioSystem.speaker)
        XCTAssertFalse(left.hidden)
        XCTAssertTrue(left.problems.contains { $0.contains("did not answer") }, "\(left.problems)")
        XCTAssertEqual(system.current, "BT-RCA")
    }

    func testLeaveWithNothingRememberedPrefersTheBuiltInOutput() {
        system.current = DriverControl.deviceUID
        present = false
        XCTAssertEqual(switcher().leave(remembered: nil).output, FakeAudioSystem.builtIn)
    }

    func testLeaveReportsADefaultThatWillNotMove() {
        system.current = DriverControl.deviceUID
        system.refuses = ["BT-RCA", "BUILTIN", "USB-DAC"]
        driver.state["target"] = "BT-RCA"
        let left = switcher().leave(remembered: nil)
        XCTAssertNil(left.output)
        XCTAssertTrue(left.hidden)
        XCTAssertEqual(left.problems, ["macOS did not make BE-RCA the default output"])
        XCTAssertTrue(ModeSwitch.recovery.contains("sudo killall coreaudiod"))
    }
}

final class AudioPathsTests: XCTestCase {
    private var running: Set<AudioPaths.Path> = []
    private var calls: [String] = []
    private var driverStarts = true

    private func paths() -> AudioPaths {
        AudioPaths(
            startTap: { [unowned self] in self.start(.tap) },
            stopTap: { [unowned self] in self.running.remove(.tap); self.calls.append("stop tap") },
            startDriver: { [unowned self] in
                guard self.driverStarts else { self.calls.append("driver refused"); return false }
                self.start(.driver)
                return true
            },
            stopDriver: { [unowned self] restoring in self.running.remove(.driver); self.calls.append("stop driver \(restoring)") })
    }

    private func start(_ path: AudioPaths.Path) {
        XCTAssertTrue(running.isEmpty, "\(path) started while \(running) runs")
        running.insert(path)
        calls.append("start \(path.rawValue)")
    }

    func testNeverBothPaths() {
        let paths = paths()
        let sequence: [(AudioPaths.Path, Bool)] = [(.tap, true), (.driver, true), (.driver, true), (.tap, true), (.driver, true), (.tap, false)]
        for (wanted, restoring) in sequence {
            paths.run(wanted, restoring: restoring)
            XCTAssertEqual(running, [wanted])
            XCTAssertEqual(paths.active, wanted)
        }
        XCTAssertEqual(calls, ["start tap", "stop tap", "start driver", "stop driver true", "start tap", "stop tap", "start driver",
                               "stop driver false", "start tap"])
    }

    func testADriverThatWillNotStartLeavesTheTap() {
        let paths = paths()
        driverStarts = false
        XCTAssertEqual(paths.run(.driver), .tap)
        XCTAssertEqual(running, [.tap])
        driverStarts = true
        paths.run(.driver)
        XCTAssertEqual(running, [.driver])
        paths.restart()
        XCTAssertEqual(running, [.driver])
        XCTAssertEqual(calls.suffix(2), ["stop driver false", "start driver"])
    }

    func testWantedPath() {
        XCTAssertEqual(AudioPaths.wanted(.tap, driverPresent: true), .tap)
        XCTAssertEqual(AudioPaths.wanted(.driver, driverPresent: true), .driver)
        XCTAssertEqual(AudioPaths.wanted(.driver, driverPresent: false), .tap)
    }
}

final class DefaultFollowerTests: XCTestCase {
    private var clock: ManualClock!
    private var system: FakeAudioSystem!
    private var followed: [String] = []
    private var logs: [String] = []
    private var follower: DefaultFollower!

    override func setUp() {
        clock = ManualClock()
        system = FakeAudioSystem(current: DriverControl.deviceUID)
        followed = []
        logs = []
        follower = DefaultFollower(
            schedule: { [unowned self] in self.clock.schedule($0, $1) }, now: { [unowned self] in self.clock.now },
            current: { [unowned self] in self.system.defaultOutput() },
            follow: { [unowned self] device in
                self.followed.append(device.uid)
                self.system.current = DriverControl.deviceUID
                self.follower.changed()
            },
            log: { [unowned self] in self.logs.append($0) })
        system.onChange = { [unowned self] in self.follower.changed() }
    }

    func testDecisions() {
        XCTAssertEqual(DefaultFollower.decide(nil), .stay)
        XCTAssertEqual(DefaultFollower.decide(FakeAudioSystem.eq), .stay)
        XCTAssertEqual(DefaultFollower.decide(FakeAudioSystem.speaker), .follow(FakeAudioSystem.speaker))
        XCTAssertEqual(DefaultFollower.decide(FakeAudioSystem.builtIn), .follow(FakeAudioSystem.builtIn))
        for device in [FakeAudioSystem.proxy, FakeAudioSystem.aggregate, FakeAudioSystem.airplay] {
            XCTAssertEqual(DefaultFollower.decide(device), .leave(device), device.name)
        }
        let eqAggregate = AudioOutputDevice(id: 20, uid: AudioDeviceManager.aggregateUIDPrefix + "1", name: "eq", transportType: kAudioDeviceTransportTypeBuiltIn)
        XCTAssertEqual(DefaultFollower.decide(eqAggregate), .leave(eqAggregate))
    }

    func testFollowsTheDeviceTheUserSettledOn() {
        system.pick(FakeAudioSystem.speaker)
        clock.advance(0.2)
        system.pick(FakeAudioSystem.headphones)
        clock.advance(0.2)
        system.pick(FakeAudioSystem.builtIn)
        XCTAssertEqual(followed, [])
        clock.advance(0.39)
        XCTAssertEqual(followed, [])
        clock.advance(0.02)
        XCTAssertEqual(followed, ["BUILTIN"])
        // eq's own write made the EQ device default again; that event is nothing to act on.
        clock.advance(5)
        XCTAssertEqual(followed, ["BUILTIN"])
    }

    func testVirtualDevicesAreLeftAlone() {
        system.pick(FakeAudioSystem.proxy)
        clock.advance(1)
        system.pick(FakeAudioSystem.proxy)
        clock.advance(1)
        XCTAssertEqual(followed, [])
        XCTAssertEqual(logs, ["follow: Proxy Audio Device is not a device the EQ device plays on — left as the default output"])
        XCTAssertEqual(system.current, "ProxyAudioDevice_UID")
    }

    /// Something that keeps moving the default is not fought: after the burst limit eq backs off,
    /// then looks once more.
    func testStopsFightingARapidMover() {
        for _ in 0..<5 {
            system.pick(FakeAudioSystem.speaker)
            clock.advance(1)
        }
        XCTAssertEqual(followed, ["BT-RCA", "BT-RCA", "BT-RCA"])
        XCTAssertEqual(system.current, "BT-RCA")
        XCTAssertEqual(logs.count, 1)
        XCTAssertTrue(logs[0].contains("leaving BE-RCA as it is for 30 s"), logs[0])
        clock.advance(DefaultFollower.cooldown)
        XCTAssertEqual(followed.count, 4)
        XCTAssertEqual(system.current, DriverControl.deviceUID)
    }

    func testPausedIgnoresEvents() {
        follower.paused = true
        system.pick(FakeAudioSystem.speaker)
        clock.advance(1)
        follower.paused = false
        clock.advance(1)
        XCTAssertEqual(followed, [])
        follower.changed()
        follower.stop()
        clock.advance(1)
        XCTAssertEqual(followed, [])
    }
}

final class DriverSessionTests: XCTestCase {
    private var clock: ManualClock!
    private var system: FakeAudioSystem!
    private var driver: FakeDriver!
    private var journal: Journal!
    private var driverMode = true
    private var solo: SoloRange?
    private var targets: [String] = []
    private var logs: [String] = []
    private var session: DriverSession!

    private let curves: [String: Profile] = [
        "BT-RCA": Profile(name: "BE-RCA", preamp: -2, bands: [3, 2, 1, 0, 0, 0, 0, 1, 2, 3]),
        "BUILTIN": Profile(name: "MacBook Pro Speakers", preamp: 0, bands: Config.screenshotCurve),
    ]

    private func make(hideWhileDefault: Bool = false) {
        clock = ManualClock()
        journal = Journal()
        system = FakeAudioSystem()
        system.journal = journal
        driver = FakeDriver()
        driver.journal = journal
        driver.names = ["BT-RCA": "BE-RCA", "BUILTIN": "MacBook Pro Speakers", "USB-DAC": "DAC"]
        driver.state["hidden"] = true
        var serial: UInt64 = 100
        session = DriverSession(
            env: DriverSession.Environment(
                system: system, driver: { [unowned self] in self.driver },
                schedule: { [unowned self] in self.clock.schedule($0, $1) }, now: { [unowned self] in self.clock.now },
                serial: { serial += 1; return serial }, log: { [unowned self] in self.logs.append($0) },
                stillDriverMode: { [unowned self] in self.driverMode }, deadline: 1, wait: { _ in }),
            hideWhileDefault: hideWhileDefault,
            settings: { [unowned self] uid in
                var s = EQProcessor.settings(profile: self.curves[uid] ?? .flat, enabled: true)
                if let solo = self.solo { s.solo = true; s.soloLow = solo.low; s.soloHigh = solo.high }
                return s
            },
            onTarget: { [unowned self] in self.targets.append($0.uid) })
        system.onChange = { [unowned self] in self.session.defaultOutputChanged() }
    }

    func testStartPlaysTheDefaultOutputsCurveOnIt() throws {
        make()
        try session.start()
        XCTAssertEqual(journal.all, ["hidden false", "target BT-RCA", "push BT-RCA", "default \(DriverControl.deviceUID)"])
        XCTAssertEqual(session.target, FakeAudioSystem.speaker)
        XCTAssertEqual(targets, ["BT-RCA"])
        let sent = FakeDriver.decode(try XCTUnwrap(driver.written.last))
        XCTAssertEqual(DriverControl.record(sent.settings, targetUID: sent.uid, serial: sent.serial),
                       DriverControl.record(EQProcessor.settings(profile: curves["BT-RCA"]!, enabled: true), targetUID: "BT-RCA", serial: 101))
        XCTAssertEqual(session.health?.eqActive, true)
    }

    func testStartRefusesWithoutADriver() {
        make()
        driver.state["settingsVersion"] = nil
        XCTAssertThrowsError(try session.start())
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(journal.all, [])
    }

    func testSettingsChangesAndSoloArePushedForTheTarget() throws {
        make()
        try session.start()
        solo = SoloRange(low: 300, high: 3000)
        session.push()
        let sent = FakeDriver.decode(try XCTUnwrap(driver.written.last))
        XCTAssertEqual(sent.uid, "BT-RCA")
        XCTAssertTrue(sent.settings.solo)
        XCTAssertEqual(sent.settings.soloLow, 300)
        XCTAssertEqual(sent.settings.soloHigh, 3000)
        session.stop()
        session.push()
        XCTAssertEqual(driver.written.count, 2)
    }

    /// Decision 2: the user picks a real device; the EQ device plays on it and is default again.
    func testFollowsTheUsersPick() throws {
        make()
        try session.start()
        journal.clear()
        system.pick(FakeAudioSystem.headphones)
        clock.advance(1)
        XCTAssertEqual(journal.all, ["target USB-DAC", "push USB-DAC", "default \(DriverControl.deviceUID)"])
        XCTAssertEqual(session.target, FakeAudioSystem.headphones)
        XCTAssertEqual(targets, ["BT-RCA", "USB-DAC"])
        clock.advance(10)
        XCTAssertEqual(journal.all.count, 3)
    }

    /// `eq mode tap` saves the mode before it moves the default to a real device: that move is not a pick.
    func testDoesNotTakeTheDefaultBackOnceTheModeIsTap() throws {
        make()
        try session.start()
        journal.clear()
        driverMode = false
        system.pick(FakeAudioSystem.speaker)
        clock.advance(1)
        XCTAssertEqual(journal.all, [])
        XCTAssertEqual(system.current, "BT-RCA")
    }

    func testATargetThePluginPickedGetsItsCurve() throws {
        make()
        try session.start()
        driver.state["target"] = "BUILTIN"
        driver.state["targetName"] = "MacBook Pro Speakers"
        session.refresh()
        XCTAssertEqual(session.target?.uid, "BUILTIN")
        XCTAssertEqual(driver.pushedUIDs.last, "BUILTIN")
        XCTAssertEqual(targets.last, "BUILTIN")
        let pushes = driver.written.count
        session.refresh()
        XCTAssertEqual(driver.written.count, pushes)
    }

    func testARefusedCurveIsReportedAndPlayContinues() throws {
        make()
        driver.refuses = true
        try session.start()
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(session.error?.contains("not signed the way the driver requires") == true, session.error ?? "")
        driver.refuses = false
        session.push()
        XCTAssertNil(session.error)
    }

    func testTheMeterComesFromThePlugin() throws {
        make()
        let meter = DriverMeter(frequencies: Config.bandFrequencies, inputDB: Array(repeating: -20, count: 10),
                                outputDB: Array(repeating: -18, count: 10), peakDB: -6, limiting: false, compressorReductionDB: 0)
        driver.meterReply = meter
        XCTAssertNil(session.meter())
        try session.start()
        XCTAssertEqual(session.meter(), meter)
    }

    /// Decision 4, kept: macOS leaves the hidden EQ device as the default output.
    func testHiddenWhileDefaultKept() throws {
        make(hideWhileDefault: true)
        try session.start()
        XCTAssertEqual(journal.all.last, "hidden true")
        XCTAssertNil(session.hiddenDefault)
        clock.advance(DriverSession.hiddenCheckDelay)
        XCTAssertEqual(session.hiddenDefault, .kept)
        XCTAssertEqual(system.current, DriverControl.deviceUID)
    }

    /// Decision 4: a hidden device that macOS will not take as the default is shown again, not left out of the path.
    func testHiddenDeviceThatCannotBeDefaultIsShown() throws {
        make(hideWhileDefault: true)
        try session.start()
        clock.advance(DriverSession.hiddenCheckDelay)
        XCTAssertEqual(session.hiddenDefault, .kept)
        system.pick(FakeAudioSystem.headphones)
        journal.clear()
        system.refusesFirst = 10
        clock.advance(1)
        XCTAssertEqual(session.hiddenDefault, .dropped)
        XCTAssertEqual(journal.all, ["target USB-DAC", "push USB-DAC", "hidden false", "default \(DriverControl.deviceUID)"])
    }

    /// Decision 4, dropped: macOS moves the default off the hidden device. That move is not the
    /// user's pick, so eq neither retargets nor tries hiding again; it shows the device and takes the default back.
    func testHiddenWhileDefaultDropped() throws {
        make(hideWhileDefault: true)
        try session.start()
        system.pick(FakeAudioSystem.builtIn)
        clock.advance(DriverSession.hiddenCheckDelay)
        XCTAssertEqual(session.hiddenDefault, .dropped)
        XCTAssertEqual(session.target, FakeAudioSystem.speaker)
        XCTAssertEqual(Array(journal.all.suffix(2)), ["hidden false", "default \(DriverControl.deviceUID)"])
        journal.clear()
        system.pick(FakeAudioSystem.headphones)
        clock.advance(1)
        XCTAssertEqual(journal.all, ["target USB-DAC", "push USB-DAC", "default \(DriverControl.deviceUID)"])
    }
}
