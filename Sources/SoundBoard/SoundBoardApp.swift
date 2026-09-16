import SwiftUI

/// Without a real .app bundle (Info.plist + bundle identifier), AppKit won't reliably give this
/// process normal application status — it can fail to become the active/key app, which in turn
/// means the global key-down monitor in ShortcutManager never sees key events. Forcing a regular
/// activation policy and explicitly activating on launch works around that regardless of how the
/// binary was launched (bare `swift run`, Xcode, or the packaged .app from Scripts/build-app.sh).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct SoundBoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var playlistStore: PlaylistStore
    @StateObject private var audioPlayerManager: AudioPlayerManager
    @StateObject private var hotkeyBarStore: HotkeyBarStore
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var microphoneManager: MicrophoneManager
    @StateObject private var musicPlayerStore: MusicPlayerStore
    private let shortcutManager: ShortcutManager

    init() {
        let store = PlaylistStore()
        let audio = AudioPlayerManager()
        let hotkeys = HotkeyBarStore(baseDirectory: store.appSupportDirectory)
        let settings = SettingsStore(baseDirectory: store.appSupportDirectory)
        let microphone = MicrophoneManager()
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: audio)
        audio.bind(to: settings)
        microphone.bind(to: settings)
        _playlistStore = StateObject(wrappedValue: store)
        _audioPlayerManager = StateObject(wrappedValue: audio)
        _hotkeyBarStore = StateObject(wrappedValue: hotkeys)
        _settingsStore = StateObject(wrappedValue: settings)
        _microphoneManager = StateObject(wrappedValue: microphone)
        _musicPlayerStore = StateObject(wrappedValue: musicPlayer)
        shortcutManager = ShortcutManager(
            playlistStore: store,
            audioPlayerManager: audio,
            hotkeyBarStore: hotkeys,
            microphoneManager: microphone,
            musicPlayerStore: musicPlayer
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playlistStore)
                .environmentObject(audioPlayerManager)
                .environmentObject(hotkeyBarStore)
                .environmentObject(shortcutManager)
                .environmentObject(microphoneManager)
                .environmentObject(musicPlayerStore)
                .onAppear {
                    shortcutManager.start()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear {
                    playlistStore.flush()
                    hotkeyBarStore.flush()
                    settingsStore.flush()
                }
                .preferredColorScheme(settingsStore.settings.appearance.colorScheme)
                .tint(DesignSystem.Colors.accentPrimary)
        }
        .defaultSize(width: 900, height: 640)

        Settings {
            SettingsView()
                .environmentObject(settingsStore)
                .preferredColorScheme(settingsStore.settings.appearance.colorScheme)
                .tint(DesignSystem.Colors.accentPrimary)
        }
    }
}
