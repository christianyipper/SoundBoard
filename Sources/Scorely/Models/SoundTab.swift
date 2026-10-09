import Foundation

/// A named group of sounds within a playlist, shown as its own tab in the sound grid.
/// A playlist's first tab is its default/unnamed-to-the-user "All" tab; additional tabs are
/// created automatically when a dropped or imported folder contains subfolders (see
/// PlaylistStore.importFolderContents).
struct SoundTab: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var sounds: [Sound]

    init(id: UUID = UUID(), name: String, sounds: [Sound] = []) {
        self.id = id
        self.name = name
        self.sounds = sounds
    }
}
