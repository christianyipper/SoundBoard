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
    /// Whether the fixed "V" mic hotkey toggles mic passthrough on/off, or holds it live only
    /// while held down (push to talk).
    var microphoneHotkeyMode: MicrophoneHotkeyMode
    /// Whether every sound is automatically gain-matched to the same perceived loudness, so the
    /// master volume behaves consistently regardless of how loud each file was recorded.
    var normalizeLoudness: Bool
    /// Mic passthrough volume, 0...1, applied to the microphone engine's output.
    var microphoneVolume: Float

    static let `default` = AppSettings(
        fadeOutDuration: 0,
        volume: 1.0,
        reverbAmount: 0,
        microphoneDeviceID: nil,
        crossFadeDuration: 0
    )

    private enum CodingKeys: String, CodingKey {
        case fadeOutDuration, volume, reverbAmount, microphoneDeviceID, crossFadeDuration, appearance, microphoneHotkeyMode, normalizeLoudness, microphoneVolume
    }

    init(
        fadeOutDuration: Double,
        volume: Float,
        reverbAmount: Float,
        microphoneDeviceID: String?,
        crossFadeDuration: Double,
        appearance: AppAppearance = .system,
        microphoneHotkeyMode: MicrophoneHotkeyMode = .toggle,
        normalizeLoudness: Bool = true,
        microphoneVolume: Float = 1.0
    ) {
        self.fadeOutDuration = fadeOutDuration
        self.volume = volume
        self.reverbAmount = reverbAmount
        self.microphoneDeviceID = microphoneDeviceID
        self.crossFadeDuration = crossFadeDuration
        self.appearance = appearance
        self.microphoneHotkeyMode = microphoneHotkeyMode
        self.normalizeLoudness = normalizeLoudness
        self.microphoneVolume = microphoneVolume
    }

    // Custom Codable so settings saved before crossFadeDuration/appearance/microphoneHotkeyMode/
    // normalizeLoudness/microphoneVolume existed still load correctly, defaulting new fields instead of failing decode entirely and
    // silently resetting every other saved setting back to .default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fadeOutDuration = try container.decode(Double.self, forKey: .fadeOutDuration)
        volume = try container.decode(Float.self, forKey: .volume)
        reverbAmount = try container.decode(Float.self, forKey: .reverbAmount)
        microphoneDeviceID = try container.decodeIfPresent(String.self, forKey: .microphoneDeviceID)
        crossFadeDuration = try container.decodeIfPresent(Double.self, forKey: .crossFadeDuration) ?? 0
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        microphoneHotkeyMode = try container.decodeIfPresent(MicrophoneHotkeyMode.self, forKey: .microphoneHotkeyMode) ?? .toggle
        normalizeLoudness = try container.decodeIfPresent(Bool.self, forKey: .normalizeLoudness) ?? true
        microphoneVolume = try container.decodeIfPresent(Float.self, forKey: .microphoneVolume) ?? 1.0
    }
}

/// How the fixed "V" hotkey controls mic passthrough, selectable in Settings.
enum MicrophoneHotkeyMode: String, Codable, CaseIterable, Identifiable {
    case toggle, pushToTalk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggle: return "Toggle"
        case .pushToTalk: return "Push to Talk"
        }
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
