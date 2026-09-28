import Foundation

/// One named, independently-editable rack of hotkey slots — its own titles and its own sound
/// assignments — selectable via the preset tabs above the hotkey bar. `slots` always has exactly
/// `HotkeyBarStore.keySlots.count` entries, index-aligned with the fixed physical key layout.
struct HotkeyPreset: Identifiable, Codable, Equatable {
    struct Slot: Codable, Equatable {
        var title: String
        var assignment: HotkeyAssignment?
    }

    var id: UUID
    var name: String
    var slots: [Slot]

    init(id: UUID = UUID(), name: String, slots: [Slot]) {
        self.id = id
        self.name = name
        self.slots = slots
    }
}
