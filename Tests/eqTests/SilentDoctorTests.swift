import XCTest
@testable import eq

final class SilentDoctorTests: XCTestCase {
    private func status(_ silent: [Status.Silent]?, mode: AudioMode = .tap, driverVersion: Int? = nil) -> Status {
        var status = Status(state: .running, device: nil, sampleRate: 48000, profile: .device, framesProcessed: 0, callbacks: 0, writes: 1,
                            enabled: true, error: nil, pid: getpid(), version: "x", updatedAt: Date(), mode: mode, silent: silent)
        if let driverVersion {
            status.driver = Status.DriverStatus(deviceName: "S · EQ", target: nil, isDefault: true, ioRunning: true, eqActive: true,
                                                underruns: 0, overruns: 0, clockPpm: 0, latencyMs: nil, hidden: false, settingsVersion: driverVersion)
        }
        return status
    }

    private var config: Config {
        var config = Config.initial(builtInUID: "BUILTIN", builtInName: "Mac Studio Speakers")
        config.setSilent("BUILTIN", true)
        return config
    }

    func testSaysHowEachSilentOutputIsKeptSilent() {
        let held = Status.Silent(uid: "BUILTIN", name: "Mac Studio Speakers", connected: true, muted: true, playing: true)
        let check = Doctor.silentCheck(config, status([held, Status.Silent(uid: "USB", name: "DAC", connected: false, muted: nil, playing: false)]))
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.detail, "Mac Studio Speakers: mute held, plays zeros; DAC: not connected")

        let bare = Doctor.silentCheck(config, status([Status.Silent(uid: "HDMI", name: "LG", connected: true, muted: nil, playing: false)]))
        XCTAssertEqual(bare.detail, "LG: no mute eq can set, zeros only")
        XCTAssertTrue(bare.ok)

        let loose = Doctor.silentCheck(config, status([Status.Silent(uid: "BUILTIN", name: "S", connected: true, muted: false, playing: false)]))
        XCTAssertTrue(loose.warning)
        XCTAssertTrue(loose.detail.contains("its mute will not stay set"))
    }

    func testAnOldDriverAnOldDaemonAndNoDaemonAreWarnings() {
        let held = Status.Silent(uid: "BUILTIN", name: "S", connected: true, muted: true, playing: true)
        let old = Doctor.silentCheck(config, status([held], mode: .driver, driverVersion: 1))
        XCTAssertTrue(old.warning)
        XCTAssertTrue(old.detail.contains("-120 dB, not zeros — eq mode driver updates it"), old.detail)
        XCTAssertTrue(Doctor.silentCheck(config, status([held], mode: .driver, driverVersion: 2)).ok)
        XCTAssertTrue(Doctor.silentCheck(config, status(nil)).detail.contains("predates silent outputs"))
        XCTAssertTrue(Doctor.silentCheck(config, nil).detail.contains("daemon not running"))
    }

    func testStatusLine() {
        Paint.forced = false
        defer { Paint.forced = nil }
        XCTAssertNil(CLI.silentLine([]))
        XCTAssertEqual(CLI.silentLine([Status.Silent(uid: "B", name: "Speakers", connected: true, muted: true, playing: false),
                                       Status.Silent(uid: "U", name: "DAC", connected: false, muted: nil, playing: false)]),
                       "Speakers muted, DAC not connected")
    }
}
