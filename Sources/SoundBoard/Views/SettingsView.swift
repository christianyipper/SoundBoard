import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var rosterStore: RosterStore

    @State private var availableInputDevices: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("Rosters") {
                LabeledContent("Scraper last updated") {
                    if let league = rosterStore.league {
                        Text(league.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text(rosterStore.isRefreshing ? "Downloading…" : "No rosters downloaded")
                    }
                }
            }

            Section("Appearance") {
                LabeledContent("Theme") {
                    SegmentedTabs(selection: $settingsStore.settings.appearance, options: AppAppearance.allCases) { appearance in
                        Text(appearance.label)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fade out on pause: \(settingsStore.settings.fadeOutDuration, specifier: "%.1f")s")
                    Slider(value: $settingsStore.settings.fadeOutDuration, in: 0...5, step: 0.1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Volume: \(Int(settingsStore.settings.volume * 100))%")
                    Slider(value: $settingsStore.settings.volume, in: 0...1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Mic Volume: \(Int(settingsStore.settings.microphoneVolume * 100))%")
                    Slider(value: $settingsStore.settings.microphoneVolume, in: 0...1)
                }

                Toggle("Match loudness across sounds", isOn: $settingsStore.settings.normalizeLoudness)

                Text("Automatically evens out sounds recorded at different levels so one volume setting works for all of them.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Reverb: \(Int(settingsStore.settings.reverbAmount))%")
                    Slider(value: $settingsStore.settings.reverbAmount, in: 0...100)
                }
            }

            Section("Music Player") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cross-fade between tracks: \(settingsStore.settings.crossFadeDuration, specifier: "%.1f")s")
                    Slider(value: $settingsStore.settings.crossFadeDuration, in: 0...10, step: 0.5)
                }

                Text("Overlaps the end of one shuffled track with the start of the next instead of stopping in between. 0 switches instantly.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Section("Microphone") {
                Picker("Input Device", selection: $settingsStore.settings.microphoneDeviceID) {
                    Text("System Default").tag(String?.none)
                    ForEach(availableInputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }

                HStack {
                    Text("Connect a USB or Bluetooth mic in macOS Sound settings, then pick it here.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Spacer()
                    Button("Refresh") {
                        refreshInputDevices()
                    }
                    .buttonStyle(.borderless)
                    .pointerCursor()
                }

                LabeledContent("Hotkey Mode") {
                    SegmentedTabs(selection: $settingsStore.settings.microphoneHotkeyMode, options: MicrophoneHotkeyMode.allCases) { mode in
                        Text(mode.label)
                    }
                }

                Text(settingsStore.settings.microphoneHotkeyMode == .pushToTalk
                    ? "Hold V to talk; release to stop."
                    : "Press V to toggle the mic on/off.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            refreshInputDevices()
        }
    }

    private func refreshInputDevices() {
        availableInputDevices = MicrophoneManager.availableInputDevices()
    }
}
