import AppKit
import Combine

/// Installs a single local key-down monitor for the app's lifetime. Normally it checks the
/// spacebar (music player play/pause) first, then the fixed hotkey bar slots (plain keys
/// 1-9/0/P/V), then every sound's custom assigned shortcut, toggling play/pause on a match. The
/// "V" slot is fixed as the mic toggle rather than a sound slot, so it toggles live mic
/// passthrough instead. While `beginRecording` is active, the next key-down is instead captured
/// and handed back to the caller (used by the "assign shortcut" UI), rather than triggering
/// playback. Key-downs are ignored while a text field is being edited, so typing into a
/// rename/name dialog never accidentally triggers a sound.
final class ShortcutManager: ObservableObject {
    private static let spacebarKeyCode: UInt16 = 49

    private let playlistStore: PlaylistStore
    private let audioPlayerManager: AudioPlayerManager
    private let hotkeyBarStore: HotkeyBarStore
    private let microphoneManager: MicrophoneManager
    private let musicPlayerStore: MusicPlayerStore
    private var monitor: Any?
    private var recordingCompletion: ((SoundShortcut) -> Void)?

    init(
        playlistStore: PlaylistStore,
        audioPlayerManager: AudioPlayerManager,
        hotkeyBarStore: HotkeyBarStore,
        microphoneManager: MicrophoneManager,
        musicPlayerStore: MusicPlayerStore
    ) {
        self.playlistStore = playlistStore
        self.audioPlayerManager = audioPlayerManager
        self.hotkeyBarStore = hotkeyBarStore
        self.microphoneManager = microphoneManager
        self.musicPlayerStore = musicPlayerStore
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
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
        if hasNoModifiers, let slot = hotkeyBarStore.slot(forKeyCode: event.keyCode) {
            switch slot.kind {
            case .microphone:
                microphoneManager.toggle()
            case .sound:
                if let assignment = hotkeyBarStore.assignment(at: slot.index) {
                    let sound = assignment.asSound
                    audioPlayerManager.toggle(sound, fileURL: playlistStore.soundsDirectory.appendingPathComponent(assignment.fileName))
                }
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

    private var isEditingText: Bool {
        NSApplication.shared.keyWindow?.firstResponder is NSText
    }
}
