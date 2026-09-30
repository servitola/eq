import EQTerm
import XCTest
@testable import eq

/// The Meter's third octaves, its curve's moves, and the ten bands it falls back to without them.
final class SpectrumViewTests: XCTestCase {
    private func frame(gains: [Double] = Config.screenshotCurve, spectrum: [Double]? = TUILookTests.spectrum) -> MeterFrame {
        MeterFrame(t: 0, device: "BE-RCA", rate: 44100, in: Array(repeating: -30, count: 10), out: Array(repeating: -28, count: 10),
                   peak: -6, limiting: false, gains: gains, preamp: 0, enabled: true, spectrum: spectrum)
    }

    // MARK: Curve motion

    func testEaseOutStartsFastAndLandsExactly() {
        XCTAssertEqual(CurveMotion.ease(0), 0)
        XCTAssertEqual(CurveMotion.ease(1), 1)
        XCTAssertEqual(CurveMotion.ease(0.5), 0.875, accuracy: 1e-12)
        let steps = (0...CurveMotion.frames).map { CurveMotion.ease(Double($0) / Double(CurveMotion.frames)) }
        for (a, b) in zip(steps, steps.dropFirst()) { XCTAssertGreaterThan(b, a) }
        let moves = zip(steps, steps.dropFirst()).map { $1 - $0 }
        for (a, b) in zip(moves, moves.dropFirst()) { XCTAssertLessThan(b, a, "each step shorter than the one before") }
    }

    func testFirstGainsAreTakenAsTheyAre() {
        var motion = CurveMotion()
        motion.advance(toward: [3, -3])
        XCTAssertFalse(motion.moving)
        XCTAssertEqual(motion.gains, [3, -3])
    }

    func testNewGainsTakeNineFramesEasingOut() {
        var motion = CurveMotion()
        motion.advance(toward: [0, 0])
        var seen: [Double] = []
        for _ in 0..<12 {
            motion.advance(toward: [9, -9])
            seen.append(motion.gains[0])
            XCTAssertEqual(motion.gains[1], -motion.gains[0], accuracy: 1e-12)
        }
        XCTAssertEqual(seen[0], 9 * CurveMotion.ease(1.0 / 9), accuracy: 1e-12, "the frame that brings the gains already moves")
        XCTAssertEqual(seen[7], 9 * CurveMotion.ease(8.0 / 9), accuracy: 1e-12)
        XCTAssertEqual(Array(seen[8...]), [9, 9, 9, 9], "there after 9 frames, 300 ms at 30 a second")
        XCTAssertFalse(motion.moving)
    }

    func testANewTargetMidwayStartsFromTheCurveOnScreen() {
        var motion = CurveMotion()
        motion.advance(toward: [0])
        for _ in 0..<3 { motion.advance(toward: [6]) }
        let shown = motion.gains[0]
        motion.advance(toward: [-6])
        XCTAssertEqual(motion.gains[0], shown + (-6 - shown) * CurveMotion.ease(1.0 / 9), accuracy: 1e-12)
        for _ in 0..<8 { motion.advance(toward: [-6]) }
        XCTAssertEqual(motion.gains, [-6])
    }

    func testAnotherBandCountJumps() {
        var motion = CurveMotion()
        motion.advance(toward: [1, 2])
        motion.advance(toward: [1, 2, 3])
        XCTAssertFalse(motion.moving)
        XCTAssertEqual(motion.gains, [1, 2, 3])
    }

    func testThePresetSwitchIsDrawnMovingThenStill() {
        var model = MeterModel(size: Size(cols: 120, rows: 40))
        _ = model.update(.frame(frame(gains: Array(repeating: 0, count: 10))))
        XCTAssertEqual(model.scene()?.curveGains, Array(repeating: 0, count: 10))
        var drawn: [Double] = []
        var redraws: [Bool] = []
        for _ in 0..<11 {
            _ = model.update(.frame(frame(gains: Config.screenshotCurve)))
            drawn.append(model.scene()!.curveGains[0])
            redraws.append(model.needsRedraw)
        }
        XCTAssertEqual(model.scene()?.gains, Config.screenshotCurve, "the chips show where it goes at once")
        XCTAssertEqual(drawn[0], 4.8 * CurveMotion.ease(1.0 / 9), accuracy: 1e-9)
        XCTAssertEqual(drawn[8], 4.8, accuracy: 1e-12)
        XCTAssertEqual(redraws, [true, true, true, true, true, true, true, true, true, false, false],
                       "frames the same as the last are drawn while the curve moves, and not after")
    }

    // MARK: Spectrum in the model

    func testSpectrumRisesAtOnceAndFallsAt20DBASecond() {
        var model = MeterModel(size: Size(cols: 120, rows: 40))
        _ = model.update(.frame(frame(spectrum: Array(repeating: -20, count: 31))))
        XCTAssertEqual(model.scene()?.spectrum, Array(repeating: -20, count: 31))
        _ = model.update(.frame(frame(spectrum: Array(repeating: -60, count: 31))))
        XCTAssertEqual(model.scene()!.spectrum![0], -20 - 20.0 / 30, accuracy: 1e-9)
        for _ in 0..<29 { _ = model.update(.frame(frame(spectrum: Array(repeating: -60, count: 31)))) }
        XCTAssertEqual(model.scene()!.spectrum![0], -40, accuracy: 1e-9, "a second later, 20 dB down")
        XCTAssertEqual(model.scene()!.spectrumPeaks![0], -20, accuracy: 1e-9, "the tick still holds")
        _ = model.update(.frame(frame(spectrum: Array(repeating: -10, count: 31))))
        XCTAssertEqual(model.scene()?.spectrum, Array(repeating: -10, count: 31))
    }

    func testWithoutASpectrumTheMeterIsTheTenBands() {
        var model = MeterModel(size: Size(cols: 120, rows: 40))
        _ = model.update(.frame(frame()))
        XCTAssertNotNil(model.scene()?.spectrum)
        _ = model.update(.frame(frame(spectrum: nil)))
        XCTAssertNil(model.scene()?.spectrum, "a daemon or a driver from before the spectrum")
        XCTAssertNil(StudioView(scene: model.scene()!, compact: false).geometry.pitch)
        _ = model.update(.frame(frame(spectrum: Array(repeating: -20, count: 12))))
        XCTAssertNil(model.scene()?.spectrum, "a spectrum of another size is not one this eq can draw")
    }

    // MARK: Geometry

    func testEveryThirdBarSitsUnderABand() {
        for (cols, pitch) in [(140, 3), (120, 2), (80, 2)] {
            let g = StudioView(scene: TUILookTests.scene(cols: cols, rows: 40), compact: false).geometry
            XCTAssertEqual(g.pitch, pitch, "\(cols) columns")
            XCTAssertEqual(g.plotWidth, 31 * pitch)
            for band in 0..<10 { XCTAssertEqual(g.barX(band), g.plotX0 + (3 * band + 2) * pitch, "\(cols) columns, band \(band)") }
            XCTAssertEqual(g.axis, g.plotX0 + g.plotWidth, "the gain scale right after the last bar")
        }
        XCTAssertNil(StudioView(scene: TUILookTests.scene(cols: 72, rows: 40), compact: false).geometry.pitch, "too narrow for 62 columns")
    }

    // MARK: Drawn

    /// The panel's rows inside its border.
    private func panel(_ scene: MeterScene) -> [String] {
        let g = StudioView(scene: scene, compact: false).geometry
        let box = g.box!
        return scene.lines()[g.top..<(g.top + g.rows)].map { String(Array($0)[(box.x + 1)..<(box.right - 1)]) }
    }

    func testANodeOnEachBandAndTheEditedOneLabelled() {
        var scene = TUILookTests.scene(cols: 120, rows: 40)
        XCTAssertEqual(panel(scene).joined().filter { $0 == "●" }.count, 10)
        scene.flash = (5, 20)
        let rows = panel(scene)
        XCTAssertEqual(rows.joined().filter { $0 == "●" }.count, 9)
        let ring = try! XCTUnwrap(rows.firstIndex { $0.contains("◉") })
        XCTAssertTrue(rows[ring - 1].contains(" -3.1 "), rows[ring - 1])
    }

    func testTheScalesSayWhatTheyMeasure() {
        let top = TUILookTests.scene(cols: 120, rows: 40).lines()[2]
        XCTAssertTrue(top.contains("╭ level dBFS ─"), top)
        XCTAssertTrue(top.contains("─ EQ dB ╮"), top)
        XCTAssertTrue(top.contains("─ meter ─"), top)
    }

    func testGridLinesAtTwelveDBSteps() {
        var scene = TUILookTests.scene(cols: 120, rows: 40, spectrum: false)
        scene.settings.curve = false
        let rows = panel(scene)
        let dotted = rows.indices.filter { rows[$0].contains("┈┈┈") }
        let labelled = [" 0 ┤", "-12 ┤", "-24 ┤", "-36 ┤", "-48 ┤"].map { label in rows.firstIndex { $0.contains(label) }! }
        XCTAssertEqual(dotted, labelled)
    }
}
