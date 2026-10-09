import XCTest
@testable import Scorely

final class MusicPlayerStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makePlaylist(soundCount: Int, seconds: Double = 0.2, in store: PlaylistStore) throws -> Playlist {
        let playlist = store.library
        var urls: [URL] = []
        for index in 0..<soundCount {
            let url = tempDirectory.appendingPathComponent("\(index).wav")
            try TestAudioFixture.makeSilentWAVData(seconds: seconds).write(to: url)
            urls.append(url)
        }
        try store.importSounds(from: urls, into: playlist.id)
        return store.library
    }

    func testTogglePlayPauseStartsFirstQueuedTrack() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = try makePlaylist(soundCount: 3, in: store)
        let audioManager = AudioPlayerManager()
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)

        musicPlayer.selectedFolderID = playlist.tabs[0].id
        let cuedSoundID = try XCTUnwrap(musicPlayer.currentSoundID)
        musicPlayer.togglePlayPause()

        XCTAssertTrue(musicPlayer.isPlaying)
        XCTAssertEqual(audioManager.state(for: cuedSoundID), .playing)
    }

    func testPausingAdvancesToNextTrackWithoutResumingCurrent() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = try makePlaylist(soundCount: 3, in: store)
        let audioManager = AudioPlayerManager()
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)

        musicPlayer.selectedFolderID = playlist.tabs[0].id
        let firstSoundID = try XCTUnwrap(musicPlayer.currentSoundID)
        musicPlayer.togglePlayPause() // play
        musicPlayer.togglePlayPause() // pause -> should cue next track

        XCTAssertFalse(musicPlayer.isPlaying)
        XCTAssertEqual(audioManager.state(for: firstSoundID), .played)
        let secondSoundID = try XCTUnwrap(musicPlayer.currentSoundID)
        XCTAssertNotEqual(secondSoundID, firstSoundID)

        musicPlayer.togglePlayPause() // play again: should play the newly cued track, not restart the first
        XCTAssertEqual(audioManager.state(for: secondSoundID), .playing)
        XCTAssertEqual(audioManager.state(for: firstSoundID), .played)
    }

    func testQueueWrapsAroundAfterAllTracksPlayed() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = try makePlaylist(soundCount: 2, in: store)
        let audioManager = AudioPlayerManager()
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)

        musicPlayer.selectedFolderID = playlist.tabs[0].id
        let firstSoundID = try XCTUnwrap(musicPlayer.currentSoundID)

        musicPlayer.togglePlayPause() // play track 1
        musicPlayer.togglePlayPause() // pause -> cue track 2
        musicPlayer.togglePlayPause() // play track 2
        musicPlayer.togglePlayPause() // pause -> wraps back to track 1

        XCTAssertEqual(musicPlayer.currentSoundID, firstSoundID)
    }

    func testShuffleOrderPersistsAcrossFolderSwitches() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlistA = try makePlaylist(soundCount: 5, in: store)
        let otherFolder = try XCTUnwrap(store.addTab(name: "Other", toPlaylist: playlistA.id))
        let audioManager = AudioPlayerManager()
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)

        musicPlayer.selectedFolderID = playlistA.tabs[0].id
        let firstCuedID = musicPlayer.currentSoundID

        musicPlayer.selectedFolderID = otherFolder.id
        musicPlayer.selectedFolderID = playlistA.tabs[0].id

        XCTAssertEqual(musicPlayer.currentSoundID, firstCuedID, "switching away and back should not reshuffle")
    }

    func testResetShuffleIsIgnoredWhilePlaying() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = try makePlaylist(soundCount: 3, in: store)
        let audioManager = AudioPlayerManager()
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)

        musicPlayer.selectedFolderID = playlist.tabs[0].id
        let playingSoundID = try XCTUnwrap(musicPlayer.currentSoundID)
        musicPlayer.togglePlayPause()
        XCTAssertTrue(musicPlayer.isPlaying)

        musicPlayer.resetShuffle()

        XCTAssertTrue(musicPlayer.isPlaying)
        XCTAssertEqual(musicPlayer.currentSoundID, playingSoundID)
        XCTAssertEqual(audioManager.state(for: playingSoundID), .playing)
    }

    func testResetShuffleCuesTrackWhilePaused() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = try makePlaylist(soundCount: 3, in: store)
        let audioManager = AudioPlayerManager()
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)

        musicPlayer.selectedFolderID = playlist.tabs[0].id
        musicPlayer.resetShuffle()

        XCTAssertFalse(musicPlayer.isPlaying)
        XCTAssertNotNil(musicPlayer.currentSoundID)
    }

    func testCrossFadeAdvancesToNextTrackBeforeCurrentOneNaturallyEnds() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = try makePlaylist(soundCount: 2, seconds: 1.0, in: store)
        let audioManager = AudioPlayerManager()
        audioManager.crossFadeDuration = 0.3
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)

        musicPlayer.selectedFolderID = playlist.tabs[0].id
        let firstSoundID = try XCTUnwrap(musicPlayer.currentSoundID)
        musicPlayer.togglePlayPause() // starts the ~1s-long first track

        // The crossfade is timed to start at (duration - crossFadeDuration) ≈ 0.9s in, well
        // before the file's own ~1s runs out, so by 1.1s it should already be onto the next track.
        let expectation = expectation(description: "crossfaded to next track")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { expectation.fulfill() }
        wait(for: [expectation], timeout: 3)

        XCTAssertTrue(musicPlayer.isPlaying)
        XCTAssertNotEqual(musicPlayer.currentSoundID, firstSoundID)
        XCTAssertEqual(audioManager.state(for: firstSoundID), .played)
    }

    func testSwitchingFolderStopsCurrentPlayback() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlistA = try makePlaylist(soundCount: 2, in: store)
        let otherFolder = try XCTUnwrap(store.addTab(name: "Other", toPlaylist: playlistA.id))
        let audioManager = AudioPlayerManager()
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: audioManager)

        musicPlayer.selectedFolderID = playlistA.tabs[0].id
        let playingSoundID = try XCTUnwrap(musicPlayer.currentSoundID)
        musicPlayer.togglePlayPause()
        XCTAssertTrue(musicPlayer.isPlaying)

        musicPlayer.selectedFolderID = otherFolder.id

        XCTAssertFalse(musicPlayer.isPlaying)
        XCTAssertEqual(audioManager.state(for: playingSoundID), .played)
    }

    func testSelectedFolderOnlyQueuesItsOwnSounds() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = try makePlaylist(soundCount: 2, in: store)
        let folderURL = tempDirectory.appendingPathComponent("Warmup", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for index in 0..<3 {
            try TestAudioFixture.makeSilentWAVData().write(to: folderURL.appendingPathComponent("w\(index).wav"))
        }
        let folderSoundIDs = Set(try store.importFolder(folderURL, into: playlist.id).map(\.id))
        let folderID = try XCTUnwrap(store.playlists.first { $0.id == playlist.id }?.tabs.last?.id)
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: AudioPlayerManager())

        musicPlayer.selectedFolderID = folderID
        var cuedIDs: Set<UUID> = []
        for _ in 0..<3 {
            cuedIDs.insert(try XCTUnwrap(musicPlayer.currentSoundID))
            musicPlayer.skipToNext()
        }

        XCTAssertEqual(cuedIDs, folderSoundIDs)
    }
}
