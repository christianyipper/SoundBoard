import AppKit
import Combine

/// Installs local key-down and key-up monitors for the app's lifetime. On key-down it checks the
/// spacebar first (pauses any hotkey sound that's playing, otherwise plays/pauses the music
/// player), then the fixed "V" mic hotkey, then the fixed
/// gamesheet shot keys (set in Settings; A/Z home +/-, D/C away +/- by default), then the selected hotkey preset's slots (plain keys 1-9/0), then every sound's custom assigned shortcut,
/// toggling play/pause on a match. The mic hotkey's behavior depends on
/// `settings.microphoneHotkeyMode`: "toggle" flips it on key-down; "push to talk" turns it on
/// while V is held and off on key-up (handled by the key-up monitor). While `beginRecording` is
/// active, the next key-down is instead captured and handed back to the caller (used by the
/// "assign shortcut" UI), rather than triggering playback. Every key-down except the spacebar is
/// ignored while a text field is being edited, so typing into a rename/name dialog never
/// accidentally triggers a sound; the spacebar always plays/pauses and never types a space.
final class ShortcutManager: ObservableObject {
    static let spacebarKeyCode: UInt16 = 49
    static let microphoneKeyCode: UInt16 = 9
    static let escapeKeyCode: UInt16 = 53

    /// Why `keyCode` can't be a shot hotkey because a fixed hotkey already owns it, or nil if it's free.
    static func reservedUse(ofKeyCode keyCode: UInt16) -> String? {
        if keyCode == spacebarKeyCode { return "Space pauses hotkey sounds and plays/pauses the music player." }
        if keyCode == microphoneKeyCode { return "V is the microphone hotkey." }
        if keyCode == escapeKeyCode { return "Escape can't be used." }
        if let slot = HotkeyBarStore.keySlots.first(where: { $0.keyCode == keyCode }) {
            return "\(slot.displayKey) is a hotkey bar key."
        }
        return nil
    }

    private let playlistStore: PlaylistStore
    private let audioPlayerManager: AudioPlayerManager
    private let hotkeyBarStore: HotkeyBarStore
    private let microphoneManager: MicrophoneManager
    private let musicPlayerStore: MusicPlayerStore
    private let settingsStore: SettingsStore
    private let gameStore: GameStore
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var recordingCompletion: ((SoundShortcut) -> Void)?

    init(
        playlistStore: PlaylistStore,
        audioPlayerManager: AudioPlayerManager,
        hotkeyBarStore: HotkeyBarStore,
        microphoneManager: MicrophoneManager,
        musicPlayerStore: MusicPlayerStore,
        settingsStore: SettingsStore,
        gameStore: GameStore
    ) {
        self.playlistStore = playlistStore
        self.audioPlayerManager = audioPlayerManager
        self.hotkeyBarStore = hotkeyBarStore
        self.microphoneManager = microphoneManager
        self.musicPlayerStore = musicPlayerStore
        self.settingsStore = settingsStore
        self.gameStore = gameStore
    }

    func start() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
            return event
        }
    }

    func stop() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
        }
        keyDownMonitor = nil
        keyUpMonitor = nil
    }

    func beginRecording(completion: @escaping (SoundShortcut) -> Void) {
        recordingCompletion = completion
    }

    func cancelRecording() {
        recordingCompletion = nil
    }

    /// Returns the event to let it propagate normally, or nil to consume it.
    /// Internal (not private) so it can be exercised directly from unit tests without a real event monitor.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let shortcut = SoundShortcut(event: event) else { return event }

        if let recordingCompletion {
            self.recordingCompletion = nil
            recordingCompletion(shortcut)
            return nil
        }

        // Checked before the text-editing guard: Space is always the play/pause key, so it's
        // consumed even in a text field and never types a space.
        let hasNoModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        if hasNoModifiers, event.keyCode == Self.spacebarKeyCode {
            // Hotkey sounds take priority: pause them and leave the music player alone.
            let hotkeyIDs = hotkeyPlayingIDs
            if hotkeyIDs.isEmpty {
                musicPlayerStore.togglePlayPause()
            } else {
                hotkeyIDs.forEach { audioPlayerManager.pause($0) }
            }
            return nil
        }

        guard !isEditingText else { return event }

        if hasNoModifiers, event.keyCode == Self.microphoneKeyCode {
            handleMicrophoneKeyDown()
            return nil
        }
        if hasNoModifiers, let shotAction = settingsStore.settings.shotHotkeys.action(forKeyCode: event.keyCode) {
            gameStore.addShot(for: shotAction.side, delta: shotAction.delta)
            return nil
        }
        if hasNoModifiers, let slot = hotkeyBarStore.slot(forKeyCode: event.keyCode) {
            if let assignment = hotkeyBarStore.assignment(at: slot.index) {
                let sound = assignment.asSound
                audioPlayerManager.toggle(sound, fileURL: playlistStore.soundsDirectory.appendingPathComponent(assignment.fileName))
            }
            return nil
        }

        for playlist in playlistStore.playlists {
            if let sound = playlist.allSounds.first(where: { $0.shortcut == shortcut }) {
                audioPlayerManager.toggle(sound, fileURL: playlistStore.url(for: sound))
                return nil
            }
        }
        return event
    }

    /// Handles the mic hotkey's key-up half for push-to-talk mode. Internal (not private) so it
    /// can be exercised directly from unit tests without a real event monitor.
    func handleKeyUp(_ event: NSEvent) {
        guard !isEditingText, event.keyCode == Self.microphoneKeyCode else { return }
        if settingsStore.settings.microphoneHotkeyMode == .pushToTalk {
            microphoneManager.setLive(false)
        }
    }

    private func handleMicrophoneKeyDown() {
        switch settingsStore.settings.microphoneHotkeyMode {
        case .toggle:
            microphoneManager.toggle()
        case .pushToTalk:
            microphoneManager.setLive(true)
        }
    }

    /// Sounds playing other than the music player's current track, i.e. ones started by a hotkey,
    /// shortcut, or tile.
    private var hotkeyPlayingIDs: Set<UUID> {
        var ids = audioPlayerManager.playingIDs
        if musicPlayerStore.isPlaying, let musicID = musicPlayerStore.currentSoundID {
            ids.remove(musicID)
        }
        return ids
    }

    private var isEditingText: Bool {
        NSApplication.shared.keyWindow?.firstResponder is NSText
    }
}
