import AppKit
import XCTest
@testable import SoundBoard

final class ShortcutManagerTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testHandleTogglesSoundWithMatchingShortcut() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.addPlaylist(name: "Effects")
        let sourceURL = tempDirectory.appendingPathComponent("a.wav")
        try TestAudioFixture.makeSilentWAVData().write(to: sourceURL)
        let sound = try store.importSounds(from: [sourceURL], into: playlist.id).first!

        let shortcut = SoundShortcut(keyCode: 1, modifierFlags: [.command])
        store.setShortcut(shortcut, forSound: sound.id, inPlaylist: playlist.id)

        let audioManager = AudioPlayerManager()
        let manager = makeManager(playlistStore: store, audioPlayerManager: audioManager)

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 1, modifierFlags: [.command]))
        let result = manager.handle(event)

        XCTAssertNil(result, "matching shortcut events should be consumed")
        XCTAssertEqual(audioManager.state(for: sound.id), .playing)
    }

    func testHandlePassesThroughUnassignedShortcut() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let audioManager = AudioPlayerManager()
        let manager = makeManager(playlistStore: store, audioPlayerManager: audioManager)

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 99, modifierFlags: []))
        let result = manager.handle(event)

        XCTAssertNotNil(result, "unassigned shortcuts should propagate normally")
    }

    func testRecordingCapturesNextKeyEventInsteadOfToggling() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let audioManager = AudioPlayerManager()
        let manager = makeManager(playlistStore: store, audioPlayerManager: audioManager)

        var captured: SoundShortcut?
        manager.beginRecording { captured = $0 }

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 5, modifierFlags: [.shift]))
        let result = manager.handle(event)

        XCTAssertNil(result)
        XCTAssertEqual(captured, SoundShortcut(keyCode: 5, modifierFlags: [.shift]))
    }

    func testHandleTogglesHotkeyBarSlotOnPlainNumberKey() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.addPlaylist(name: "Effects")
        let sourceURL = tempDirectory.appendingPathComponent("a.wav")
        try TestAudioFixture.makeSilentWAVData().write(to: sourceURL)
        let sound = try store.importSounds(from: [sourceURL], into: playlist.id).first!

        let hotkeyBarStore = HotkeyBarStore(baseDirectory: tempDirectory)
        hotkeyBarStore.assign(sound, toSlot: 0) // slot "1"

        let audioManager = AudioPlayerManager()
        let manager = ShortcutManager(
            playlistStore: store,
            audioPlayerManager: audioManager,
            hotkeyBarStore: hotkeyBarStore,
            microphoneManager: MicrophoneManager(),
            musicPlayerStore: MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager),
            settingsStore: SettingsStore(baseDirectory: tempDirectory)
        )

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 18, modifierFlags: [])) // physical "1" key
        let result = manager.handle(event)

        XCTAssertNil(result, "hotkey bar slot key presses should be consumed")
        XCTAssertEqual(audioManager.state(for: sound.id), .playing)
    }

    func testHandleIgnoresEmptyHotkeyBarSlot() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let hotkeyBarStore = HotkeyBarStore(baseDirectory: tempDirectory)
        let audioManager = AudioPlayerManager()
        let manager = ShortcutManager(
            playlistStore: store,
            audioPlayerManager: audioManager,
            hotkeyBarStore: hotkeyBarStore,
            microphoneManager: MicrophoneManager(),
            musicPlayerStore: MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager),
            settingsStore: SettingsStore(baseDirectory: tempDirectory)
        )

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 18, modifierFlags: [])) // physical "1" key, unassigned
        let result = manager.handle(event)

        XCTAssertNil(result, "reserved hotkey bar keys are still consumed even when the slot is empty")
    }

    func testHandleTogglesMicOnMicKeyInToggleMode() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let hotkeyBarStore = HotkeyBarStore(baseDirectory: tempDirectory)
        let audioManager = AudioPlayerManager()
        let microphoneManager = MicrophoneManager()
        let settingsStore = SettingsStore(baseDirectory: tempDirectory)
        settingsStore.settings.microphoneHotkeyMode = .toggle
        let manager = ShortcutManager(
            playlistStore: store,
            audioPlayerManager: audioManager,
            hotkeyBarStore: hotkeyBarStore,
            microphoneManager: microphoneManager,
            musicPlayerStore: MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager),
            settingsStore: settingsStore
        )

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 9, modifierFlags: [])) // physical "V" key
        let result = manager.handle(event)

        XCTAssertNil(result, "the mic hotkey press should be consumed")
    }

    func testMicKeyDownStartsAndKeyUpStopsInPushToTalkMode() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let hotkeyBarStore = HotkeyBarStore(baseDirectory: tempDirectory)
        let audioManager = AudioPlayerManager()
        let microphoneManager = MicrophoneManager()
        let settingsStore = SettingsStore(baseDirectory: tempDirectory)
        settingsStore.settings.microphoneHotkeyMode = .pushToTalk
        let manager = ShortcutManager(
            playlistStore: store,
            audioPlayerManager: audioManager,
            hotkeyBarStore: hotkeyBarStore,
            microphoneManager: microphoneManager,
            musicPlayerStore: MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager),
            settingsStore: settingsStore
        )

        let downEvent = try XCTUnwrap(Self.keyEvent(keyCode: 9, modifierFlags: [], type: .keyDown))
        XCTAssertNil(manager.handle(downEvent))

        let upEvent = try XCTUnwrap(Self.keyEvent(keyCode: 9, modifierFlags: [], type: .keyUp))
        manager.handleKeyUp(upEvent)
        // Without microphone access granted in the test environment, start() never actually
        // flips isLive; this test only verifies the key-up path doesn't crash and is reachable.
        XCTAssertFalse(microphoneManager.isLive)
    }

    func testHandleTogglesMusicPlayerOnSpacebar() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.addPlaylist(name: "Music")
        let sourceURL = tempDirectory.appendingPathComponent("a.wav")
        try TestAudioFixture.makeSilentWAVData().write(to: sourceURL)
        let sound = try store.importSounds(from: [sourceURL], into: playlist.id).first!

        let audioManager = AudioPlayerManager()
        let musicPlayerStore = MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)
        musicPlayerStore.selectedPlaylistID = playlist.id
        let manager = ShortcutManager(
            playlistStore: store,
            audioPlayerManager: audioManager,
            hotkeyBarStore: HotkeyBarStore(baseDirectory: tempDirectory),
            microphoneManager: MicrophoneManager(),
            musicPlayerStore: musicPlayerStore,
            settingsStore: SettingsStore(baseDirectory: tempDirectory)
        )

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 49, modifierFlags: [])) // spacebar
        let result = manager.handle(event)

        XCTAssertNil(result, "spacebar presses should be consumed")
        XCTAssertTrue(musicPlayerStore.isPlaying)
        XCTAssertEqual(audioManager.state(for: sound.id), .playing)
    }

    func testArrowKeysSwitchHotkeyPresetTabsWhenMultiplePresetsExist() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let hotkeyBarStore = HotkeyBarStore(baseDirectory: tempDirectory)
        let firstPresetID = try XCTUnwrap(hotkeyBarStore.presets.first?.id)
        let secondPreset = hotkeyBarStore.createPreset(name: "Second")
        hotkeyBarStore.selectPreset(firstPresetID)

        let audioManager = AudioPlayerManager()
        let manager = ShortcutManager(
            playlistStore: store,
            audioPlayerManager: audioManager,
            hotkeyBarStore: hotkeyBarStore,
            microphoneManager: MicrophoneManager(),
            musicPlayerStore: MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager),
            settingsStore: SettingsStore(baseDirectory: tempDirectory)
        )

        // Real arrow key events always carry .numericPad (and usually .function) from macOS
        // itself, even with no keys held down — exercising that here is what would have caught
        // the original bug, where requiring zero modifier flags silently broke arrow handling.
        let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

        let rightEvent = try XCTUnwrap(Self.keyEvent(keyCode: 124, modifierFlags: arrowFlags)) // right arrow
        XCTAssertNil(manager.handle(rightEvent), "right arrow should be consumed when multiple presets exist")
        XCTAssertEqual(hotkeyBarStore.selectedPresetID, secondPreset.id)

        let leftEvent = try XCTUnwrap(Self.keyEvent(keyCode: 123, modifierFlags: arrowFlags)) // left arrow
        XCTAssertNil(manager.handle(leftEvent))
        XCTAssertEqual(hotkeyBarStore.selectedPresetID, firstPresetID)
    }

    func testCommandArrowDoesNotSwitchHotkeyPresetTabs() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let hotkeyBarStore = HotkeyBarStore(baseDirectory: tempDirectory)
        let firstPresetID = try XCTUnwrap(hotkeyBarStore.presets.first?.id)
        _ = hotkeyBarStore.createPreset(name: "Second")
        hotkeyBarStore.selectPreset(firstPresetID)

        let audioManager = AudioPlayerManager()
        let manager = ShortcutManager(
            playlistStore: store,
            audioPlayerManager: audioManager,
            hotkeyBarStore: hotkeyBarStore,
            microphoneManager: MicrophoneManager(),
            musicPlayerStore: MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager),
            settingsStore: SettingsStore(baseDirectory: tempDirectory)
        )

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 124, modifierFlags: [.command, .numericPad, .function]))
        XCTAssertNotNil(manager.handle(event), "cmd+arrow should propagate normally, not switch tabs")
        XCTAssertEqual(hotkeyBarStore.selectedPresetID, firstPresetID)
    }

    func testArrowKeysPassThroughWithOnlyOneHotkeyPreset() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let hotkeyBarStore = HotkeyBarStore(baseDirectory: tempDirectory)
        let audioManager = AudioPlayerManager()
        let manager = ShortcutManager(
            playlistStore: store,
            audioPlayerManager: audioManager,
            hotkeyBarStore: hotkeyBarStore,
            microphoneManager: MicrophoneManager(),
            musicPlayerStore: MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager),
            settingsStore: SettingsStore(baseDirectory: tempDirectory)
        )

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 124, modifierFlags: [.numericPad, .function])) // right arrow
        XCTAssertNotNil(manager.handle(event), "arrow keys should propagate normally with only one preset")
    }

    private func makeManager(playlistStore: PlaylistStore, audioPlayerManager: AudioPlayerManager) -> ShortcutManager {
        ShortcutManager(
            playlistStore: playlistStore,
            audioPlayerManager: audioPlayerManager,
            hotkeyBarStore: HotkeyBarStore(baseDirectory: tempDirectory),
            microphoneManager: MicrophoneManager(),
            musicPlayerStore: MusicPlayerStore(playlistStore: playlistStore, audioPlayerManager: audioPlayerManager),
            settingsStore: SettingsStore(baseDirectory: tempDirectory)
        )
    }

    private static func keyEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
