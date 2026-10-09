import Foundation

struct Sound: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    /// File name relative to the app's Sounds storage directory (see PlaylistStore.soundsDirectory).
    var fileName: String
    var shortcut: SoundShortcut?

    init(id: UUID = UUID(), name: String, fileName: String, shortcut: SoundShortcut? = nil) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.shortcut = shortcut
    }
}
