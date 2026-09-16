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
            musicPlayerStore: MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)
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
            musicPlayerStore: MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)
        )

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 18, modifierFlags: [])) // physical "1" key, unassigned
        let result = manager.handle(event)

        XCTAssertNil(result, "reserved hotkey bar keys are still consumed even when the slot is empty")
    }

    func testHandleTogglesMicOnMicSlotKey() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let hotkeyBarStore = HotkeyBarStore(baseDirectory: tempDirectory)
        let audioManager = AudioPlayerManager()
        let microphoneManager = MicrophoneManager()
        let manager = ShortcutManager(
            playlistStore: store,
            audioPlayerManager: audioManager,
            hotkeyBarStore: hotkeyBarStore,
            microphoneManager: microphoneManager,
            musicPlayerStore: MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)
        )

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 9, modifierFlags: [])) // physical "V" key
        let result = manager.handle(event)

        XCTAssertNil(result, "the mic slot key press should be consumed")
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
            musicPlayerStore: musicPlayerStore
        )

        let event = try XCTUnwrap(Self.keyEvent(keyCode: 49, modifierFlags: [])) // spacebar
        let result = manager.handle(event)

        XCTAssertNil(result, "spacebar presses should be consumed")
        XCTAssertTrue(musicPlayerStore.isPlaying)
        XCTAssertEqual(audioManager.state(for: sound.id), .playing)
    }

    private func makeManager(playlistStore: PlaylistStore, audioPlayerManager: AudioPlayerManager) -> ShortcutManager {
        ShortcutManager(
            playlistStore: playlistStore,
            audioPlayerManager: audioPlayerManager,
            hotkeyBarStore: HotkeyBarStore(baseDirectory: tempDirectory),
            microphoneManager: MicrophoneManager(),
            musicPlayerStore: MusicPlayerStore(playlistStore: playlistStore, audioPlayerManager: audioPlayerManager)
        )
    }

    private static func keyEvent(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
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
