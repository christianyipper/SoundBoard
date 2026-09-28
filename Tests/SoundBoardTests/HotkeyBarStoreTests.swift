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

    func testKeySlotsAreOrderedOneThroughFiveThenSixThroughZero() {
        let displayKeys = HotkeyBarStore.keySlots.map(\.displayKey)
        XCTAssertEqual(displayKeys, ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
    }

    func testDefaultPresetTitlesMatchRequestedLabels() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let titles = (0..<10).map { store.title(at: $0) }
        XCTAssertEqual(titles, [
            "Home Goal", "Away Goal", "Penalty", "Even Strength", "Scorer",
            "Assist 1", "Assist 2", "End of Goal", "End of Period", "Last Minute"
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

    func testResetAllClearsEverySlotButKeepsTitles() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        store.assign(Sound(name: "A", fileName: "a.wav"), toSlot: 0)
        store.assign(Sound(name: "B", fileName: "b.wav"), toSlot: 9)

        store.resetAll()

        XCTAssertNil(store.assignment(at: 0))
        XCTAssertNil(store.assignment(at: 9))
        XCTAssertEqual(store.title(at: 0), "Home Goal")
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

    func testRenameSlot() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        store.renameSlot(0, title: "Custom Title")
        XCTAssertEqual(store.title(at: 0), "Custom Title")
    }

    func testCreateSelectAndDeletePreset() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let defaultPresetID = store.presets.first!.id

        let preset = store.createPreset(name: "Basketball")
        XCTAssertEqual(store.selectedPresetID, preset.id)
        XCTAssertEqual(store.presets.count, 2)

        store.selectPreset(defaultPresetID)
        XCTAssertEqual(store.selectedPresetID, defaultPresetID)
        XCTAssertEqual(store.title(at: 0), "Home Goal")

        store.deletePreset(preset.id)
        XCTAssertEqual(store.presets.count, 1)
    }

    func testDeletingTheOnlyPresetIsANoOp() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let onlyPresetID = store.presets.first!.id

        store.deletePreset(onlyPresetID)

        XCTAssertEqual(store.presets.count, 1)
        XCTAssertEqual(store.selectedPresetID, onlyPresetID)
    }

    func testPresetsHaveIndependentTitlesAndAssignments() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let defaultPresetID = store.presets.first!.id
        let sound = Sound(name: "Buzzer", fileName: "buzzer.wav")
        store.assign(sound, toSlot: 0)

        let basketball = store.createPreset(name: "Basketball")
        XCTAssertNil(store.assignment(at: 0), "new preset should start with no assignments")
        store.renameSlot(0, title: "Buzzer Beater")

        store.selectPreset(defaultPresetID)
        XCTAssertEqual(store.assignment(at: 0)?.soundID, sound.id, "original preset's assignment should be untouched")
        XCTAssertEqual(store.title(at: 0), "Home Goal", "original preset's title should be untouched")

        store.selectPreset(basketball.id)
        XCTAssertEqual(store.title(at: 0), "Buzzer Beater")
    }

    func testSelectAdjacentPresetWrapsAroundInBothDirections() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let firstID = store.presets.first!.id
        let second = store.createPreset(name: "Second")
        let third = store.createPreset(name: "Third")
        store.selectPreset(firstID)

        store.selectAdjacentPreset(offset: 1)
        XCTAssertEqual(store.selectedPresetID, second.id)

        store.selectAdjacentPreset(offset: 1)
        XCTAssertEqual(store.selectedPresetID, third.id)

        store.selectAdjacentPreset(offset: 1)
        XCTAssertEqual(store.selectedPresetID, firstID, "should wrap around past the last preset")

        store.selectAdjacentPreset(offset: -1)
        XCTAssertEqual(store.selectedPresetID, third.id, "should wrap around backwards past the first preset")
    }

    func testSelectAdjacentPresetIsNoOpWithOnlyOnePreset() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let onlyPresetID = store.presets.first!.id

        store.selectAdjacentPreset(offset: 1)

        XCTAssertEqual(store.selectedPresetID, onlyPresetID)
    }

    func testRenamePreset() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let presetID = store.presets.first!.id
        store.renamePreset(presetID, to: "Hockey")
        XCTAssertEqual(store.presets.first?.name, "Hockey")
    }
}
