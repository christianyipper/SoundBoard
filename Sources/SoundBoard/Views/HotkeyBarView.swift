import SwiftUI

/// Hotkey rack: a strip of preset tabs (each an independently named rack with its own slot
/// titles and sound assignments) above a 2-row grid of slots for keys 1-5 (top row) and 6-0
/// (bottom row). Drag any sound tile from the grid onto a slot to assign it; press the matching
/// key, or click the slot, to toggle play/pause. A slot's title is editable via its context menu.
/// Styled to match the sound grid's file-browser look: a flush flat dark panel with the tab
/// strip's own lighter background up top, no outer rounded card or border.
struct HotkeyBarView: View {
    @EnvironmentObject private var hotkeyBarStore: HotkeyBarStore

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    private var topRow: [HotkeyBarStore.KeySlot] { Array(HotkeyBarStore.keySlots[0..<5]) }
    private var bottomRow: [HotkeyBarStore.KeySlot] { Array(HotkeyBarStore.keySlots[5..<10]) }

    var body: some View {
        VStack(spacing: 10) {
            HotkeyPresetTabStrip()

            VStack(spacing: 10) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(topRow) { keySlot in
                        HotkeySlotView(keySlot: keySlot)
                    }
                }

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(bottomRow) { keySlot in
                        HotkeySlotView(keySlot: keySlot)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .background(DesignSystem.Colors.background)
    }
}

/// Row of preset tabs: click to switch, right-click to rename/delete, trailing "+" to create a
/// new preset. Mirrors the sound grid's Explorer-style tab strip look and feel, including the
/// lighter background strip that sits directly behind the tabs.
private struct HotkeyPresetTabStrip: View {
    @EnvironmentObject private var hotkeyBarStore: HotkeyBarStore

    @State private var isAddingPreset = false
    @State private var newPresetName = ""
    @State private var renamingPresetID: UUID?
    @State private var renameText = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(hotkeyBarStore.presets) { preset in
                        TabStripButton(
                            id: preset.id,
                            icon: "keyboard.fill",
                            title: preset.name,
                            isActive: preset.id == hotkeyBarStore.selectedPresetID,
                            canClose: hotkeyBarStore.presets.count > 1,
                            onSelect: { hotkeyBarStore.selectPreset(preset.id) },
                            onClose: { hotkeyBarStore.deletePreset(preset.id) },
                            onMove: { draggedID, targetID in hotkeyBarStore.movePreset(draggedID, before: targetID) }
                        ) {
                            Button("Rename…") {
                                renameText = preset.name
                                renamingPresetID = preset.id
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Hugs its content width instead of expanding to fill the HStack, so the add-tab
            // button lands immediately beside the last tab rather than floating off to the right.
            .fixedSize(horizontal: true, vertical: false)

            TabStripAddButton(help: "Create a new hotkey preset") {
                newPresetName = ""
                isAddingPreset = true
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 28)
        .background(DesignSystem.Colors.surfaceTint.opacity(0.35))
        .alert("New Preset", isPresented: $isAddingPreset) {
            TextField("Preset Name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createPreset() }
        }
        .alert("Rename Preset", isPresented: Binding(
            get: { renamingPresetID != nil },
            set: { if !$0 { renamingPresetID = nil } }
        )) {
            TextField("Preset Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { commitRename() }
        }
    }

    private func createPreset() {
        let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hotkeyBarStore.createPreset(name: trimmed)
    }

    private func commitRename() {
        guard let id = renamingPresetID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hotkeyBarStore.renamePreset(id, to: trimmed)
        renamingPresetID = nil
    }
}
