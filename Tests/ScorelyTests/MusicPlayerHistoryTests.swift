import XCTest
@testable import Scorely

/// The music player's play history surviving an app restart, and the toolbar Reset clearing it.
final class MusicPlayerHistoryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makePlaylist(soundCount: Int, in store: PlaylistStore) throws -> Playlist {
        let playlist = store.library
        var urls: [URL] = []
        for index in 0..<soundCount {
            let url = tempDirectory.appendingPathComponent("\(index).wav")
            try TestAudioFixture.makeSilentWAVData(seconds: 0.2).write(to: url)
            urls.append(url)
        }
        try store.importSounds(from: urls, into: playlist.id)
        return store.library
    }

    func testRelaunchCuesTheSameShuffledTrack() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let folderID = try makePlaylist(soundCount: 5, in: store).tabs[0].id
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: AudioPlayerManager(), baseDirectory: tempDirectory)
        musicPlayer.selectedFolderID = folderID
        musicPlayer.toggleShuffle()
        musicPlayer.skipToNext()
        musicPlayer.skipToNext()
        let cued = musicPlayer.currentSoundID
        musicPlayer.flush()

        let relaunched = MusicPlayerStore(playlistStore: store, audioPlayerManager: AudioPlayerManager(), baseDirectory: tempDirectory)
        XCTAssertEqual(relaunched.selectedFolderID, folderID)
        XCTAssertTrue(relaunched.isShuffled)
        XCTAssertEqual(relaunched.currentSoundID, cued)
    }

    func testTrackPlayingAtQuitCountsAsPlayed() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let folderID = try makePlaylist(soundCount: 3, in: store).tabs[0].id
        let audio = AudioPlayerManager()
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: audio, baseDirectory: tempDirectory)
        musicPlayer.selectedFolderID = folderID
        let playing = musicPlayer.currentSoundID
        musicPlayer.togglePlayPause()
        musicPlayer.flush()
        if let playing { audio.pause(playing) }

        let relaunched = MusicPlayerStore(playlistStore: store, audioPlayerManager: AudioPlayerManager(), baseDirectory: tempDirectory)
        XCTAssertNotNil(relaunched.currentSoundID)
        XCTAssertNotEqual(relaunched.currentSoundID, playing)
        XCTAssertFalse(relaunched.isPlaying)
    }

    func testResetHistoryStartsTheFolderOverAndIsSaved() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let folderID = try makePlaylist(soundCount: 3, in: store).tabs[0].id
        let musicPlayer = MusicPlayerStore(playlistStore: store, audioPlayerManager: AudioPlayerManager(), baseDirectory: tempDirectory)
        musicPlayer.selectedFolderID = folderID
        let first = musicPlayer.currentSoundID
        musicPlayer.skipToNext()
        XCTAssertNotEqual(musicPlayer.currentSoundID, first)

        musicPlayer.resetHistory()
        XCTAssertEqual(musicPlayer.currentSoundID, first)
        musicPlayer.flush()

        let relaunched = MusicPlayerStore(playlistStore: store, audioPlayerManager: AudioPlayerManager(), baseDirectory: tempDirectory)
        XCTAssertEqual(relaunched.currentSoundID, first)
    }
}
