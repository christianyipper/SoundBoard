import SwiftUI

/// Which view fills the main area below the hotkey bar and music player.
enum MainMode: String, CaseIterable, Identifiable {
    case files
    case gamesheet
    case call

    var id: Self { self }

    var title: String {
        switch self {
        case .files: "Files"
        case .gamesheet: "Live View"
        case .call: "Gamesheet"
        }
    }

    var icon: String {
        switch self {
        case .files: "folder"
        case .gamesheet: "list.clipboard"
        case .call: "megaphone"
        }
    }

    /// The hotkey preset shown (and played by keys 1-0) while this view is up.
    var hotkeyPresetName: String {
        switch self {
        case .files, .gamesheet: HotkeyBarStore.defaultPresetName
        case .call: HotkeyBarStore.goalCallPresetName
        }
    }
}

/// Hotkey rack: a top bar (preset tabs, Files/Gamesheet/Call toggle, and the "- Key"/"+ Key"
/// buttons) above a single row of the selected preset's hotkey slots (keys 1-9 then 0). Drag any sound tile from the grid
/// onto a slot to assign it; press the matching key, or click the slot, to toggle play/pause. A
/// slot's title is editable via its context menu.
struct HotkeyBarView: View {
    @EnvironmentObject private var hotkeyBarStore: HotkeyBarStore

    @Binding var mode: MainMode

    var body: some View {
        VStack(spacing: 10) {
            HotkeyTopBar(mode: $mode)

            HStack(spacing: 10) {
                ForEach(hotkeyBarStore.visibleKeySlots) { keySlot in
                    HotkeySlotView(keySlot: keySlot)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .background(DesignSystem.Colors.background)
    }
}

/// Bar across the top of the window: the Default/Goal Call preset tabs on the left, then the
/// Files/Gamesheet/Call toggle and the buttons that add or remove a hotkey in the selected preset
/// on the right. Switching views also switches preset (see ContentView: Files and Gamesheet → Default,
/// Call → Goal Call); the tabs can still switch presets by hand.
private struct HotkeyTopBar: View {
    @EnvironmentObject private var hotkeyBarStore: HotkeyBarStore

    @Binding var mode: MainMode

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(hotkeyBarStore.presets) { preset in
                TabStripButton(
                    id: preset.id,
                    icon: "keyboard.fill",
                    title: preset.name,
                    isActive: preset.id == hotkeyBarStore.selectedPresetID,
                    canClose: false,
                    onSelect: { hotkeyBarStore.selectPreset(preset.id) },
                    onClose: {},
                    onMove: { _, _ in }
                )
            }

            Spacer(minLength: 12)

            HStack(spacing: 16) {
                SegmentedTabs(selection: $mode, options: MainMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.icon)
                }
                .fixedSize()
                .help("Files and Gamesheet switch hotkeys to Default; Call switches them to Goal Call")

                HStack(spacing: 6) {
                    KeyCountButton(title: "- Key", isEnabled: hotkeyBarStore.canRemoveKey, action: hotkeyBarStore.removeLastKey)
                        .help("Hide the last hotkey (its sound is kept for when you add it back)")
                    KeyCountButton(title: "+ Key", isEnabled: hotkeyBarStore.canAddKey, action: hotkeyBarStore.addKey)
                        .help("Add the next hotkey, up to key 0")
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .background(DesignSystem.Colors.headerBackground)
        .environment(\.onDarkHeader, true)
    }
}

/// "- Key" / "+ Key" button beside the view toggle; only used in the dark purple header.
private struct KeyCountButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignSystem.Colors.headerText)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                .fill(Color.white.opacity(isHovering && isEnabled ? 0.14 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .pointerCursor()
    }
}
