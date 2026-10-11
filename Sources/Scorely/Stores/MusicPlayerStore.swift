import AVFoundation
import Combine

/// Drives the music player section below the hotkey bar: pick a folder and toggle play/pause on
/// its sounds (via the spacebar or the player's own button), either in folder order or — with
/// shuffle on — in a shuffled order. Unlike a normal player, pausing doesn't just stop where it is — it also
/// cues up the next track, so the next play starts a fresh song rather than resuming this one. A
/// track that finishes on its own behaves the same way: the next track is cued but not started,
/// so nothing plays until the user hits Play again. Each folder's play order and position are
/// kept, so switching away and back picks up on the same track with the same history; only the
/// refresh button (restartFromFirstTrack()) starts a folder over. That history is saved to disk
/// too, so restarting the app mid-game doesn't replay songs already played.
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
    /// Each folder's position in its play order, kept across folder switches so returning to a
    /// folder resumes on the same track.
    private var currentIndices: [UUID: Int] = [:]
    /// When the current track's audio actually started, for computing `elapsedTime`.
    private var trackStartDate: Date?
    /// File durations by sound, so the timeline can be scrubbed before a track's first play.
    private var fileDurations: [UUID: TimeInterval] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Where the play history is saved; nil keeps it in memory only.
    private let fileURL: URL?
    private var saveWorkItem: DispatchWorkItem?

    private struct PersistedState: Codable {
        var selectedFolderID: UUID?
        var isShuffled: Bool
        var shuffleOrders: [UUID: [UUID]]
        var currentIndices: [UUID: Int]
        /// Whether the cued track had started playing, so it counts as played on relaunch.
        var wasPlaying: Bool
    }

    init(playlistStore: PlaylistStore, audioPlayerManager: AudioPlayerManager, baseDirectory: URL? = nil) {
        self.playlistStore = playlistStore
        self.audioPlayerManager = audioPlayerManager
        fileURL = baseDirectory?.appendingPathComponent("musicplayer.json")
        restoreSavedState()

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
        scheduleSave()
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
        scheduleSave()
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
        scheduleSave()
    }

    /// Turns shuffle on or off without interrupting the current track. Turning it on shuffles
    /// the folder with the current track first, so playback carries on from it into a random
    /// order; turning it off continues from the current track in folder order. Every other
    /// visited folder is reordered the same way around its own current track, so it still
    /// resumes there when switched back to.
    func toggleShuffle() {
        // Each visited folder's current track under the old ordering, to carry into the new one.
        let currentTracks = Dictionary(uniqueKeysWithValues: currentIndices.keys.compactMap { folderID in
            soundID(atCurrentIndexOf: folderID).map { (folderID, $0) }
        })
        isShuffled.toggle()
        shuffleOrders.removeAll()
        currentIndices.removeAll()

        for (folderID, trackID) in currentTracks {
            let folderOrder = folderSoundIDs(for: folderID)
            guard folderOrder.contains(trackID) else { continue }
            if isShuffled {
                shuffleOrders[folderID] = [trackID] + folderOrder.filter { $0 != trackID }.shuffled()
                currentIndices[folderID] = 0
            } else {
                currentIndices[folderID] = folderOrder.firstIndex(of: trackID)
            }
        }
        guard let selectedFolderID else { return }
        currentIndices[selectedFolderID] = currentIndices[selectedFolderID] ?? 0
        currentSoundID = soundID(atCurrentIndexOf: selectedFolderID)
        scheduleSave()
    }

    /// Jumps back to the folder's first sound and starts its play order over: its cached shuffle
    /// order is discarded (with shuffle on, a fresh one is generated starting from that first
    /// sound) and its position is reset. Other folders keep their history. Preserves play/pause
    /// state the same way skipToNext() does.
    func restartFromFirstTrack() {
        guard let selectedFolderID else { return }
        let wasPlaying = isPlaying
        if isPlaying, let currentSoundID {
            audioPlayerManager.pause(currentSoundID)
        }
        shuffleOrders[selectedFolderID] = nil

        let folderOrder = folderSoundIDs(for: selectedFolderID)
        if isShuffled, let firstID = folderOrder.first {
            shuffleOrders[selectedFolderID] = [firstID] + folderOrder.dropFirst().shuffled()
        }
        currentIndices[selectedFolderID] = 0
        currentSoundID = soundID(atCurrentIndexOf: selectedFolderID)
        if wasPlaying {
            play(folderID: selectedFolderID)
        } else {
            isPlaying = false
            trackStartDate = nil
            elapsedTime = 0
        }
        scheduleSave()
    }

    /// Forgets every folder's play history (the toolbar's Reset). A playing track carries on and
    /// a fresh order follows it; otherwise the selected folder is cued from the start of a fresh
    /// order.
    func resetHistory() {
        shuffleOrders.removeAll()
        currentIndices.removeAll()
        if let selectedFolderID {
            let folderOrder = folderSoundIDs(for: selectedFolderID)
            if isPlaying, let currentSoundID, folderOrder.contains(currentSoundID) {
                if isShuffled {
                    shuffleOrders[selectedFolderID] = [currentSoundID] + folderOrder.filter { $0 != currentSoundID }.shuffled()
                    currentIndices[selectedFolderID] = 0
                } else {
                    currentIndices[selectedFolderID] = folderOrder.firstIndex(of: currentSoundID)
                }
            } else {
                elapsedTime = 0
                currentSoundID = cueFirstTrack(for: selectedFolderID)
            }
        }
        scheduleSave()
    }

    func flush() {
        saveWorkItem?.cancel()
        writeToDisk()
    }

    // MARK: - Persistence

    /// Picks up the saved folder, shuffle setting and each folder's play order and position. A
    /// track that was playing when the app quit counts as played, so the next one is cued.
    private func restoreSavedState() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        isShuffled = state.isShuffled
        shuffleOrders = state.shuffleOrders
        currentIndices = state.currentIndices
        guard let folderID = state.selectedFolderID, playlistStore.folder(withID: folderID) != nil else { return }
        // Set directly: didSet doesn't run during init, and selectFolder() would re-cue anyway.
        selectedFolderID = folderID
        if state.wasPlaying, currentIndices[folderID] != nil {
            advanceIndex(for: folderID)
        }
        currentSoundID = currentIndices[folderID] == nil ? cueFirstTrack(for: folderID) : soundID(atCurrentIndexOf: folderID)
    }

    private func scheduleSave() {
        guard fileURL != nil else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.writeToDisk()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func writeToDisk() {
        guard let fileURL else { return }
        let state = PersistedState(
            selectedFolderID: selectedFolderID,
            isShuffled: isShuffled,
            shuffleOrders: shuffleOrders,
            currentIndices: currentIndices,
            wasPlaying: isPlaying
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Private

    /// Stops the current track and cues the newly selected folder where it was left off (the
    /// same track it was on), or its first track if it hasn't been visited yet.
    private func selectFolder(_ folderID: UUID?) {
        let wasPlaying = isPlaying
        // Cleared before pausing so the playingIDs sink doesn't read the pause as the track
        // finishing and advance the new folder's position.
        isPlaying = false
        trackStartDate = nil
        elapsedTime = 0
        if wasPlaying, let currentSoundID {
            audioPlayerManager.pause(currentSoundID)
        }
        currentSoundID = folderID.flatMap { folderID in
            currentIndices[folderID] == nil ? cueFirstTrack(for: folderID) : soundID(atCurrentIndexOf: folderID)
        }
        scheduleSave()
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
        scheduleSave()
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
