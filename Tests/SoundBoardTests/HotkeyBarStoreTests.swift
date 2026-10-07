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
            "Home Goal", "Away Goal", "Penalty", "Even Strength", "End of Period",
            "Slot 6", "Slot 7", "Slot 8", "Slot 9", "Slot 0"
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
        (0..<5).forEach { _ in store.addKey() }
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

    func testAddingAndRemovingKeys() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        XCTAssertEqual(store.visibleKeySlots.map(\.displayKey), ["1", "2", "3", "4", "5"])
        XCTAssertNil(store.slot(forKeyCode: 22), "key 6 should pass through while hidden")

        store.addKey()
        XCTAssertEqual(store.keyCount, 6)
        XCTAssertEqual(store.slot(forKeyCode: 22)?.displayKey, "6")

        (0..<10).forEach { _ in store.addKey() }
        XCTAssertEqual(store.keyCount, 10, "can't go past key 0")
        XCTAssertFalse(store.canAddKey)

        (0..<20).forEach { _ in store.removeLastKey() }
        XCTAssertEqual(store.keyCount, 1, "at least one key stays")
        XCTAssertFalse(store.canRemoveKey)
    }

    func testDefaultAndGoalCallPresetsExist() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        XCTAssertEqual(store.presets.map(\.name), ["Default", "Goal Call"])
        XCTAssertEqual(store.selectedPresetID, store.presets[0].id)
        XCTAssertEqual(store.title(at: 0), "Home Goal")

        store.selectPreset(named: "Goal Call")
        XCTAssertEqual(store.selectedPresetID, store.presets[1].id)
        XCTAssertEqual(store.title(at: 0), "Team Intro")
        XCTAssertEqual((0..<10).map { store.title(at: $0) }, [
            "Team Intro", "Goal", "Assist #1", "Assist #2", "Team End",
            "Slot 6", "Slot 7", "Slot 8", "Slot 9", "Slot 0"
        ])
    }

    func testGoalCallPresetKeepsItsOwnAssignments() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let horn = Sound(name: "Horn", fileName: "horn.wav")
        let call = Sound(name: "Call", fileName: "call.wav")
        store.assign(horn, toSlot: 0)
        store.selectPreset(named: "Goal Call")
        store.assign(call, toSlot: 0)
        store.flush()

        let reloaded = HotkeyBarStore(baseDirectory: tempDirectory)
        XCTAssertEqual(reloaded.assignment(at: 0)?.soundID, call.id, "the selected preset persists")
        reloaded.selectPreset(named: "Default")
        XCTAssertEqual(reloaded.assignment(at: 0)?.soundID, horn.id)
    }

    func testHiddenKeysKeepTheirAssignments() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let sound = Sound(name: "Horn", fileName: "horn.wav")
        store.assign(sound, toSlot: 4)

        store.removeLastKey()
        XCTAssertNil(store.slot(forSoundID: sound.id), "hidden slots shouldn't badge sounds")
        store.addKey()
        XCTAssertEqual(store.assignment(at: 4)?.soundID, sound.id)
        XCTAssertEqual(store.slot(forSoundID: sound.id)?.displayKey, "5")
    }

    func testRemovingAHotkeyShiftsLaterKeysDown() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        let penalty = Sound(name: "Penalty", fileName: "penalty.wav")
        let scorer = Sound(name: "Scorer", fileName: "scorer.wav")
        store.assign(penalty, toSlot: 2)
        store.assign(scorer, toSlot: 4)

        store.removeKey(at: 2)

        XCTAssertEqual(store.keyCount, 4)
        XCTAssertNil(store.slot(forSoundID: penalty.id))
        XCTAssertEqual(store.title(at: 2), "Even Strength")
        XCTAssertEqual(store.assignment(at: 3)?.soundID, scorer.id)
        XCTAssertEqual(store.slot(forSoundID: scorer.id)?.displayKey, "4")
        XCTAssertEqual(store.title(at: 9), "Slot 0", "a blank slot fills in at the end")
    }

    func testKeyCountPersists() {
        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        store.addKey()
        store.flush()

        XCTAssertEqual(HotkeyBarStore(baseDirectory: tempDirectory).keyCount, 6)
    }

    func testExtendedKeysSwitchMigratesToKeyCount() throws {
        let slots = (0..<10).map { ["title": "T\($0)"] }
        let json: [String: Any] = [
            "presets": [
                ["id": UUID().uuidString, "name": "Default", "slots": slots, "showsExtendedKeys": true],
                ["id": UUID().uuidString, "name": "Goal Call", "slots": slots, "showsExtendedKeys": false]
            ]
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: tempDirectory.appendingPathComponent("hotkeys.json"))

        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        XCTAssertEqual(store.keyCount, 10)
        store.selectPreset(named: "Goal Call")
        XCTAssertEqual(store.keyCount, 5)
    }

    func testLegacyUserPresetsMigrateToFixedPresets() throws {
        let sound = Sound(name: "Horn", fileName: "horn.wav")
        let assignment = HotkeyAssignment(sound: sound)
        let legacySlots = (0..<10).map { i in
            ["title": "T\(i)", "assignment": i == 7 ? ["soundID": assignment.soundID.uuidString, "name": assignment.name, "fileName": assignment.fileName] : nil] as [String: Any?]
        }.map { $0.compactMapValues { $0 } }
        let legacyID = UUID()
        let json: [String: Any] = [
            "presets": [
                ["id": legacyID.uuidString, "name": "Hockey", "slots": legacySlots],
                ["id": UUID().uuidString, "name": "Basketball", "slots": legacySlots]
            ],
            "selectedPresetID": legacyID.uuidString
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: tempDirectory.appendingPathComponent("hotkeys.json"))

        let store = HotkeyBarStore(baseDirectory: tempDirectory)
        XCTAssertEqual(store.presets.map(\.name), ["Default", "Goal Call"])
        XCTAssertEqual(store.selectedPresetID, legacyID, "first legacy preset becomes Default")
        XCTAssertEqual(store.title(at: 0), "T0")
        XCTAssertEqual(store.keyCount, 5, "legacy presets start with only keys 1-5 showing")
        XCTAssertEqual(store.assignment(at: 7)?.soundID, sound.id, "the hidden 6-0 assignment is kept")
    }
}
