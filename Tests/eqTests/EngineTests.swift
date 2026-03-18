import XCTest
import CoreAudio
@testable import eq

final class EngineTests: XCTestCase {
    private func asbd(rate: Double = 48000, channels: UInt32 = 2) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    func testTapSelectionPicksTheOnlyStereoFloatStream() {
        let selection = TapInputSelection.select(
            tapFormat: asbd(), aggregateInputFormats: [asbd(channels: 1), asbd()], aggregateInputChannels: [1, 2])
        XCTAssertEqual(selection, TapInputSelection(bufferIndex: 1, channels: 2))
    }

    func testTapSelectionUsesChannelBoundaryWhenAmbiguous() {
        let selection = TapInputSelection.select(
            tapFormat: asbd(), aggregateInputFormats: [asbd(), asbd()], aggregateInputChannels: [2, 2],
            aggregateInputStartingChannels: [1, 3], physicalInputChannelCount: 2)
        XCTAssertEqual(selection, TapInputSelection(bufferIndex: 1, channels: 2))
    }

    func testPeakFilterAtZeroGainIsUnity() {
        let c = BiquadCoefficients.make(type: .peak, frequency: 1000, gainDB: 0, q: 1.41, sampleRate: 48000)
        XCTAssertEqual(c.magnitudeDB(at: 1000, sampleRate: 48000), 0, accuracy: 1e-4)
        XCTAssertEqual(c.magnitudeDB(at: 100, sampleRate: 48000), 0, accuracy: 1e-4)
    }

    func testPeakFilterGainIsSymmetricAtCentre() {
        let boost = BiquadCoefficients.make(type: .peak, frequency: 1000, gainDB: 6, q: 1.41, sampleRate: 48000)
        let cut = BiquadCoefficients.make(type: .peak, frequency: 1000, gainDB: -6, q: 1.41, sampleRate: 48000)
        XCTAssertEqual(boost.magnitudeDB(at: 1000, sampleRate: 48000), 6, accuracy: 0.01)
        XCTAssertEqual(cut.magnitudeDB(at: 1000, sampleRate: 48000), -6, accuracy: 0.01)
    }

    func testFlatProfilePassesAudioThroughUnchanged() {
        let processor = EQProcessor()
        processor.configure(sampleRate: 48000)
        processor.apply(profile: .flat, enabled: true)
        let frames = 256
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        for i in 0..<frames {
            left[i] = 0.25 * sin(Float(i) * 0.1)
            right[i] = left[i]
        }
        let expected = Array(UnsafeBufferPointer(start: left, count: frames))
        processor.process(channels: [left, right], frameCount: frames)
        for i in 0..<frames {
            XCTAssertEqual(left[i], expected[i], accuracy: 1e-5)
            XCTAssertEqual(right[i], expected[i], accuracy: 1e-5)
        }
    }

    func testDisabledProfileBypasses() {
        let processor = EQProcessor()
        processor.configure(sampleRate: 48000)
        processor.apply(profile: Profile(name: nil, preamp: -12, bands: Array(repeating: -12, count: 10)), enabled: false)
        let frames = 64
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { buffer.deallocate() }
        for i in 0..<frames { buffer[i] = 0.5 }
        processor.process(channels: [buffer], frameCount: frames)
        XCTAssertEqual(buffer[10], 0.5, accuracy: 1e-6)
    }

    func testTransportNames() {
        XCTAssertEqual(AudioOutputDevice(id: 1, uid: "u", name: "n", transportType: kAudioDeviceTransportTypeBluetooth).transportName, "bluetooth")
        XCTAssertEqual(AudioOutputDevice(id: 1, uid: "u", name: "n", transportType: kAudioDeviceTransportTypeBuiltIn).transportName, "builtin")
        XCTAssertEqual(AudioOutputDevice(id: 1, uid: "u", name: "n", transportType: 0).transportName, "other")
    }
}
