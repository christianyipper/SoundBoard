import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var rosterStore: RosterStore
    @EnvironmentObject private var shortcutManager: ShortcutManager

    @State private var availableInputDevices: [AudioInputDevice] = []
    /// The shot hotkey waiting for a key press, if any.
    @State private var recordingShotAction: ShotHotkeys.Action?
    @State private var shotHotkeyMessage: String?

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

            Section("Gamesheet Shot Hotkeys") {
                ForEach(ShotHotkeys.actions) { action in
                    LabeledContent(action.label) {
                        Button {
                            recordShotHotkey(for: action)
                        } label: {
                            Text(recordingShotAction == action
                                ? "Press a key…"
                                : SoundShortcut.keyName(for: settingsStore.settings.shotHotkeys[action]))
                                .frame(minWidth: 90)
                        }
                        .buttonStyle(.bordered)
                        .pointerCursor()
                    }
                }

                Text(shotHotkeyMessage ?? "Click a key, then press the new key. Escape cancels. Picking a key another shot hotkey uses swaps the two.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(shotHotkeyMessage == nil ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.dangerGlow)

                Button("Reset to A / Z / D / C") {
                    shortcutManager.cancelRecording()
                    recordingShotAction = nil
                    shotHotkeyMessage = nil
                    settingsStore.settings.shotHotkeys = .default
                }
                .buttonStyle(.borderless)
                .pointerCursor()
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
        .onDisappear {
            shortcutManager.cancelRecording()
            recordingShotAction = nil
        }
    }

    private func recordShotHotkey(for action: ShotHotkeys.Action) {
        recordingShotAction = action
        shotHotkeyMessage = nil
        shortcutManager.beginRecording { shortcut in
            DispatchQueue.main.async {
                recordingShotAction = nil
                guard shortcut.keyCode != ShortcutManager.escapeKeyCode else { return }
                if let reason = ShortcutManager.reservedUse(ofKeyCode: shortcut.keyCode) {
                    shotHotkeyMessage = reason
                    return
                }
                // Shot keys only fire without modifiers, so only the key itself is kept.
                settingsStore.settings.shotHotkeys.assign(shortcut.keyCode, to: action)
            }
        }
    }

    private func refreshInputDevices() {
        availableInputDevices = MicrophoneManager.availableInputDevices()
    }
}
