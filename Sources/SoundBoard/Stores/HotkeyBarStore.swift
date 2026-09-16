import Foundation

/// Owns the fixed 12-slot hotkey rack (number keys 1-9 and 0, plus "P" and "V") shown above the
/// sound grid. Slot positions and titles are fixed; only the assigned sound (via drag and drop)
/// varies, and is persisted independently of any single playlist.
final class HotkeyBarStore: ObservableObject {
    struct Slot: Identifiable {
        /// A slot either plays an assigned sound, or (the fixed "Microphone" slot) toggles live mic passthrough.
        enum Kind {
            case sound
            case microphone
        }

        let index: Int
        let keyCode: UInt16
        let displayKey: String
        let title: String
        var kind: Kind = .sound
        var id: Int { index }
    }

    /// Row 1: keys 1-4. Row 2: keys 5-8. Row 3: keys 9, 0, P, V. Key codes are the physical ANSI keyboard codes.
    static let slots: [Slot] = [
        Slot(index: 0, keyCode: 18, displayKey: "1", title: "Home Goal"),
        Slot(index: 1, keyCode: 19, displayKey: "2", title: "Away Goal"),
        Slot(index: 2, keyCode: 20, displayKey: "3", title: "Penalty"),
        Slot(index: 3, keyCode: 21, displayKey: "4", title: "Even Strength"),
        Slot(index: 4, keyCode: 23, displayKey: "5", title: "Scorer"),
        Slot(index: 5, keyCode: 22, displayKey: "6", title: "Assist 1"),
        Slot(index: 6, keyCode: 26, displayKey: "7", title: "Assist 2"),
        Slot(index: 7, keyCode: 28, displayKey: "8", title: "End of Goal"),
        Slot(index: 8, keyCode: 25, displayKey: "9", title: "End of Period"),
        Slot(index: 9, keyCode: 29, displayKey: "0", title: "Last Minute"),
        Slot(index: 10, keyCode: 35, displayKey: "p", title: "Commissioner"),
        Slot(index: 11, keyCode: 9, displayKey: "v", title: "Microphone", kind: .microphone)
    ]

    @Published private(set) var assignments: [Int: HotkeyAssignment] = [:]

    private let fileURL: URL
    private var saveWorkItem: DispatchWorkItem?

    init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("hotkeys.json")
        assignments = Self.load(from: fileURL) ?? [:]
    }

    func assignment(at index: Int) -> HotkeyAssignment? {
        assignments[index]
    }

    func slot(forKeyCode keyCode: UInt16) -> Slot? {
        Self.slots.first { $0.keyCode == keyCode }
    }

    /// The slot (if any) a given sound is currently assigned to, e.g. for badging that sound's
    /// tile in the grid with its hotkey number.
    func slot(forSoundID soundID: UUID) -> Slot? {
        guard let index = assignments.first(where: { $0.value.soundID == soundID })?.key else { return nil }
        return Self.slots.first { $0.index == index }
    }

    func assign(_ sound: Sound, toSlot index: Int) {
        assignments[index] = HotkeyAssignment(sound: sound)
        scheduleSave()
    }

    func clear(slot index: Int) {
        assignments.removeValue(forKey: index)
        scheduleSave()
    }

    func resetAll() {
        assignments.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.writeToDisk()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func writeToDisk() {
        guard let data = try? JSONEncoder().encode(assignments) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func flush() {
        saveWorkItem?.cancel()
        writeToDisk()
    }

    private static func load(from url: URL) -> [Int: HotkeyAssignment]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Int: HotkeyAssignment].self, from: data)
    }
}
