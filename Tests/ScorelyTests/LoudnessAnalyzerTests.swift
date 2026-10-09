import AVFoundation
import XCTest
@testable import Scorely

final class LoudnessAnalyzerTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func sineURL(amplitude: Float, seconds: Double = 2, sampleRate: Double = 48_000) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = amplitude * sin(2 * .pi * 997 * Float(i) / Float(sampleRate))
        }
        let file = try! AVAudioFile(forWriting: url, settings: format.settings)
        try! file.write(from: buffer)
        urls.append(url)
        return url
    }

    /// BS.1770 calibration: a ~1 kHz sine at 0 dBFS in one channel reads -3.01 LUFS, so -20 dBFS
    /// (amplitude 0.1) should read about -23 LUFS.
    func testMeasuresReferenceSineAtExpectedLoudness() throws {
        let measurement = try XCTUnwrap(LoudnessAnalyzer.measure(fileURL: sineURL(amplitude: 0.1)))
        XCTAssertEqual(try XCTUnwrap(measurement.integratedLoudness), -23.01, accuracy: 0.3)
        XCTAssertEqual(try XCTUnwrap(measurement.samplePeak), -20, accuracy: 0.1)
    }

    func testMeasuresCorrectlyAt44100Hz() throws {
        let measurement = try XCTUnwrap(LoudnessAnalyzer.measure(fileURL: sineURL(amplitude: 0.1, sampleRate: 44_100)))
        XCTAssertEqual(try XCTUnwrap(measurement.integratedLoudness), -23.01, accuracy: 0.3)
    }

    func testClipsShorterThanOneGatingBlockAreStillMeasured() throws {
        let measurement = try XCTUnwrap(LoudnessAnalyzer.measure(fileURL: sineURL(amplitude: 0.1, seconds: 0.2)))
        XCTAssertEqual(try XCTUnwrap(measurement.integratedLoudness), -23.01, accuracy: 0.5)
    }

    func testSilentFileGetsNoGain() throws {
        let url = TestAudioFixture.makeSilentWAVURL(seconds: 1)
        urls.append(url)
        let measurement = try XCTUnwrap(LoudnessAnalyzer.measure(fileURL: url))
        XCTAssertNil(measurement.integratedLoudness)
        XCTAssertEqual(LoudnessAnalyzer.normalizationGain(for: measurement), 0)
    }

    func testLoudAndQuietSoundsNormalizeToSameLevel() throws {
        let loud = try XCTUnwrap(LoudnessAnalyzer.measure(fileURL: sineURL(amplitude: 0.5)))
        let quiet = try XCTUnwrap(LoudnessAnalyzer.measure(fileURL: sineURL(amplitude: 0.1)))
        let loudResult = try XCTUnwrap(loud.integratedLoudness) + LoudnessAnalyzer.normalizationGain(for: loud)
        let quietResult = try XCTUnwrap(quiet.integratedLoudness) + LoudnessAnalyzer.normalizationGain(for: quiet)
        XCTAssertEqual(loudResult, LoudnessAnalyzer.targetLoudness, accuracy: 0.01)
        XCTAssertEqual(quietResult, LoudnessAnalyzer.targetLoudness, accuracy: 0.01)
    }

    func testBoostIsLimitedByPeakCeiling() {
        // Quiet overall but with a near-full-scale peak: boosting to target would clip.
        let measurement = LoudnessAnalyzer.Measurement(integratedLoudness: -30, samplePeak: -3)
        XCTAssertEqual(LoudnessAnalyzer.normalizationGain(for: measurement), 2, accuracy: 0.001)
    }

    func testBoostIsCapped() {
        let measurement = LoudnessAnalyzer.Measurement(integratedLoudness: -50, samplePeak: -40)
        XCTAssertEqual(LoudnessAnalyzer.normalizationGain(for: measurement), LoudnessAnalyzer.maxBoost)
    }

    func testCachePersistsMeasurements() throws {
        let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        urls.append(cacheURL)
        let audioURL = sineURL(amplitude: 0.1)
        let cache = LoudnessCache(fileURL: cacheURL)
        let measured = try XCTUnwrap(cache.measurementAnalyzingIfNeeded(for: audioURL))

        let saved = expectation(description: "saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved.fulfill() }
        wait(for: [saved], timeout: 3)

        XCTAssertEqual(LoudnessCache(fileURL: cacheURL).measurement(for: audioURL), measured)
    }
}
