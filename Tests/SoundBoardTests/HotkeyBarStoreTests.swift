import XCTest
@testable import SoundBoard

final class HotkeyBarStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testSlotsAreOrderedOneThroughNineThenZeroThenPAndV() {
        let displayKeys = HotkeyBarStore.slots.map(\.displayKey)
        XCTAssertEqual(displayKeys, ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "p", "v"])
    }

    func testSlotTitlesMatchRequestedLabels() {
        let titles = HotkeyBarStore.slots.map(\.title)
        XCTAssertEqual(titles, [
            "Home Goal", "Away Goal", "Penalty", "Even Strength", "Scorer",
            "Assist 1", "Assist 2", "End of Goal", "End of Period", "Last Minute",
            "Commissioner", "Microphone"
        ])
    }

    func testAssignAndClearSlot() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let sound = Sound(name: "Goal Horn", fileName: "horn.wav")

        store.assign(sound, toSlot: 0)
        XCTAssertEqual(store.assignment(at: 0)?.soundID, sound.id)

        store.clear(slot: 0)
        XCTAssertNil(store.assignment(at: 0))
    }

    func testResetAllClearsEverySlot() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        store.assign(Sound(name: "A", fileName: "a.wav"), toSlot: 0)
        store.assign(Sound(name: "B", fileName: "b.wav"), toSlot: 9)

        store.resetAll()

        XCTAssertNil(store.assignment(at: 0))
        XCTAssertNil(store.assignment(at: 9))
    }

    func testSlotForKeyCodeLookup() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        XCTAssertEqual(store.slot(forKeyCode: 18)?.displayKey, "1")
        XCTAssertEqual(store.slot(forKeyCode: 29)?.displayKey, "0")
        XCTAssertNil(store.slot(forKeyCode: 99))
    }

    func testPersistenceRoundTrip() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let sound = Sound(name: "Goal Horn", fileName: "horn.wav")
        store.assign(sound, toSlot: 3)
        store.flush()

        let reloaded = HotkeyBarStore(baseDirectory: tempDirectory)
        XCTAssertEqual(reloaded.assignment(at: 3)?.soundID, sound.id)
        XCTAssertEqual(reloaded.assignment(at: 3)?.name, "Goal Horn")
    }
}
