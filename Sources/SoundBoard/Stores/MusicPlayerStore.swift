import AVFoundation
import Combine

/// Drives the music player section below the hotkey bar: pick a folder and toggle play/pause on
/// its sounds (via the spacebar or the player's own button), either in folder order or — with
/// shuffle on — in a shuffled order. Unlike a normal player, pausing doesn't just stop where it is — it also
/// cues up the next track, so the next play starts a fresh song rather than resuming this one. A
/// track that finishes on its own behaves the same way: the next track is cued but not started,
/// so nothing plays until the user hits Play again. The play order is cached per folder so
/// switching away and back doesn't reshuffle; toggling shuffle off and on again does.
final class MusicPlayerStore: ObservableObject {
    /// The folder (`SoundTab`) whose sounds are shuffled and played.
    @Published var selectedFolderID: UUID? {
        didSet {
            guard selectedFolderID != oldValue else { return }
            selectFolder(selectedFolderID)
        }
    }
    @Published private(set) var currentSoundID: UUID?
    @Published private(set) var isPlaying = false
    /// Whether tracks play in a shuffled order rather than folder order. Toggled with
    /// toggleShuffle(), which keeps the current track and reorders what comes after it.
    @Published private(set) var isShuffled = false
    /// Playhead position in the current track, for the timeline display. Reset to 0 whenever a
    /// new track is cued. While paused it can be moved with seek(to:), and the next play starts
    /// from there.
    @Published private(set) var elapsedTime: TimeInterval = 0

    private let playlistStore: PlaylistStore
    private let audioPlayerManager: AudioPlayerManager
    /// Shuffled play order per folder, cached so switching folders and back doesn't reshuffle.
    /// Only used while `isShuffled`; otherwise the folder's own order is played.
    private var shuffleOrders: [UUID: [UUID]] = [:]
    private var currentIndices: [UUID: Int] = [:]
    /// When the current track's audio actually started, for computing `elapsedTime`.
    private var trackStartDate: Date?
    /// File durations by sound, so the timeline can be scrubbed before a track's first play.
    private var fileDurations: [UUID: TimeInterval] = [:]
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
                // own. Cue the next track and stay paused, same as a manual skip while paused.
                self.advanceAndCue()
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

    /// Full duration, in seconds, of the current track's audio.
    var currentDuration: TimeInterval? {
        guard let currentSoundID else { return nil }
        if let duration = audioPlayerManager.duration(for: currentSoundID) ?? fileDurations[currentSoundID] {
            return duration
        }
        guard let sound = playlistStore.sound(withID: currentSoundID),
              let file = try? AVAudioFile(forReading: playlistStore.url(for: sound)) else { return nil }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        fileDurations[currentSoundID] = duration
        return duration
    }

    /// Moves the playhead to `time` seconds into the current track. Jumps the audio there if
    /// playing; if paused, the next play starts from there instead of the beginning.
    func seek(to time: TimeInterval) {
        guard let currentSoundID, let duration = currentDuration else { return }
        let clamped = min(max(time, 0), duration)
        elapsedTime = clamped
        guard isPlaying else { return }
        trackStartDate = Date().addingTimeInterval(-clamped)
        audioPlayerManager.seek(currentSoundID, to: clamped)
    }

    /// Starts the cued track if idle, or stops the current one (fading per settings) and cues the
    /// next track in the play order if playing. Bound to the spacebar and the player's button.
    func togglePlayPause() {
        guard let selectedFolderID else { return }
        if isPlaying {
            isPlaying = false
            trackStartDate = nil
            elapsedTime = 0
            if let currentSoundID {
                audioPlayerManager.pause(currentSoundID)
            }
            advanceIndex(for: selectedFolderID)
            currentSoundID = soundID(atCurrentIndexOf: selectedFolderID)
        } else {
            // Every path that stops playback resets elapsedTime, so anything nonzero here is a
            // position the user scrubbed to while paused.
            play(folderID: selectedFolderID, from: elapsedTime)
        }
    }

    /// Jumps to the next track in the play order, preserving the current play/pause state:
    /// plays it immediately if a track was already playing, or just cues it (silent, awaiting
    /// Play) if playback was paused.
    func skipToNext() {
        guard let selectedFolderID else { return }
        let wasPlaying = isPlaying
        if isPlaying, let currentSoundID {
            audioPlayerManager.pause(currentSoundID)
        }
        advanceIndex(for: selectedFolderID)
        currentSoundID = soundID(atCurrentIndexOf: selectedFolderID)
        if wasPlaying {
            play(folderID: selectedFolderID)
        } else {
            isPlaying = false
            trackStartDate = nil
            elapsedTime = 0
        }
    }

    /// Jumps to the previous track in the play order, preserving the current play/pause state
    /// the same way skipToNext() does.
    func skipToPrevious() {
        guard let selectedFolderID else { return }
        let wasPlaying = isPlaying
        if isPlaying, let currentSoundID {
            audioPlayerManager.pause(currentSoundID)
        }
        retreatIndex(for: selectedFolderID)
        currentSoundID = soundID(atCurrentIndexOf: selectedFolderID)
        if wasPlaying {
            play(folderID: selectedFolderID)
        } else {
            isPlaying = false
            trackStartDate = nil
            elapsedTime = 0
        }
    }

    /// Turns shuffle on or off without interrupting the current track. Turning it on shuffles
    /// the folder with the current track first, so playback carries on from it into a random
    /// order; turning it off continues from the current track in folder order.
    func toggleShuffle() {
        isShuffled.toggle()
        // Other folders' positions belong to the old ordering; they're re-cued from the start
        // when next selected anyway.
        shuffleOrders.removeAll()
        currentIndices.removeAll()
        guard let selectedFolderID else { return }

        let folderOrder = folderSoundIDs(for: selectedFolderID)
        if isShuffled {
            if let currentSoundID, folderOrder.contains(currentSoundID) {
                shuffleOrders[selectedFolderID] = [currentSoundID] + folderOrder.filter { $0 != currentSoundID }.shuffled()
            }
            currentIndices[selectedFolderID] = 0
        } else {
            currentIndices[selectedFolderID] = currentSoundID.flatMap(folderOrder.firstIndex(of:)) ?? 0
        }
        currentSoundID = soundID(atCurrentIndexOf: selectedFolderID)
    }

    // MARK: - Private

    private func selectFolder(_ folderID: UUID?) {
        if isPlaying, let currentSoundID {
            audioPlayerManager.pause(currentSoundID)
        }
        isPlaying = false
        trackStartDate = nil
        elapsedTime = 0
        currentSoundID = folderID.flatMap { cueFirstTrack(for: $0) }
    }

    private func tickElapsedTime() {
        guard isPlaying, let trackStartDate else { return }
        elapsedTime = Date().timeIntervalSince(trackStartDate)
    }

    private func play(folderID: UUID, from startTime: TimeInterval = 0) {
        let candidateID = currentSoundID ?? cueFirstTrack(for: folderID)
        guard let candidateID, let sound = playlistStore.sound(withID: candidateID) else { return }
        currentSoundID = candidateID
        isPlaying = true
        trackStartDate = Date().addingTimeInterval(-startTime)
        elapsedTime = startTime
        audioPlayerManager.play(sound, fileURL: playlistStore.url(for: sound), from: startTime)
    }

    /// Advances the queue and cues the next track without starting it — used when a track
    /// finishes on its own (detected via the playingIDs sink above).
    private func advanceAndCue() {
        guard let selectedFolderID else { return }
        isPlaying = false
        trackStartDate = nil
        elapsedTime = 0
        advanceIndex(for: selectedFolderID)
        currentSoundID = soundID(atCurrentIndexOf: selectedFolderID)
    }

    /// Ensures a play order exists for `folderID` (reusing the cached one if present),
    /// resets its index to the start, and returns the sound now cued at that position.
    private func cueFirstTrack(for folderID: UUID) -> UUID? {
        let order = shuffleOrder(for: folderID)
        currentIndices[folderID] = 0
        return order.first
    }

    private func soundID(atCurrentIndexOf folderID: UUID) -> UUID? {
        let order = shuffleOrder(for: folderID)
        guard !order.isEmpty else { return nil }
        let index = min(currentIndices[folderID] ?? 0, order.count - 1)
        return order[index]
    }

    /// Moves to the next position in the play order, wrapping back to the start once every
    /// track has played — replaying the same play order rather than generating a new one.
    private func advanceIndex(for folderID: UUID) {
        let order = shuffleOrder(for: folderID)
        guard !order.isEmpty else { return }
        let next = (currentIndices[folderID] ?? 0) + 1
        currentIndices[folderID] = next % order.count
    }

    /// Moves to the previous position in the play order, wrapping to the end.
    private func retreatIndex(for folderID: UUID) {
        let order = shuffleOrder(for: folderID)
        guard !order.isEmpty else { return }
        let current = currentIndices[folderID] ?? 0
        currentIndices[folderID] = (current - 1 + order.count) % order.count
    }

    private func folderSoundIDs(for folderID: UUID) -> [UUID] {
        playlistStore.folder(withID: folderID)?.sounds.map(\.id) ?? []
    }

    /// The play order for `folderID`: the folder's own order when shuffle is off, otherwise its
    /// cached shuffle order (dropping any sounds since removed), generating and caching a fresh
    /// one if none exists yet.
    private func shuffleOrder(for folderID: UUID) -> [UUID] {
        let currentSoundIDs = folderSoundIDs(for: folderID)
        guard isShuffled else { return currentSoundIDs }

        if let existing = shuffleOrders[folderID] {
            let validIDs = Set(currentSoundIDs)
            let filtered = existing.filter { validIDs.contains($0) }
            if filtered.count != existing.count {
                shuffleOrders[folderID] = filtered
                if let index = currentIndices[folderID], index >= filtered.count {
                    currentIndices[folderID] = 0
                }
            }
            return shuffleOrders[folderID] ?? []
        }

        let shuffled = currentSoundIDs.shuffled()
        shuffleOrders[folderID] = shuffled
        return shuffled
    }
}
