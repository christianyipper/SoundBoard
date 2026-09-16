import Foundation

/// A system audio input device (built-in, USB, or Bluetooth microphone) available for mic passthrough.
struct AudioInputDevice: Identifiable, Equatable, Hashable {
    /// CoreAudio device UID. Stable for a given physical device across reconnects/reboots,
    /// which is why it (not the transient AudioDeviceID) is what gets persisted in settings.
    let uid: String
    let name: String
    var id: String { uid }
}
