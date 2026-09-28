import Foundation

struct Playlist: Identifiable, Codable, Equatable {
    /// Display name of a playlist's first, always-present tab.
    static let defaultTabName = "All"

    var id: UUID
    var name: String
    var tabs: [SoundTab]
    /// Whether `PlaylistStore.selectRootFolder` has already been used on this playlist. A
    /// playlist may only be pointed at one on-disk parent folder, so the picker is offered once
    /// and then replaced by a "change" affordance rather than being clickable indefinitely.
    var rootFolderSelected: Bool

    init(id: UUID = UUID(), name: String, sounds: [Sound] = []) {
        self.id = id
        self.name = name
        self.tabs = [SoundTab(name: Self.defaultTabName, sounds: sounds)]
        self.rootFolderSelected = false
    }

    /// Convenience accessor for the default (first) tab's sounds, for call sites that don't care about tabs.
    var sounds: [Sound] {
        get { tabs.first?.sounds ?? [] }
        set {
            guard !tabs.isEmpty else {
                tabs = [SoundTab(name: Self.defaultTabName, sounds: newValue)]
                return
            }
            tabs[0].sounds = newValue
        }
    }

    /// All sounds across every tab, e.g. for playlist-wide counts and shortcut lookups.
    var allSounds: [Sound] {
        tabs.flatMap(\.sounds)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, tabs, sounds, rootFolderSelected
    }

    // Custom Codable so playlists saved before tabs existed (which only had a `sounds` array)
    // still load correctly, migrated into a single default tab, and so playlists saved before
    // rootFolderSelected existed default to false (picker still offered).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rootFolderSelected = try container.decodeIfPresent(Bool.self, forKey: .rootFolderSelected) ?? false
        if let tabs = try container.decodeIfPresent([SoundTab].self, forKey: .tabs), !tabs.isEmpty {
            self.tabs = tabs
        } else {
            let sounds = try container.decodeIfPresent([Sound].self, forKey: .sounds) ?? []
            self.tabs = [SoundTab(name: Self.defaultTabName, sounds: sounds)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(rootFolderSelected, forKey: .rootFolderSelected)
    }
}
