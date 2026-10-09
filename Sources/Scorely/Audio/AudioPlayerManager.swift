import AVFoundation
import Combine

/// Plays sounds via an AVAudioEngine graph (one AVAudioPlayerNode → AVAudioUnitReverb →
/// loudness-gain EQ chain per sound, feeding a shared mixer) and tracks per-sound play state for
/// the grid's color coding: idle (never played / reset), playing (green), played (paused or finished, red).
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

    /// When true, each sound is gain-matched to a common loudness (see LoudnessAnalyzer) before
    /// the master volume applies, so one volume setting suits every sound. Applied immediately.
    var normalizeLoudness: Bool = true {
        didSet {
            guard normalizeLoudness != oldValue else { return }
            for channel in channels.values {
                applyNormalizationGain(to: channel)
            }
        }
    }

    /// Holds the playback graph nodes and scheduling state for a single sound.
    private final class Channel {
        let playerNode = AVAudioPlayerNode()
        /// Carries the per-sound loudness-normalization gain. AVAudioPlayerNode.volume tops out at
        /// 1.0 (and is already used for master volume + fades), so boosting a quiet sound needs a
        /// separate gain stage — an EQ's globalGain (-96...+24 dB) with its band bypassed.
        /// It sits after the reverb, not before: reverb is linear so the result sounds the same,
        /// but an EQ feeding the reverb directly makes AVAudioPlayerNode.play() stall for ~5s on
        /// low-sample-rate files (e.g. 8 kHz), while reverb → EQ doesn't.
        let gainNode = AVAudioUnitEQ(numberOfBands: 1)
        let reverbNode = AVAudioUnitReverb()
        let file: AVAudioFile
        let fileURL: URL
        /// True when the file hasn't been scheduled yet, or finished playing and needs
        /// re-scheduling from the start before the next play() can produce audio.
        var needsScheduling = true
        var fadeWorkItem: DispatchWorkItem?
        /// Bumped every time a new segment is scheduled. AVAudioPlayerNode.stop() asynchronously
        /// fires the completion handler of whatever was scheduled before, even when cancelled
        /// early — tagging each schedule with a generation lets handleFinished(_:generation:)
        /// ignore that stale callback instead of clobbering a play() that already restarted it.
        var scheduleGeneration = 0

        init(file: AVAudioFile, fileURL: URL) {
            self.file = file
            self.fileURL = fileURL
            gainNode.bands[0].bypass = true
        }
    }

    private let engine: AVAudioEngine
    private var engineStarted = false
    private var channels: [UUID: Channel] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let loudnessCache: LoudnessCache
    /// Runs loudness analyses several at a time (decoding a long track takes a moment), leaving a
    /// core free for the UI and audio.
    private let analysisQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Scorely.LoudnessAnalysis"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)
        return queue
    }()
    /// Analyses queued or running, by file, with the callbacks waiting on each. Main thread only.
    private var pendingAnalyses: [URL: PendingAnalysis] = [:]
    /// Plays waiting on their file's loudness analysis before starting, by sound. Anything that
    /// stops a sound clears its entry, so a stale play doesn't start once the analysis lands.
    private var pendingStarts: [UUID: UUID] = [:]

    private struct PendingAnalysis {
        let operation: Operation
        var waiters: [() -> Void] = []
    }

    /// `engine` is injectable so tests can pass one in offline manual-rendering mode and inspect
    /// exactly what the graph produces.
    init(loudnessCache: LoudnessCache = LoudnessCache(), engine: AVAudioEngine = AVAudioEngine()) {
        self.loudnessCache = loudnessCache
        self.engine = engine
        super.init()
    }

    /// Keeps fadeOutDuration/volume/reverbAmount in sync with the persisted settings.
    func bind(to settingsStore: SettingsStore) {
        settingsStore.$settings
            .sink { [weak self] settings in
                self?.fadeOutDuration = settings.fadeOutDuration
                self?.volume = settings.volume
                self?.reverbAmount = settings.reverbAmount
                self?.crossFadeDuration = settings.crossFadeDuration
                self?.normalizeLoudness = settings.normalizeLoudness
            }
            .store(in: &cancellables)
    }

    /// Analyzes every sound's loudness in the background as playlists load or sounds are imported,
    /// so the (one-time, per-file) analysis is normally done long before a sound is first played
    /// and play() never has to wait on it.
    func bind(to playlistStore: PlaylistStore) {
        playlistStore.$playlists
            .sink { [weak self, weak playlistStore] playlists in
                guard let self, let playlistStore else { return }
                let urls = playlists.flatMap(\.allSounds).map(playlistStore.url(for:))
                self.analyzeLoudnessInBackground(urls)
            }
            .store(in: &cancellables)
    }

    private func analyzeLoudnessInBackground(_ urls: [URL]) {
        for url in urls where loudnessCache.measurement(for: url) == nil {
            enqueueAnalysis(of: url)
        }
    }

    /// Queues `url` for analysis unless it's already queued or running, and returns its operation.
    @discardableResult
    private func enqueueAnalysis(of url: URL) -> Operation {
        if let pending = pendingAnalyses[url] { return pending.operation }
        let operation = BlockOperation { [loudnessCache] in
            _ = loudnessCache.measurementAnalyzingIfNeeded(for: url)
        }
        operation.completionBlock = { [weak self] in
            DispatchQueue.main.async { self?.finishAnalysis(of: url) }
        }
        pendingAnalyses[url] = PendingAnalysis(operation: operation)
        analysisQueue.addOperation(operation)
        return operation
    }

    private func finishAnalysis(of url: URL) {
        guard let pending = pendingAnalyses.removeValue(forKey: url) else { return }
        // Skip if the file couldn't be analyzed, or applyNormalizationGain would just requeue it.
        for channel in channels.values where channel.fileURL == url && loudnessCache.measurement(for: url) != nil {
            applyNormalizationGain(to: channel)
        }
        pending.waiters.forEach { $0() }
    }

    /// Runs `completion` once `url`'s loudness is known, so a sound starts at its normalized level
    /// rather than audibly jumping to it partway in. Immediate when it's already cached (the usual
    /// case, since files are analyzed on import) or normalization is off; otherwise the analysis is
    /// moved to the front of the queue and `completion` runs on the main thread when it's done.
    private func whenLoudnessReady(for url: URL, _ completion: @escaping () -> Void) {
        guard normalizeLoudness, loudnessCache.measurement(for: url) == nil else {
            completion()
            return
        }
        enqueueAnalysis(of: url).queuePriority = .veryHigh
        pendingAnalyses[url]?.waiters.append(completion)
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
        pendingStarts.removeAll()
        playingIDs.removeAll()
        playedIDs.removeAll()
    }

    /// Starts `sound` from the beginning, or from `startTime` seconds in when given (e.g. the
    /// music player resuming from wherever the user scrubbed its timeline to while paused).
    ///
    /// The sound is marked playing right away, though its audio may start a moment later if its
    /// loudness hasn't been analyzed yet (see whenLoudnessReady(for:_:)).
    func play(_ sound: Sound, fileURL: URL, from startTime: TimeInterval = 0) {
        let token = UUID()
        pendingStarts[sound.id] = token
        playingIDs.insert(sound.id)
        playedIDs.remove(sound.id)
        whenLoudnessReady(for: fileURL) { [weak self] in
            guard let self, self.pendingStarts[sound.id] == token else { return }
            self.pendingStarts[sound.id] = nil
            if self.beginPlayback(sound, fileURL: fileURL, startVolume: self.volume, startTime: startTime) == nil {
                self.playingIDs.remove(sound.id)
            }
        }
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
        // The outgoing sound keeps playing until the incoming one is ready to start.
        let token = UUID()
        pendingStarts[sound.id] = token
        playingIDs.insert(sound.id)
        playedIDs.remove(sound.id)
        whenLoudnessReady(for: fileURL) { [weak self] in
            guard let self, self.pendingStarts[sound.id] == token else { return }
            self.pendingStarts[sound.id] = nil
            guard let channel = self.beginPlayback(sound, fileURL: fileURL, startVolume: 0) else {
                self.playingIDs.remove(sound.id)
                return
            }
            self.fadeIn(channel, to: self.volume, duration: self.crossFadeDuration)
            if self.playingIDs.contains(fromSoundID) {
                self.pause(fromSoundID, fadeDuration: self.crossFadeDuration)
            }
        }
    }

    /// Jumps a currently playing sound to `time` seconds in, without interrupting its playing
    /// state. Ignored if the sound isn't playing.
    func seek(_ soundID: UUID, to time: TimeInterval) {
        guard playingIDs.contains(soundID), pendingStarts[soundID] == nil,
              let channel = channels[soundID] else { return }
        // Drop any in-progress fade-in so the new position plays at full volume.
        channel.fadeWorkItem?.cancel()
        channel.fadeWorkItem = nil
        channel.playerNode.volume = volume
        // stop() fires the old segment's completion handler; the generation bump in
        // schedule(_:soundID:fromFrame:) makes handleFinished ignore it.
        channel.playerNode.stop()
        schedule(channel, soundID: soundID, fromFrame: frame(for: time, in: channel))
        channel.playerNode.play()
    }

    /// Stops playback and rewinds to the start, rather than pausing in place — so toggling the
    /// same sound off and back on again always restarts it from the beginning instead of
    /// resuming from wherever it was left off. Fades out over `fadeDuration` seconds (defaulting
    /// to `fadeOutDuration`) before stopping; 0 stops instantly.
    func pause(_ soundID: UUID, fadeDuration: Double? = nil) {
        pendingStarts[soundID] = nil
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
    private func beginPlayback(_ sound: Sound, fileURL: URL, startVolume: Float, startTime: TimeInterval = 0) -> Channel? {
        let channel: Channel
        if let existing = channels[sound.id] {
            channel = existing
        } else {
            guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
            let created = Channel(file: file, fileURL: fileURL)
            // AVAudioUnitReverb produces glitchy/unstable output until a factory preset is
            // loaded — without this, that noise hides under the dry signal at full volume but
            // is exposed as an audible artifact once the dry signal fades toward silence.
            created.reverbNode.loadFactoryPreset(.mediumRoom)
            created.reverbNode.wetDryMix = reverbAmount
            engine.attach(created.playerNode)
            engine.attach(created.gainNode)
            engine.attach(created.reverbNode)
            engine.connect(created.playerNode, to: created.reverbNode, format: file.processingFormat)
            // Everything after the player runs at the file's own sample rate, in stereo, and that
            // format must be passed explicitly. With `format: nil` the engine falls back to the
            // effect units' default 44.1 kHz output format, but effects don't resample — so a
            // 48 kHz file would be played back as if it were 44.1 kHz (~8% slow and flat in pitch),
            // a 96 kHz file at half speed. Stereo because the reverb can't output mono; the main
            // mixer then handles any conversion to the output device's rate and layout.
            let effectsFormat = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 2)
            engine.connect(created.reverbNode, to: created.gainNode, format: effectsFormat)
            engine.connect(created.gainNode, to: engine.mainMixerNode, format: effectsFormat)
            applyNormalizationGain(to: created)
            channels[sound.id] = created
            channel = created
        }

        channel.fadeWorkItem?.cancel()
        channel.fadeWorkItem = nil
        channel.playerNode.volume = startVolume
        startEngineIfNeeded()

        if startTime > 0 {
            // Starting mid-file: discard whatever was scheduled (if anything) and start over
            // from the requested position.
            if !channel.needsScheduling {
                channel.playerNode.stop()
            }
            schedule(channel, soundID: sound.id, fromFrame: frame(for: startTime, in: channel))
        } else if channel.needsScheduling {
            schedule(channel, soundID: sound.id, fromFrame: 0)
        }
        channel.playerNode.play()
        return channel
    }

    /// Queues the channel's file from `startFrame` to its end. Each call bumps the channel's
    /// generation so the completion handler of anything scheduled before is ignored.
    private func schedule(_ channel: Channel, soundID: UUID, fromFrame startFrame: AVAudioFramePosition) {
        channel.needsScheduling = false
        channel.scheduleGeneration += 1
        let generation = channel.scheduleGeneration
        let frameCount = AVAudioFrameCount(max(channel.file.length - startFrame, 0))
        // completionCallbackType defaults to .dataConsumed, which fires as soon as the
        // buffer is handed to the node's queue — almost immediately, well before the audio
        // has actually finished playing. .dataPlayedBack is what actually waits for playback.
        channel.playerNode.scheduleSegment(channel.file, startingFrame: startFrame, frameCount: frameCount, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleFinished(soundID, generation: generation)
            }
        }
    }

    /// The file frame at `time` seconds in, clamped to the file's bounds.
    private func frame(for time: TimeInterval, in channel: Channel) -> AVAudioFramePosition {
        let frame = AVAudioFramePosition(time * channel.file.processingFormat.sampleRate)
        return min(max(frame, 0), max(channel.file.length - 1, 0))
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

    /// Sets the channel's gain stage to its sound's loudness-normalization gain, or 0 dB when
    /// normalization is off. Never analyzes here — that would block the main thread for as long as
    /// it takes to decode the whole file. play() waits for the analysis before creating a channel,
    /// so this only lacks a measurement when normalization is switched on with channels already
    /// open; those are queued for analysis, and finishAnalysis(of:) applies the gain when done.
    private func applyNormalizationGain(to channel: Channel) {
        guard normalizeLoudness else {
            channel.gainNode.globalGain = 0
            return
        }
        guard let measurement = loudnessCache.measurement(for: channel.fileURL) else {
            channel.gainNode.globalGain = 0
            enqueueAnalysis(of: channel.fileURL)
            return
        }
        channel.gainNode.globalGain = Float(LoudnessAnalyzer.normalizationGain(for: measurement))
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
        pendingStarts[soundID] = nil
        if let channel = channels.removeValue(forKey: soundID) {
            channel.fadeWorkItem?.cancel()
            channel.playerNode.stop()
            engine.disconnectNodeInput(channel.playerNode)
            engine.disconnectNodeInput(channel.gainNode)
            engine.disconnectNodeInput(channel.reverbNode)
            engine.detach(channel.playerNode)
            engine.detach(channel.gainNode)
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
