import Foundation
import Combine

/// Drives the music player section below the hotkey bar: pick a playlist, shuffle its sounds into
/// a fixed play order, and toggle play/pause on that shuffled queue (via the spacebar or the
/// player's own button). Unlike a normal player, pausing doesn't just stop where it is — it also
/// cues up the next track, so the next play starts a fresh song rather than resuming this one. A
/// track that finishes on its own (without the user pausing) advances and keeps playing
/// automatically — crossfading into the next track if the "cross-fade between tracks" setting is
/// on, timed to start before the current track's audio actually ends so the two overlap. The
/// shuffle order is cached per playlist so switching away and back doesn't reshuffle; only the
/// explicit "reset" action does that.
final class MusicPlayerStore: ObservableObject {
    @Published var selectedPlaylistID: UUID? {
        didSet {
            guard selectedPlaylistID != oldValue else { return }
            selectPlaylist(selectedPlaylistID)
        }
    }
    @Published private(set) var currentSoundID: UUID?
    @Published private(set) var isPlaying = false
    /// Seconds elapsed since the current track started, for the timeline display. Reset to 0
    /// whenever a new track starts and frozen (not decremented) on pause, since pausing cues up
    /// a fresh track for next time rather than resuming this one.
    @Published private(set) var elapsedTime: TimeInterval = 0

    private let playlistStore: PlaylistStore
    private let audioPlayerManager: AudioPlayerManager
    /// Shuffled play order per playlist, cached so switching playlists and back doesn't reshuffle.
    private var shuffleOrders: [UUID: [UUID]] = [:]
    private var currentIndices: [UUID: Int] = [:]
    /// Fires shortly before the currently-playing track's audio actually ends, to kick off a
    /// crossfade into the next one. Only scheduled when the crossfade setting is on.
    private var crossFadeWorkItem: DispatchWorkItem?
    /// When the current track's audio actually started, for computing `elapsedTime`.
    private var trackStartDate: Date?
    private var cancellables = Set<AnyCancellable>()

    init(playlistStore: PlaylistStore, audioPlayerManager: AudioPlayerManager) {
        self.playlistStore = playlistStore
        self.audioPlayerManager = audioPlayerManager

        audioPlayerManager.$playingIDs
            .sink { [weak self] playingIDs in
                guard let self, self.isPlaying, let currentSoundID = self.currentSoundID else { return }
                guard !playingIDs.contains(currentSoundID) else { return }
                // Our track dropped out of `playingIDs` without togglePlayPause() pausing it
                // itself (that path flips `isPlaying` to false first) — i.e. it finished on its
                // own. Advance the queue and keep the music going.
                self.advanceAndPlay()
            }
            .store(in: &cancellables)

        Timer.publish(every: 0.25, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tickElapsedTime() }
            .store(in: &cancellables)
    }

    var currentSound: Sound? {
        currentSoundID.flatMap(playlistStore.sound(withID:))
    }

    /// Full duration, in seconds, of the current track's audio — available once it's started
    /// playing at least once this session.
    var currentDuration: TimeInterval? {
        currentSoundID.flatMap(audioPlayerManager.duration(for:))
    }

    /// Starts the cued track if idle, or stops the current one (fading per settings) and cues the
    /// next track in the shuffle order if playing. Bound to the spacebar and the player's button.
    func togglePlayPause() {
        guard let selectedPlaylistID else { return }
        cancelScheduledCrossFade()
        if isPlaying {
            isPlaying = false
            trackStartDate = nil
            elapsedTime = 0
            if let currentSoundID {
                audioPlayerManager.pause(currentSoundID)
            }
            advanceIndex(for: selectedPlaylistID)
            currentSoundID = soundID(atCurrentIndexOf: selectedPlaylistID)
        } else {
            play(playlistID: selectedPlaylistID)
        }
    }

    /// Jumps to the next track in the shuffle order, preserving the current play/pause state:
    /// plays it immediately if a track was already playing, or just cues it (silent, awaiting
    /// Play) if playback was paused.
    func skipToNext() {
        guard let selectedPlaylistID else { return }
        cancelScheduledCrossFade()
        let wasPlaying = isPlaying
        if isPlaying, let currentSoundID {
            audioPlayerManager.pause(currentSoundID)
        }
        advanceIndex(for: selectedPlaylistID)
        currentSoundID = soundID(atCurrentIndexOf: selectedPlaylistID)
        if wasPlaying {
            play(playlistID: selectedPlaylistID)
        } else {
            isPlaying = false
            trackStartDate = nil
            elapsedTime = 0
        }
    }

    /// Jumps to the previous track in the shuffle order, preserving the current play/pause state
    /// the same way skipToNext() does.
    func skipToPrevious() {
        guard let selectedPlaylistID else { return }
        cancelScheduledCrossFade()
        let wasPlaying = isPlaying
        if isPlaying, let currentSoundID {
            audioPlayerManager.pause(currentSoundID)
        }
        retreatIndex(for: selectedPlaylistID)
        currentSoundID = soundID(atCurrentIndexOf: selectedPlaylistID)
        if wasPlaying {
            play(playlistID: selectedPlaylistID)
        } else {
            isPlaying = false
            trackStartDate = nil
            elapsedTime = 0
        }
    }

    /// Re-shuffles the selected playlist's play order and cues its first track. Stops playback
    /// first if that playlist is currently playing.
    func resetShuffle() {
        guard let selectedPlaylistID else { return }
        cancelScheduledCrossFade()
        if isPlaying, let currentSoundID {
            audioPlayerManager.pause(currentSoundID)
            isPlaying = false
        }
        shuffleOrders[selectedPlaylistID] = nil
        currentIndices[selectedPlaylistID] = nil
        trackStartDate = nil
        elapsedTime = 0
        currentSoundID = cueFirstTrack(for: selectedPlaylistID)
    }

    // MARK: - Private

    private func selectPlaylist(_ playlistID: UUID?) {
        cancelScheduledCrossFade()
        if isPlaying, let currentSoundID {
            audioPlayerManager.pause(currentSoundID)
        }
        isPlaying = false
        trackStartDate = nil
        elapsedTime = 0
        currentSoundID = playlistID.flatMap { cueFirstTrack(for: $0) }
    }

    private func tickElapsedTime() {
        guard isPlaying, let trackStartDate else { return }
        elapsedTime = Date().timeIntervalSince(trackStartDate)
    }

    private func play(playlistID: UUID) {
        let candidateID = currentSoundID ?? cueFirstTrack(for: playlistID)
        guard let candidateID, let sound = playlistStore.sound(withID: candidateID) else { return }
        currentSoundID = candidateID
        isPlaying = true
        trackStartDate = Date()
        elapsedTime = 0
        audioPlayerManager.play(sound, fileURL: playlistStore.url(for: sound))
        scheduleCrossFadeIfNeeded(from: candidateID, playlistID: playlistID)
    }

    /// Advances the queue and plays the next track from scratch — the fallback used when there's
    /// no crossfade configured, so a track's natural completion (detected via the playingIDs sink
    /// above) is what drives moving on to the next one.
    private func advanceAndPlay() {
        guard let selectedPlaylistID else { return }
        advanceIndex(for: selectedPlaylistID)
        currentSoundID = soundID(atCurrentIndexOf: selectedPlaylistID)
        play(playlistID: selectedPlaylistID)
    }

    /// Schedules a crossfade into the next queued track, timed to fire just before `soundID`'s
    /// audio actually finishes, so the two overlap. No-ops when the crossfade setting is off (0)
    /// or the track's duration isn't known yet.
    private func scheduleCrossFadeIfNeeded(from soundID: UUID, playlistID: UUID) {
        let crossFadeDuration = audioPlayerManager.crossFadeDuration
        guard crossFadeDuration > 0, let duration = audioPlayerManager.duration(for: soundID) else { return }

        let delay = max(duration - crossFadeDuration, 0)
        let workItem = DispatchWorkItem { [weak self] in
            self?.crossFadeToNext(from: soundID, playlistID: playlistID)
        }
        crossFadeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Advances the queue and crossfades from `fromSoundID` into the newly-cued track, then
    /// schedules the next crossfade in turn. Bails out if playback state has since moved on
    /// (paused, reset, or switched playlists) rather than what this was scheduled for.
    private func crossFadeToNext(from fromSoundID: UUID, playlistID: UUID) {
        guard isPlaying, currentSoundID == fromSoundID, selectedPlaylistID == playlistID else { return }
        advanceIndex(for: playlistID)
        guard let nextSoundID = soundID(atCurrentIndexOf: playlistID),
              let sound = playlistStore.sound(withID: nextSoundID) else { return }
        currentSoundID = nextSoundID
        trackStartDate = Date()
        elapsedTime = 0
        audioPlayerManager.crossFade(from: fromSoundID, to: sound, fileURL: playlistStore.url(for: sound))
        scheduleCrossFadeIfNeeded(from: nextSoundID, playlistID: playlistID)
    }

    private func cancelScheduledCrossFade() {
        crossFadeWorkItem?.cancel()
        crossFadeWorkItem = nil
    }

    /// Ensures a shuffle order exists for `playlistID` (reusing the cached one if present),
    /// resets its index to the start, and returns the sound now cued at that position.
    private func cueFirstTrack(for playlistID: UUID) -> UUID? {
        let order = shuffleOrder(for: playlistID)
        currentIndices[playlistID] = 0
        return order.first
    }

    private func soundID(atCurrentIndexOf playlistID: UUID) -> UUID? {
        let order = shuffleOrder(for: playlistID)
        guard !order.isEmpty else { return nil }
        let index = currentIndices[playlistID] ?? 0
        return order[index]
    }

    /// Moves to the next position in the shuffle order, wrapping back to the start once every
    /// track has played — replaying the same shuffle order rather than generating a new one.
    private func advanceIndex(for playlistID: UUID) {
        let order = shuffleOrder(for: playlistID)
        guard !order.isEmpty else { return }
        let next = (currentIndices[playlistID] ?? 0) + 1
        currentIndices[playlistID] = next % order.count
    }

    /// Moves to the previous position in the shuffle order, wrapping to the end.
    private func retreatIndex(for playlistID: UUID) {
        let order = shuffleOrder(for: playlistID)
        guard !order.isEmpty else { return }
        let current = currentIndices[playlistID] ?? 0
        currentIndices[playlistID] = (current - 1 + order.count) % order.count
    }

    /// Returns the cached shuffle order for `playlistID`, dropping any sounds that were since
    /// removed from the playlist, or generating (and caching) a fresh shuffled order if none
    /// exists yet.
    private func shuffleOrder(for playlistID: UUID) -> [UUID] {
        let currentSoundIDs = playlistStore.playlists.first { $0.id == playlistID }?.allSounds.map(\.id) ?? []

        if let existing = shuffleOrders[playlistID] {
            let validIDs = Set(currentSoundIDs)
            let filtered = existing.filter { validIDs.contains($0) }
            if filtered.count != existing.count {
                shuffleOrders[playlistID] = filtered
                if let index = currentIndices[playlistID], index >= filtered.count {
                    currentIndices[playlistID] = 0
                }
            }
            return shuffleOrders[playlistID] ?? []
        }

        let shuffled = currentSoundIDs.shuffled()
        shuffleOrders[playlistID] = shuffled
        return shuffled
    }
}
