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
    @StateObject private var gameStore: GameStore
    @StateObject private var rosterStore: RosterStore
    private let shortcutManager: ShortcutManager

    init() {
        let store = PlaylistStore()
        let audio = AudioPlayerManager(
            loudnessCache: LoudnessCache(fileURL: store.appSupportDirectory.appendingPathComponent("loudness.json"))
        )
        let hotkeys = HotkeyBarStore(baseDirectory: store.appSupportDirectory)
        let settings = SettingsStore(baseDirectory: store.appSupportDirectory)
        let microphone = MicrophoneManager()
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: audio)
        audio.bind(to: settings)
        audio.bind(to: store)
        microphone.bind(to: settings)
        _playlistStore = StateObject(wrappedValue: store)
        _audioPlayerManager = StateObject(wrappedValue: audio)
        _hotkeyBarStore = StateObject(wrappedValue: hotkeys)
        _settingsStore = StateObject(wrappedValue: settings)
        _microphoneManager = StateObject(wrappedValue: microphone)
        _musicPlayerStore = StateObject(wrappedValue: musicPlayer)
        let game = GameStore(baseDirectory: store.appSupportDirectory)
        _gameStore = StateObject(wrappedValue: game)
        _rosterStore = StateObject(wrappedValue: RosterStore(baseDirectory: store.appSupportDirectory))
        shortcutManager = ShortcutManager(
            playlistStore: store,
            audioPlayerManager: audio,
            hotkeyBarStore: hotkeys,
            microphoneManager: microphone,
            musicPlayerStore: musicPlayer,
            settingsStore: settings,
            gameStore: game
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
                .environmentObject(settingsStore)
                .environmentObject(gameStore)
                .environmentObject(rosterStore)
                .onAppear {
                    shortcutManager.start()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onDisappear {
                    playlistStore.flush()
                    hotkeyBarStore.flush()
                    settingsStore.flush()
                    gameStore.flush()
                }
                .preferredColorScheme(settingsStore.settings.appearance.colorScheme)
                .tint(DesignSystem.Colors.accentPrimary)
        }
        .defaultSize(width: 900, height: 640)

        Settings {
            SettingsView()
                .environmentObject(settingsStore)
                .environmentObject(rosterStore)
                .preferredColorScheme(settingsStore.settings.appearance.colorScheme)
                .tint(DesignSystem.Colors.accentPrimary)
        }
    }
}
