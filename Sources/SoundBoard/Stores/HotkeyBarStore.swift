import Foundation

/// Owns the fixed 10-key hotkey rack (number row 1-5 on top, 6-0 on the bottom) shown above the
/// sound grid, organized into user-created "presets" — independently named racks, each with its
/// own slot titles and sound assignments, switchable via tabs. The physical key layout (which key
/// code sits at which grid position) is fixed and shared by every preset; only slot titles and
/// assignments vary per preset. The microphone toggle is a separate, fixed "V" hotkey handled by
/// ShortcutManager directly, independent of any preset.
final class HotkeyBarStore: ObservableObject {
    struct KeySlot: Identifiable {
        let index: Int
        let keyCode: UInt16
        let displayKey: String
        var id: Int { index }
    }

    /// Row 1: keys 1-5 (indices 0-4). Row 2: keys 6-0 (indices 5-9). Key codes are the physical ANSI keyboard codes.
    static let keySlots: [KeySlot] = [
        KeySlot(index: 0, keyCode: 18, displayKey: "1"),
        KeySlot(index: 1, keyCode: 19, displayKey: "2"),
        KeySlot(index: 2, keyCode: 20, displayKey: "3"),
        KeySlot(index: 3, keyCode: 21, displayKey: "4"),
        KeySlot(index: 4, keyCode: 23, displayKey: "5"),
        KeySlot(index: 5, keyCode: 22, displayKey: "6"),
        KeySlot(index: 6, keyCode: 26, displayKey: "7"),
        KeySlot(index: 7, keyCode: 28, displayKey: "8"),
        KeySlot(index: 8, keyCode: 25, displayKey: "9"),
        KeySlot(index: 9, keyCode: 29, displayKey: "0")
    ]

    private static let defaultTitles = [
        "Home Goal", "Away Goal", "Penalty", "Even Strength", "Scorer",
        "Assist 1", "Assist 2", "End of Goal", "End of Period", "Last Minute"
    ]

    @Published private(set) var presets: [HotkeyPreset] = []
    @Published private(set) var selectedPresetID: UUID?

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    private struct PersistedState: Codable {
        var presets: [HotkeyPreset]
        var selectedPresetID: UUID?
    }

    init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("hotkeys.json")
        if let state = Self.load(from: fileURL), !state.presets.isEmpty {
            presets = state.presets
            let hasSelected = state.selectedPresetID.map { id in state.presets.contains { $0.id == id } } ?? false
            selectedPresetID = hasSelected ? state.selectedPresetID : state.presets.first?.id
        } else {
            let defaultPreset = Self.makeDefaultPreset()
            presets = [defaultPreset]
            selectedPresetID = defaultPreset.id
        }
    }

    private static func makeDefaultPreset() -> HotkeyPreset {
        HotkeyPreset(name: "Default", slots: defaultTitles.map { HotkeyPreset.Slot(title: $0, assignment: nil) })
    }

    private static func blankSlots() -> [HotkeyPreset.Slot] {
        keySlots.map { HotkeyPreset.Slot(title: "Slot \($0.displayKey)", assignment: nil) }
    }

    // MARK: - Preset selection

    private var selectedIndex: Int? {
        guard let selectedPresetID else { return nil }
        return presets.firstIndex { $0.id == selectedPresetID }
    }

    func selectPreset(_ id: UUID) {
        guard presets.contains(where: { $0.id == id }) else { return }
        selectedPresetID = id
        scheduleSave()
    }

    /// Selects the preset tab immediately before/after the current one, wrapping around at the
    /// ends. No-op with a single preset. Used by the left/right arrow key shortcuts.
    func selectAdjacentPreset(offset: Int) {
        guard presets.count > 1, let selectedIndex else { return }
        let newIndex = ((selectedIndex + offset) % presets.count + presets.count) % presets.count
        selectedPresetID = presets[newIndex].id
        scheduleSave()
    }

    // MARK: - Preset management

    @discardableResult
    func createPreset(name: String) -> HotkeyPreset {
        let preset = HotkeyPreset(name: name, slots: Self.blankSlots())
        presets.append(preset)
        selectedPresetID = preset.id
        scheduleSave()
        return preset
    }

    func renamePreset(_ id: UUID, to newName: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[index].name = newName
        scheduleSave()
    }

    /// Reorders presets by moving `id` to just before `targetID`, e.g. when the user drags one
    /// preset tab onto another in the strip.
    func movePreset(_ id: UUID, before targetID: UUID) {
        guard id != targetID, let fromIndex = presets.firstIndex(where: { $0.id == id }) else { return }
        let preset = presets.remove(at: fromIndex)
        let toIndex = presets.firstIndex(where: { $0.id == targetID }) ?? presets.count
        presets.insert(preset, at: toIndex)
        scheduleSave()
    }

    /// Deletes a preset. At least one preset always remains, so this is a no-op if `id` is the
    /// only remaining preset.
    func deletePreset(_ id: UUID) {
        guard presets.count > 1, let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets.remove(at: index)
        if selectedPresetID == id {
            selectedPresetID = presets[min(index, presets.count - 1)].id
        }
        scheduleSave()
    }

    // MARK: - Slots (within the selected preset)

    func title(at index: Int) -> String {
        guard let selectedIndex, presets[selectedIndex].slots.indices.contains(index) else { return "" }
        return presets[selectedIndex].slots[index].title
    }

    func renameSlot(_ index: Int, title: String) {
        guard let selectedIndex, presets[selectedIndex].slots.indices.contains(index) else { return }
        presets[selectedIndex].slots[index].title = title
        scheduleSave()
    }

    func assignment(at index: Int) -> HotkeyAssignment? {
        guard let selectedIndex, presets[selectedIndex].slots.indices.contains(index) else { return nil }
        return presets[selectedIndex].slots[index].assignment
    }

    func slot(forKeyCode keyCode: UInt16) -> KeySlot? {
        Self.keySlots.first { $0.keyCode == keyCode }
    }

    /// The slot (if any) a given sound is assigned to in the currently selected preset, e.g. for
    /// badging that sound's tile in the grid with its hotkey number.
    func slot(forSoundID soundID: UUID) -> KeySlot? {
        guard let selectedIndex,
              let slotIndex = presets[selectedIndex].slots.firstIndex(where: { $0.assignment?.soundID == soundID })
        else { return nil }
        return Self.keySlots.first { $0.index == slotIndex }
    }

    func assign(_ sound: Sound, toSlot index: Int) {
        guard let selectedIndex, presets[selectedIndex].slots.indices.contains(index) else { return }
        presets[selectedIndex].slots[index].assignment = HotkeyAssignment(sound: sound)
        scheduleSave()
    }

    func clear(slot index: Int) {
        guard let selectedIndex, presets[selectedIndex].slots.indices.contains(index) else { return }
        presets[selectedIndex].slots[index].assignment = nil
        scheduleSave()
    }

    /// Clears every sound assignment in the selected preset. Slot titles are untouched.
    func resetAll() {
        guard let selectedIndex else { return }
        for i in presets[selectedIndex].slots.indices {
            presets[selectedIndex].slots[i].assignment = nil
        }
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.writeToDisk()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func writeToDisk() {
        let state = PersistedState(presets: presets, selectedPresetID: selectedPresetID)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func flush() {
        saveWorkItem?.cancel()
        writeToDisk()
    }

    private static func load(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }
}
