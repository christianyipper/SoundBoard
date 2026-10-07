import AVFoundation
import XCTest
@testable import SoundBoard

/// Renders sounds through AudioPlayerManager's real graph offline and checks the output keeps the
/// source's pitch/speed — reverb and loudness matching must only ever change level, never rate.
final class PlaybackFidelityTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    private func toneURL(frequency: Float, amplitude: Float, sampleRate: Double, channels: AVAudioChannelCount) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = amplitude * sin(2 * .pi * frequency * Float(i) / Float(sampleRate))
            }
        }
        try! AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        urls.append(url)
        return url
    }

    /// Plays `url` through a fresh manager rendering offline at `outputRate`, and returns the
    /// output's measured frequency (from zero crossings) and peak level over a steady window.
    private func render(_ url: URL, outputRate: Double, normalize: Bool = true) throws -> (frequency: Double, peak: Float) {
        let engine = AVAudioEngine()
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
        let manager = AudioPlayerManager(engine: engine)
        manager.normalizeLoudness = normalize
        manager.play(Sound(name: "Tone", fileName: url.lastPathComponent), fileURL: url)

        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var samples: [Float] = []
        while samples.count < Int(outputRate / 2) {
            _ = try engine.renderOffline(4096, to: buffer)
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }

        let start = Int(outputRate * 0.1)
        let window = Int(outputRate * 0.25)
        var crossings = 0
        var peak: Float = 0
        for i in (start + 1)..<(start + window) {
            if samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
            peak = max(peak, abs(samples[i]))
        }
        return (Double(crossings) / 0.25, peak)
    }

    func testPlaybackKeepsPitchAcrossSampleRatesAndChannelCounts() throws {
        let cases: [(fileRate: Double, channels: AVAudioChannelCount, outputRate: Double)] = [
            (48_000, 2, 44_100), (48_000, 2, 48_000), (44_100, 2, 48_000), (96_000, 2, 48_000),
            (48_000, 1, 48_000), (22_050, 1, 48_000), (8_000, 1, 44_100),
        ]
        for testCase in cases {
            let url = toneURL(frequency: 1000, amplitude: 0.5, sampleRate: testCase.fileRate, channels: testCase.channels)
            let frequency = try render(url, outputRate: testCase.outputRate).frequency
            XCTAssertEqual(frequency, 1000, accuracy: 8, "\(testCase)")
        }
    }

    func testLoudnessMatchingOnlyChangesLevel() throws {
        let url = toneURL(frequency: 1000, amplitude: 0.9, sampleRate: 48_000, channels: 2)
        let normalized = try render(url, outputRate: 48_000, normalize: true)
        let untouched = try render(url, outputRate: 48_000, normalize: false)

        XCTAssertEqual(normalized.frequency, untouched.frequency, accuracy: 8)
        XCTAssertLessThan(normalized.peak, untouched.peak * 0.7, "a loud file should be turned down")
    }
}
