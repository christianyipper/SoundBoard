import AVFoundation
@testable import Scorely

/// Shared fixture generator: a minimal valid PCM WAV so AVAudioPlayer can actually load it in tests.
enum TestAudioFixture {
    static func makeSilentWAVData(seconds: Double = 0.2) -> Data {
        let sampleRate: UInt32 = 8000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let numSamples = UInt32(seconds * Double(sampleRate))
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = numSamples * UInt32(blockAlign)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndian: UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: numChannels)
        data.append(littleEndian: sampleRate)
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.append(littleEndian: dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }

    static func makeSilentWAVURL(seconds: Double = 0.2) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try! makeSilentWAVData(seconds: seconds).write(to: url)
        return url
    }
}

extension Data {
    mutating func append(littleEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension AudioPlayerManager {
    /// A manager whose loudness cache already has `urls` analyzed, as they would be after import,
    /// so play() starts them synchronously instead of waiting on a background analysis.
    static func withAnalyzedFiles(_ urls: [URL], engine: AVAudioEngine = AVAudioEngine()) -> AudioPlayerManager {
        let cache = LoudnessCache()
        for url in urls {
            _ = cache.measurementAnalyzingIfNeeded(for: url)
        }
        return AudioPlayerManager(loudnessCache: cache, engine: engine)
    }
}
