import Foundation

/// A sound assigned to one of the fixed hotkey bar slots. Stores just enough to play the sound
/// (and to track its play state) independent of whichever playlist it was dragged from.
struct HotkeyAssignment: Codable, Equatable {
    var soundID: UUID
    var name: String
    var fileName: String

    init(sound: Sound) {
        soundID = sound.id
        name = sound.name
        fileName = sound.fileName
    }

    /// Rebuilds a lightweight Sound value suitable for AudioPlayerManager, which only keys off `id`.
    var asSound: Sound {
        Sound(id: soundID, name: name, fileName: fileName)
    }
}
