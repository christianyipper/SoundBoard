import AVFoundation

/// Measures an audio file's perceived loudness per ITU-R BS.1770 (integrated LUFS — the same
/// measure streaming services normalize to) plus its sample peak, so sounds imported at wildly
/// different levels can be gain-matched before the master volume is applied.
///
/// Plain RMS would get close, but BS.1770's K-weighting (a high-shelf boost + low-cut) tracks how
/// loud things actually *sound*: a bass-heavy clip and a trebly clip with equal RMS aren't
/// perceived as equally loud. Its gating also keeps leading/trailing silence from dragging a
/// short clip's measured loudness down and over-boosting it.
enum LoudnessAnalyzer {
    struct Measurement: Codable, Equatable {
        /// Integrated loudness in LUFS. nil when the file is (effectively) silent.
        var integratedLoudness: Double?
        /// Highest absolute sample value in dBFS (0 = full scale). nil when the file is silent.
        var samplePeak: Double?
    }

    /// Loudness every sound is normalized to. Most commercial music sits around -14 to -9 LUFS
    /// and sound effects vary widely; -16 leaves headroom so typical material is mostly turned
    /// *down* (which is lossless) rather than boosted into clipping.
    static let targetLoudness: Double = -16
    /// Boosting is capped so near-silent ambience or a quiet recording isn't amplified into a
    /// wall of noise floor.
    static let maxBoost: Double = 12
    /// Normalization never pushes a sound's peaks above this, so boosting can't introduce clipping.
    static let peakCeiling: Double = -1

    /// The gain, in dB, that brings `measurement` to `targetLoudness` without exceeding
    /// `peakCeiling` or `maxBoost`. Silent/unmeasurable files get 0 dB (left as-is).
    static func normalizationGain(for measurement: Measurement) -> Double {
        guard let loudness = measurement.integratedLoudness else { return 0 }
        var gain = targetLoudness - loudness
        if let peak = measurement.samplePeak {
            gain = min(gain, peakCeiling - peak)
        }
        return min(gain, maxBoost)
    }

    /// Decodes the whole file and measures it. Reads in chunks so long music tracks don't need
    /// to be held in memory at once. Returns nil if the file can't be opened/decoded.
    static func measure(fileURL: URL) -> Measurement? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard sampleRate > 0, channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { return nil }

        // Each channel gets its own two-stage K-weighting filter state.
        var filters = (0..<channelCount).map { _ in KWeightingFilter(sampleRate: sampleRate) }

        // BS.1770 gates over 400 ms blocks overlapping by 75%, i.e. a new block every 100 ms —
        // so accumulate filtered energy per 100 ms segment, and build each block from 4 of them.
        let segmentFrames = max(Int(sampleRate * 0.1), 1)
        var segmentEnergies: [Double] = []
        var currentSegmentEnergy = 0.0
        var currentSegmentFrames = 0
        var peak: Float = 0

        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                return nil
            }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let channelData = buffer.floatChannelData else { break }

            for frame in 0..<frameCount {
                var energy = 0.0
                for channel in 0..<channelCount {
                    let sample = channelData[channel][frame]
                    peak = max(peak, abs(sample))
                    let weighted = filters[channel].process(Double(sample))
                    energy += weighted * weighted
                }
                currentSegmentEnergy += energy
                currentSegmentFrames += 1
                if currentSegmentFrames == segmentFrames {
                    segmentEnergies.append(currentSegmentEnergy)
                    currentSegmentEnergy = 0
                    currentSegmentFrames = 0
                }
            }
        }

        let samplePeak: Double? = peak > 0 ? 20 * log10(Double(peak)) : nil

        // Mean-square energy (summed across channels) of each 400 ms gating block.
        var blockEnergies: [Double] = []
        if segmentEnergies.count >= 4 {
            let blockFrames = Double(segmentFrames * 4)
            for start in 0...(segmentEnergies.count - 4) {
                blockEnergies.append(segmentEnergies[start..<(start + 4)].reduce(0, +) / blockFrames)
            }
        } else {
            // Clips shorter than one 400 ms block (common for sound effects) aren't measurable
            // under strict BS.1770, so treat the whole clip as a single block instead.
            let totalFrames = segmentEnergies.count * segmentFrames + currentSegmentFrames
            if totalFrames > 0 {
                blockEnergies.append((segmentEnergies.reduce(0, +) + currentSegmentEnergy) / Double(totalFrames))
            }
        }

        return Measurement(integratedLoudness: gatedLoudness(of: blockEnergies), samplePeak: samplePeak)
    }

    /// BS.1770 two-pass gating: drop blocks below an absolute -70 LUFS (silence), then drop blocks
    /// more than 10 LU below the loudness of what's left (pauses, quiet tails), and report the
    /// loudness of the remaining blocks.
    private static func gatedLoudness(of blockEnergies: [Double]) -> Double? {
        func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }

        let aboveAbsolute = blockEnergies.filter { $0 > 0 && loudness($0) > -70 }
        guard !aboveAbsolute.isEmpty else { return nil }

        let relativeGate = loudness(aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)) - 10
        let gated = aboveAbsolute.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }

        return loudness(gated.reduce(0, +) / Double(gated.count))
    }
}

/// BS.1770's K-weighting: a ~+4 dB high shelf around 1.5 kHz (head acoustics) followed by a
/// ~38 Hz high-pass (RLB curve). Coefficients are derived for the file's actual sample rate rather
/// than using the spec's 48 kHz table, so 44.1 kHz and other rates are weighted correctly too.
private struct KWeightingFilter {
    private var shelf: Biquad
    private var highPass: Biquad

    init(sampleRate: Double) {
        shelf = .highShelf(sampleRate: sampleRate, frequency: 1500, gainDB: 4, q: 1 / 2.squareRoot())
        highPass = .highPass(sampleRate: sampleRate, frequency: 38, q: 0.5)
    }

    mutating func process(_ sample: Double) -> Double {
        highPass.process(shelf.process(sample))
    }
}

/// Direct-form-I biquad with RBJ cookbook coefficients, normalized so a0 == 1.
private struct Biquad {
    let b0, b1, b2, a1, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    static func highShelf(sampleRate: Double, frequency: Double, gainDB: Double, q: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let sqrtAAlpha = 2 * a.squareRoot() * alpha
        return Biquad(
            b0: a * ((a + 1) + (a - 1) * cosW0 + sqrtAAlpha),
            b1: -2 * a * ((a - 1) + (a + 1) * cosW0),
            b2: a * ((a + 1) + (a - 1) * cosW0 - sqrtAAlpha),
            a0: (a + 1) - (a - 1) * cosW0 + sqrtAAlpha,
            a1: 2 * ((a - 1) - (a + 1) * cosW0),
            a2: (a + 1) - (a - 1) * cosW0 - sqrtAAlpha
        )
    }

    static func highPass(sampleRate: Double, frequency: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * q)
        return Biquad(
            b0: (1 + cosW0) / 2,
            b1: -(1 + cosW0),
            b2: (1 + cosW0) / 2,
            a0: 1 + alpha,
            a1: -2 * cosW0,
            a2: 1 - alpha
        )
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}
