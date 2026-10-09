import Foundation

/// Owns the hotkey rack (up to ten keys, 1-9 then 0, in one row) shown above the sound grid.
/// There are two fixed presets, each with its own slot titles and sound assignments:
/// "Default" (used by the Files and Gamesheet views) and "Goal Call" (used by the Call view); the
/// main view picks which one is active via `selectPreset(named:)`. Each preset shows its own
/// number of keys (five to start), changed with the header's + / − buttons or by removing a hotkey from its
/// context menu; keys past that count are hidden and inactive. The microphone toggle is a separate, fixed "V" hotkey handled by
/// ShortcutManager directly, independent of any preset.
final class HotkeyBarStore: ObservableObject {
    struct KeySlot: Identifiable {
        let index: Int
        let keyCode: UInt16
        let displayKey: String
        var id: Int { index }
    }

    /// Keys 1-5 (indices 0-4), then keys 6-0 (indices 5-9). Key codes are the physical ANSI keyboard codes.
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

    /// Keys shown in a new preset (1-5); the + button adds up to all of `keySlots`.
    static let defaultKeyCount = 5
    static let minimumKeyCount = 1

    static let defaultPresetName = "Default"
    static let goalCallPresetName = "Goal Call"
    static let presetNames = [defaultPresetName, goalCallPresetName]

    /// Named titles for each preset's first keys; the rest are "Slot N" until renamed.
    private static let presetTitles: [String: [String]] = [
        defaultPresetName: ["Home Goal", "Away Goal", "Penalty", "Even Strength", "End of Period"],
        goalCallPresetName: ["Team Intro", "Goal", "Assist #1", "Assist #2", "Team End"]
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
        let state = Self.load(from: fileURL)
        presets = Self.fixedPresets(from: state?.presets ?? [])
        let hasSelected = state?.selectedPresetID.map { id in presets.contains { $0.id == id } } ?? false
        selectedPresetID = hasSelected ? state?.selectedPresetID : presets.first?.id
    }

    /// Builds the fixed presets, reusing saved ones by name. Older saves without a "Default"
    /// preset (from when presets were user-created) use their first other-named preset for it;
    /// any remaining user-created presets are dropped.
    private static func fixedPresets(from saved: [HotkeyPreset]) -> [HotkeyPreset] {
        let legacy = saved.first { !presetNames.contains($0.name) }
        return presetNames.map { name in
            if let preset = saved.first(where: { $0.name == name }) { return preset }
            if name == defaultPresetName, var legacy {
                legacy.name = name
                return legacy
            }
            return HotkeyPreset(name: name, slots: initialSlots(forPreset: name))
        }
    }

    private static func initialSlots(forPreset name: String) -> [HotkeyPreset.Slot] {
        let titles = presetTitles[name] ?? []
        return blankSlots().enumerated().map { index, slot in
            titles.indices.contains(index) ? HotkeyPreset.Slot(title: titles[index], assignment: nil) : slot
        }
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

    func selectPreset(named name: String) {
        guard let preset = presets.first(where: { $0.name == name }), preset.id != selectedPresetID else { return }
        selectPreset(preset.id)
    }

    // MARK: - Key count

    /// How many keys (from 1 up) the selected preset shows and responds to.
    var keyCount: Int {
        guard let selectedIndex else { return 0 }
        return min(max(presets[selectedIndex].keyCount, Self.minimumKeyCount), Self.keySlots.count)
    }

    /// Keys shown in the selected preset, in key order.
    var visibleKeySlots: [KeySlot] {
        Array(Self.keySlots.prefix(keyCount))
    }

    var canAddKey: Bool { selectedIndex != nil && keyCount < Self.keySlots.count }
    var canRemoveKey: Bool { selectedIndex != nil && keyCount > Self.minimumKeyCount }

    /// Shows the next key. It comes back with whatever title and sound it had when hidden.
    func addKey() {
        guard canAddKey, let selectedIndex else { return }
        presets[selectedIndex].keyCount = keyCount + 1
        scheduleSave()
    }

    /// Hides the last key. Its title and sound are kept, so the + button brings it back as it was.
    func removeLastKey() {
        guard canRemoveKey, let selectedIndex else { return }
        presets[selectedIndex].keyCount = keyCount - 1
        scheduleSave()
    }

    /// Deletes the hotkey at `index` (its title and sound), moving every later slot down one key
    /// so the row closes up, and shows one fewer key.
    func removeKey(at index: Int) {
        guard canRemoveKey, let selectedIndex, index < keyCount else { return }
        var slots = presets[selectedIndex].slots
        slots.remove(at: index)
        slots.append(Self.blankSlots()[slots.count])
        presets[selectedIndex].slots = slots
        presets[selectedIndex].keyCount = keyCount - 1
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

    /// The visible slot for a key press. Keys 6-0 return nil while hidden, so they pass through.
    func slot(forKeyCode keyCode: UInt16) -> KeySlot? {
        visibleKeySlots.first { $0.keyCode == keyCode }
    }

    /// The slot (if any) a given sound is assigned to in the currently selected preset, e.g. for
    /// badging that sound's tile in the grid with its hotkey number.
    func slot(forSoundID soundID: UUID) -> KeySlot? {
        guard let selectedIndex,
              let slotIndex = presets[selectedIndex].slots.firstIndex(where: { $0.assignment?.soundID == soundID })
        else { return nil }
        return visibleKeySlots.first { $0.index == slotIndex }
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
