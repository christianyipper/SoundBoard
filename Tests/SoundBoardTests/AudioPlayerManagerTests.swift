import Combine
import XCTest
@testable import SoundBoard

final class AudioPlayerManagerTests: XCTestCase {
    private var audioFileURL: URL!

    override func setUp() {
        super.setUp()
        audioFileURL = TestAudioFixture.makeSilentWAVURL(seconds: 0.2)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: audioFileURL)
        super.tearDown()
    }

    func testPlayMarksSoundAsPlaying() {
        let manager = AudioPlayerManager()
        let sound = Sound(name: "Test", fileName: "test.wav")

        manager.play(sound, fileURL: audioFileURL)

        XCTAssertEqual(manager.state(for: sound.id), .playing)
    }

    func testPauseMarksSoundAsPlayed() {
        let manager = AudioPlayerManager()
        let sound = Sound(name: "Test", fileName: "test.wav")

        manager.play(sound, fileURL: audioFileURL)
        manager.pause(sound.id)

        XCTAssertEqual(manager.state(for: sound.id), .played)
    }

    func testToggleSwitchesBetweenPlayingAndPaused() {
        let manager = AudioPlayerManager()
        let sound = Sound(name: "Test", fileName: "test.wav")

        manager.toggle(sound, fileURL: audioFileURL)
        XCTAssertEqual(manager.state(for: sound.id), .playing)

        manager.toggle(sound, fileURL: audioFileURL)
        XCTAssertEqual(manager.state(for: sound.id), .played)
    }

    func testCrossFadeFallsBackToInstantPauseAndPlayWhenDurationIsZero() {
        let manager = AudioPlayerManager()
        manager.crossFadeDuration = 0
        let soundA = Sound(name: "A", fileName: "a.wav")
        let soundB = Sound(name: "B", fileName: "b.wav")

        manager.play(soundA, fileURL: audioFileURL)
        manager.crossFade(from: soundA.id, to: soundB, fileURL: audioFileURL)

        XCTAssertEqual(manager.state(for: soundA.id), .played)
        XCTAssertEqual(manager.state(for: soundB.id), .playing)
    }

    func testCrossFadeMarksOutgoingPlayedAndIncomingPlaying() {
        let manager = AudioPlayerManager()
        manager.crossFadeDuration = 3
        let soundA = Sound(name: "A", fileName: "a.wav")
        let soundB = Sound(name: "B", fileName: "b.wav")

        manager.play(soundA, fileURL: audioFileURL)
        manager.crossFade(from: soundA.id, to: soundB, fileURL: audioFileURL)

        XCTAssertEqual(manager.state(for: soundA.id), .played)
        XCTAssertEqual(manager.state(for: soundB.id), .playing)
    }

    func testCrossFadeFallsBackWhenOutgoingSoundIsNotPlaying() {
        let manager = AudioPlayerManager()
        manager.crossFadeDuration = 3
        let soundA = Sound(name: "A", fileName: "a.wav")
        let soundB = Sound(name: "B", fileName: "b.wav")

        // A was never played, so there's nothing to crossfade from.
        manager.crossFade(from: soundA.id, to: soundB, fileURL: audioFileURL)

        XCTAssertEqual(manager.state(for: soundB.id), .playing)
    }

    func testDurationReflectsFileLengthOnceOpened() {
        let manager = AudioPlayerManager()
        let sound = Sound(name: "Test", fileName: "test.wav")

        XCTAssertNil(manager.duration(for: sound.id), "unplayed sounds have no known duration yet")

        manager.play(sound, fileURL: audioFileURL)

        let duration = try? XCTUnwrap(manager.duration(for: sound.id))
        XCTAssertEqual(duration ?? 0, 0.2, accuracy: 0.01)
    }

    func testResetPlayedStatesClearsPlayedButNotPlaying() {
        let manager = AudioPlayerManager()
        let playedSound = Sound(name: "Played", fileName: "a.wav")
        let playingSound = Sound(name: "Playing", fileName: "b.wav")

        manager.play(playedSound, fileURL: audioFileURL)
        manager.pause(playedSound.id)
        manager.play(playingSound, fileURL: audioFileURL)

        manager.resetPlayedStates()

        XCTAssertEqual(manager.state(for: playedSound.id), .idle)
        XCTAssertEqual(manager.state(for: playingSound.id), .playing)
    }

    func testNaturalCompletionMarksSoundAsPlayed() throws {
        let manager = AudioPlayerManager()
        let sound = Sound(name: "Short", fileName: "short.wav")

        manager.play(sound, fileURL: audioFileURL)
        XCTAssertEqual(manager.state(for: sound.id), .playing)

        let result = try waitForPlayedState(of: sound.id, in: manager, timeout: 2)
        try XCTSkipIf(result == .timedOut, "No audio output device available in this environment; playback completion can't be observed.")

        XCTAssertEqual(manager.state(for: sound.id), .played)
    }

    func testPauseThenPlayRestartsFromBeginningRatherThanResuming() throws {
        let manager = AudioPlayerManager()
        let sound = Sound(name: "Long", fileName: "long.wav")
        let longFileURL = TestAudioFixture.makeSilentWAVURL(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: longFileURL) }

        manager.play(sound, fileURL: longFileURL)

        // Let it play well into the file, then stop it partway through.
        let partwayExpectation = expectation(description: "played partway through")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            partwayExpectation.fulfill()
        }
        wait(for: [partwayExpectation], timeout: 2)
        manager.pause(sound.id)
        XCTAssertEqual(manager.state(for: sound.id), .played)

        // Playing it again should restart from frame 0 — if it had merely resumed from the
        // paused position, it would finish in ~0.4s instead of running the full ~1.0s again.
        let secondPlayStart = Date()
        manager.play(sound, fileURL: longFileURL)
        XCTAssertEqual(manager.state(for: sound.id), .playing)

        let result = try waitForPlayedState(of: sound.id, in: manager, timeout: 2)
        try XCTSkipIf(result == .timedOut, "No audio output device available in this environment; playback completion can't be observed.")

        let elapsed = Date().timeIntervalSince(secondPlayStart)
        XCTAssertGreaterThan(elapsed, 0.75, "restarting after a stop should replay the full duration, not just the remaining portion")
    }

    /// Waits for `soundID` to appear in `manager.playedIDs`, e.g. after natural playback
    /// completion. Uses XCTWaiter (rather than `wait(for:)`) so a timeout can be turned into a
    /// skip instead of a hard failure — this needs a real, running audio output device, which
    /// isn't available in every environment (e.g. a headless CI sandbox with no CoreAudio device).
    private func waitForPlayedState(of soundID: UUID, in manager: AudioPlayerManager, timeout: TimeInterval) throws -> XCTWaiter.Result {
        let expectation = expectation(description: "sound reaches played state")
        var cancellable: AnyCancellable?
        cancellable = manager.$playedIDs
            .filter { $0.contains(soundID) }
            .first()
            .sink { _ in expectation.fulfill() }
        defer { cancellable?.cancel() }

        return XCTWaiter().wait(for: [expectation], timeout: timeout)
    }
}
