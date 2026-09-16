import AVFoundation
import Combine

/// Plays sounds via an AVAudioEngine graph (one AVAudioPlayerNode + AVAudioUnitReverb per sound,
/// feeding a shared mixer) and tracks per-sound play state for the grid's color coding:
/// idle (never played / reset), playing (green), played (paused or finished, red).
///
/// AVAudioEngine (rather than plain AVAudioPlayer) is what makes the reverb setting possible:
/// AVAudioPlayer has no effects pipeline, so getting adjustable reverb requires routing playback
/// through an AVAudioUnitReverb node instead.
final class AudioPlayerManager: NSObject, ObservableObject {
    @Published private(set) var playingIDs: Set<UUID> = []
    @Published private(set) var playedIDs: Set<UUID> = []

    /// Seconds to fade to silence before pausing. 0 pauses instantly. Applied on the next pause.
    var fadeOutDuration: Double = 0
    /// Seconds to crossfade between two sounds in crossFade(from:to:fileURL:). 0 switches instantly.
    var crossFadeDuration: Double = 0
    /// Master playback volume, 0...1. Applied immediately to all sounds, including mid-playback.
    var volume: Float = 1.0 {
        didSet {
            for channel in channels.values where channel.fadeWorkItem == nil {
                channel.playerNode.volume = volume
            }
        }
    }
    /// Reverb wet/dry mix, 0...100. Applied immediately to all sounds, including mid-playback.
    var reverbAmount: Float = 0 {
        didSet {
            for channel in channels.values {
                channel.reverbNode.wetDryMix = reverbAmount
            }
        }
    }

    /// Holds the playback graph nodes and scheduling state for a single sound.
    private final class Channel {
        let playerNode = AVAudioPlayerNode()
        let reverbNode = AVAudioUnitReverb()
        let file: AVAudioFile
        /// True when the file hasn't been scheduled yet, or finished playing and needs
        /// re-scheduling from the start before the next play() can produce audio.
        var needsScheduling = true
        var fadeWorkItem: DispatchWorkItem?
        /// Bumped every time a new segment is scheduled. AVAudioPlayerNode.stop() asynchronously
        /// fires the completion handler of whatever was scheduled before, even when cancelled
        /// early — tagging each schedule with a generation lets handleFinished(_:generation:)
        /// ignore that stale callback instead of clobbering a play() that already restarted it.
        var scheduleGeneration = 0

        init(file: AVAudioFile) {
            self.file = file
        }
    }

    private let engine = AVAudioEngine()
    private var engineStarted = false
    private var channels: [UUID: Channel] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Keeps fadeOutDuration/volume/reverbAmount in sync with the persisted settings.
    func bind(to settingsStore: SettingsStore) {
        settingsStore.$settings
            .sink { [weak self] settings in
                self?.fadeOutDuration = settings.fadeOutDuration
                self?.volume = settings.volume
                self?.reverbAmount = settings.reverbAmount
                self?.crossFadeDuration = settings.crossFadeDuration
            }
            .store(in: &cancellables)
    }

    /// The full duration, in seconds, of `soundID`'s audio file — available once it's been played
    /// at least once (i.e. its channel/file has already been opened). Lets a caller like the music
    /// player time a crossfade to land right before a track's audio actually ends.
    func duration(for soundID: UUID) -> TimeInterval? {
        guard let channel = channels[soundID] else { return nil }
        return Double(channel.file.length) / channel.file.processingFormat.sampleRate
    }

    func state(for soundID: UUID) -> PlayState {
        if playingIDs.contains(soundID) { return .playing }
        if playedIDs.contains(soundID) { return .played }
        return .idle
    }

    func toggle(_ sound: Sound, fileURL: URL) {
        if playingIDs.contains(sound.id) {
            pause(sound.id)
        } else {
            play(sound, fileURL: fileURL)
        }
    }

    /// Pauses every currently playing sound, e.g. for a global "Pause" control.
    func pauseAll() {
        for soundID in Array(playingIDs) {
            pause(soundID)
        }
    }

    /// Immediately halts and rewinds every currently playing sound, and clears played state,
    /// so every tile is back to idle and the next play starts from the beginning.
    func stopAll() {
        for soundID in Array(playingIDs) {
            guard let channel = channels[soundID] else { continue }
            channel.fadeWorkItem?.cancel()
            channel.fadeWorkItem = nil
            channel.playerNode.stop()
            channel.needsScheduling = true
        }
        playingIDs.removeAll()
        playedIDs.removeAll()
    }

    func play(_ sound: Sound, fileURL: URL) {
        guard beginPlayback(sound, fileURL: fileURL, startVolume: volume) != nil else { return }
        playingIDs.insert(sound.id)
        playedIDs.remove(sound.id)
    }

    /// Crosses over from `fromSoundID` to `sound`: fades the outgoing sound down to silence while
    /// simultaneously fading `sound` up from silence, both over `crossFadeDuration` seconds, so
    /// playback overlaps instead of leaving a gap — used for the music player's automatic
    /// track-to-track transitions. Falls back to an instant pause + play when there's no crossfade
    /// configured, no outgoing sound, or the outgoing sound isn't currently playing.
    func crossFade(from fromSoundID: UUID?, to sound: Sound, fileURL: URL) {
        guard crossFadeDuration > 0, let fromSoundID, fromSoundID != sound.id, playingIDs.contains(fromSoundID) else {
            if let fromSoundID {
                pause(fromSoundID)
            }
            play(sound, fileURL: fileURL)
            return
        }

        // Start (and mark playing) the incoming sound before pausing the outgoing one: both are
        // @Published mutations, so publishing the outgoing sound's removal first would briefly
        // publish `playingIDs` containing neither sound, which could misread as both having
        // stopped to an observer (e.g. the music player's own "did it finish?" check).
        guard let channel = beginPlayback(sound, fileURL: fileURL, startVolume: 0) else { return }
        playingIDs.insert(sound.id)
        playedIDs.remove(sound.id)
        fadeIn(channel, to: volume, duration: crossFadeDuration)

        pause(fromSoundID, fadeDuration: crossFadeDuration)
    }

    /// Stops playback and rewinds to the start, rather than pausing in place — so toggling the
    /// same sound off and back on again always restarts it from the beginning instead of
    /// resuming from wherever it was left off. Fades out over `fadeDuration` seconds (defaulting
    /// to `fadeOutDuration`) before stopping; 0 stops instantly.
    func pause(_ soundID: UUID, fadeDuration: Double? = nil) {
        playingIDs.remove(soundID)
        playedIDs.insert(soundID)

        guard let channel = channels[soundID] else { return }
        channel.fadeWorkItem?.cancel()

        let duration = fadeDuration ?? fadeOutDuration
        guard duration > 0 else {
            stopAndRewind(channel)
            return
        }
        fadeOutAndStop(channel, duration: duration)
    }

    /// Starts (or restarts, if already scheduled) `sound` playing at `startVolume` rather than
    /// unconditionally at the master volume, so play() (starts at master volume) and crossFade()
    /// (starts at 0, then fades in) can share the same channel setup/scheduling logic. Returns
    /// nil if the file can't be opened.
    @discardableResult
    private func beginPlayback(_ sound: Sound, fileURL: URL, startVolume: Float) -> Channel? {
        let channel: Channel
        if let existing = channels[sound.id] {
            channel = existing
        } else {
            guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
            let created = Channel(file: file)
            // AVAudioUnitReverb produces glitchy/unstable output until a factory preset is
            // loaded — without this, that noise hides under the dry signal at full volume but
            // is exposed as an audible artifact once the dry signal fades toward silence.
            created.reverbNode.loadFactoryPreset(.mediumRoom)
            created.reverbNode.wetDryMix = reverbAmount
            engine.attach(created.playerNode)
            engine.attach(created.reverbNode)
            engine.connect(created.playerNode, to: created.reverbNode, format: file.processingFormat)
            // Passing nil here lets the engine use the reverb unit's actual (possibly
            // upmixed/resampled) output format instead of assuming it matches the input file,
            // which avoids format-mismatch failures for unusual source sample rates/channel counts.
            engine.connect(created.reverbNode, to: engine.mainMixerNode, format: nil)
            channels[sound.id] = created
            channel = created
        }

        channel.fadeWorkItem?.cancel()
        channel.fadeWorkItem = nil
        channel.playerNode.volume = startVolume
        startEngineIfNeeded()

        if channel.needsScheduling {
            channel.needsScheduling = false
            channel.file.framePosition = 0
            channel.scheduleGeneration += 1
            let generation = channel.scheduleGeneration
            // completionCallbackType defaults to .dataConsumed, which fires as soon as the
            // buffer is handed to the node's queue — almost immediately, well before the audio
            // has actually finished playing. .dataPlayedBack is what actually waits for playback.
            channel.playerNode.scheduleFile(channel.file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.handleFinished(sound.id, generation: generation)
                }
            }
        }
        channel.playerNode.play()
        return channel
    }

    /// Ramps the channel's volume down to zero over `duration` using an equal-power curve (a
    /// linear gain ramp sounds like it "cuts" near the end rather than tapering smoothly), then
    /// holds true silence briefly before stopping and rewinding, and restores volume to the
    /// current master level so the next play() starts at full volume again.
    ///
    /// The settle hold matters with reverb on: AVAudioPlayerNode.stop() truncates whatever's
    /// still mid-render, and truncating a live (non-silent) signal produces a discontinuity that
    /// the reverb tail rings out as an audible click/hiccup. Stopping only once the node has
    /// already been rendering genuine silence for a few cycles avoids that.
    private func fadeOutAndStop(_ channel: Channel, duration: Double) {
        let stepInterval = 0.01
        let steps = max(Int(duration / stepInterval), 1)
        let startVolume = channel.playerNode.volume
        let settleDelay = 0.05

        func step(_ index: Int) {
            guard index <= steps else {
                channel.playerNode.volume = 0
                let settleItem = DispatchWorkItem {
                    self.stopAndRewind(channel)
                    channel.playerNode.volume = self.volume
                    channel.fadeWorkItem = nil
                }
                channel.fadeWorkItem = settleItem
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: settleItem)
                return
            }
            let progress = Float(index) / Float(steps)
            channel.playerNode.volume = startVolume * cos(progress * .pi / 2)

            let workItem = DispatchWorkItem { step(index + 1) }
            channel.fadeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + stepInterval, execute: workItem)
        }
        step(1)
    }

    /// Ramps a freshly-started channel's volume up from silence to `targetVolume` over `duration`,
    /// the mirror image of fadeOutAndStop's curve, so a simultaneous fade-out/fade-in pair (see
    /// crossFade(from:to:fileURL:)) sounds like a smooth handoff rather than a dip in loudness.
    private func fadeIn(_ channel: Channel, to targetVolume: Float, duration: Double) {
        let stepInterval = 0.01
        let steps = max(Int(duration / stepInterval), 1)

        func step(_ index: Int) {
            guard index <= steps else {
                channel.playerNode.volume = targetVolume
                channel.fadeWorkItem = nil
                return
            }
            let progress = Float(index) / Float(steps)
            channel.playerNode.volume = targetVolume * sin(progress * .pi / 2)

            let workItem = DispatchWorkItem { step(index + 1) }
            channel.fadeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + stepInterval, execute: workItem)
        }
        step(1)
    }

    /// Stops the node and marks it as needing rescheduling, so the next play() starts from frame 0.
    private func stopAndRewind(_ channel: Channel) {
        channel.playerNode.stop()
        channel.needsScheduling = true
    }

    private func handleFinished(_ soundID: UUID, generation: Int) {
        guard let channel = channels[soundID], channel.scheduleGeneration == generation else { return }
        channel.needsScheduling = true
        playingIDs.remove(soundID)
        playedIDs.insert(soundID)
    }

    func resetPlayedStates() {
        playedIDs.removeAll()
    }

    /// Drops cached players so removed/renamed sounds don't hold stale file handles.
    func invalidatePlayer(for soundID: UUID) {
        if let channel = channels.removeValue(forKey: soundID) {
            channel.fadeWorkItem?.cancel()
            channel.playerNode.stop()
            engine.disconnectNodeInput(channel.playerNode)
            engine.disconnectNodeInput(channel.reverbNode)
            engine.detach(channel.playerNode)
            engine.detach(channel.reverbNode)
        }
        playingIDs.remove(soundID)
        playedIDs.remove(soundID)
    }

    private func startEngineIfNeeded() {
        guard !engineStarted else { return }
        engine.prepare()
        // If this fails (e.g. no audio output device available), sounds simply won't be
        // audible; state tracking above still behaves normally rather than crashing.
        engineStarted = (try? engine.start()) != nil
    }
}
