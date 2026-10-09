import Foundation

/// One of the two fixed hotkey racks ("Default" and "Goal Call") — its own titles and its own
/// sound assignments — selectable via the preset tabs above the hotkey bar. `slots` always has
/// exactly `HotkeyBarStore.keySlots.count` entries, index-aligned with the fixed physical key
/// layout. Only the first `keyCount` keys are shown (and respond to key presses); the slots past
/// it keep their titles and sounds for when keys are added back.
struct HotkeyPreset: Identifiable, Codable, Equatable {
    struct Slot: Codable, Equatable {
        var title: String
        var assignment: HotkeyAssignment?
    }

    var id: UUID
    var name: String
    var slots: [Slot]
    var keyCount: Int

    init(id: UUID = UUID(), name: String, slots: [Slot], keyCount: Int = HotkeyBarStore.defaultKeyCount) {
        self.id = id
        self.name = name
        self.slots = slots
        self.keyCount = keyCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, slots, keyCount
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case showsExtendedKeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slots = try container.decode([Slot].self, forKey: .slots)
        if let keyCount = try container.decodeIfPresent(Int.self, forKey: .keyCount) {
            self.keyCount = keyCount
        } else {
            // Saves from when keys 6-0 were an on/off switch: on means all ten keys; off (or
            // older saves without the switch) means keys 1-5, with 6-0's sounds kept.
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let showsExtendedKeys = try legacy.decodeIfPresent(Bool.self, forKey: .showsExtendedKeys) ?? false
            keyCount = showsExtendedKeys ? slots.count : HotkeyBarStore.defaultKeyCount
        }
    }
}
