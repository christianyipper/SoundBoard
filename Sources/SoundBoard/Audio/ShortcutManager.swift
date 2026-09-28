import AppKit
import Combine

/// Installs local key-down and key-up monitors for the app's lifetime. On key-down it checks the
/// spacebar (music player play/pause) first, then the fixed "V" mic hotkey, then left/right arrow
/// (switches the selected hotkey preset tab, only when more than one preset exists), then the
/// selected hotkey preset's slots (plain keys 1-9/0), then every sound's custom assigned shortcut,
/// toggling play/pause on a match. The mic hotkey's behavior depends on
/// `settings.microphoneHotkeyMode`: "toggle" flips it on key-down; "push to talk" turns it on
/// while V is held and off on key-up (handled by the key-up monitor). While `beginRecording` is
/// active, the next key-down is instead captured and handed back to the caller (used by the
/// "assign shortcut" UI), rather than triggering playback. Key-downs are ignored while a text
/// field is being edited, so typing into a rename/name dialog never accidentally triggers a sound.
final class ShortcutManager: ObservableObject {
    private static let spacebarKeyCode: UInt16 = 49
    private static let microphoneKeyCode: UInt16 = 9
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124

    private let playlistStore: PlaylistStore
    private let audioPlayerManager: AudioPlayerManager
    private let hotkeyBarStore: HotkeyBarStore
    private let microphoneManager: MicrophoneManager
    private let musicPlayerStore: MusicPlayerStore
    private let settingsStore: SettingsStore
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?
    private var recordingCompletion: ((SoundShortcut) -> Void)?

    init(
        playlistStore: PlaylistStore,
        audioPlayerManager: AudioPlayerManager,
        hotkeyBarStore: HotkeyBarStore,
        microphoneManager: MicrophoneManager,
        musicPlayerStore: MusicPlayerStore,
        settingsStore: SettingsStore
    ) {
        self.playlistStore = playlistStore
        self.audioPlayerManager = audioPlayerManager
        self.hotkeyBarStore = hotkeyBarStore
        self.microphoneManager = microphoneManager
        self.musicPlayerStore = musicPlayerStore
        self.settingsStore = settingsStore
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

        guard !isEditingText else { return event }

        let hasNoModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        if hasNoModifiers, event.keyCode == Self.spacebarKeyCode {
            musicPlayerStore.togglePlayPause()
            return nil
        }
        if hasNoModifiers, event.keyCode == Self.microphoneKeyCode {
            handleMicrophoneKeyDown()
            return nil
        }
        // Arrow keys always carry the .numericPad (and often .function) modifier flag from macOS
        // itself, even with no keys held down, so they'd never satisfy `hasNoModifiers`. Only the
        // "real" modifier keys should block tab switching here.
        let navigationModifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if navigationModifiers.isEmpty, hotkeyBarStore.presets.count > 1, event.keyCode == Self.leftArrowKeyCode {
            hotkeyBarStore.selectAdjacentPreset(offset: -1)
            return nil
        }
        if navigationModifiers.isEmpty, hotkeyBarStore.presets.count > 1, event.keyCode == Self.rightArrowKeyCode {
            hotkeyBarStore.selectAdjacentPreset(offset: 1)
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

    private var isEditingText: Bool {
        NSApplication.shared.keyWindow?.firstResponder is NSText
    }
}
