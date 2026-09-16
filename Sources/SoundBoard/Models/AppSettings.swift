import Foundation

/// User-configurable playback settings, persisted independently of playlists/hotkeys.
struct AppSettings: Codable, Equatable {
    /// Seconds to fade a sound's volume to zero before pausing it. 0 pauses instantly.
    var fadeOutDuration: Double
    /// Master playback volume, 0...1.
    var volume: Float
    /// Reverb wet/dry mix, 0...100 (matches AVAudioUnitReverb.wetDryMix). 0 disables reverb.
    var reverbAmount: Float
    /// CoreAudio device UID of the selected microphone input for mic passthrough.
    /// nil means "use the system default input device".
    var microphoneDeviceID: String?
    /// Seconds to crossfade between the music player's shuffled tracks — the outgoing track
    /// fades out while the next one simultaneously fades in. 0 switches tracks instantly.
    var crossFadeDuration: Double
    /// Light/dark/system appearance override for the app's windows.
    var appearance: AppAppearance

    static let `default` = AppSettings(
        fadeOutDuration: 0,
        volume: 1.0,
        reverbAmount: 0,
        microphoneDeviceID: nil,
        crossFadeDuration: 0
    )

    private enum CodingKeys: String, CodingKey {
        case fadeOutDuration, volume, reverbAmount, microphoneDeviceID, crossFadeDuration, appearance
    }

    init(
        fadeOutDuration: Double,
        volume: Float,
        reverbAmount: Float,
        microphoneDeviceID: String?,
        crossFadeDuration: Double,
        appearance: AppAppearance = .system
    ) {
        self.fadeOutDuration = fadeOutDuration
        self.volume = volume
        self.reverbAmount = reverbAmount
        self.microphoneDeviceID = microphoneDeviceID
        self.crossFadeDuration = crossFadeDuration
        self.appearance = appearance
    }

    // Custom Codable so settings saved before crossFadeDuration/appearance existed still load
    // correctly, defaulting new fields instead of failing decode entirely and silently resetting
    // every other saved setting back to .default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fadeOutDuration = try container.decode(Double.self, forKey: .fadeOutDuration)
        volume = try container.decode(Float.self, forKey: .volume)
        reverbAmount = try container.decode(Float.self, forKey: .reverbAmount)
        microphoneDeviceID = try container.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        crossFadeDuration = try container.decodeIfPresent(Double.self, forKey: .crossFadeDuration) ?? 0
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
    }
}

/// Light/dark/system appearance override, selectable in Settings.
enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
