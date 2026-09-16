import SwiftUI

/// Hotkey grid (keys 1-4, then 5-8, then 9/0/P/V) shown above the sound grid. Drag any sound tile
/// from the grid onto a slot to assign it; press the matching key, or click the slot, to toggle
/// play/pause (the "V" slot instead toggles live mic passthrough). Slot titles are fixed; only
/// the assigned sound varies.
struct HotkeyBarView: View {
    private let rows: [(heading: String, slots: [HotkeyBarStore.Slot])] = [
        ("Teams", Array(HotkeyBarStore.slots[0..<4])),
        ("Goals", Array(HotkeyBarStore.slots[4..<8])),
        ("Misc", Array(HotkeyBarStore.slots[8..<12]))
    ]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                Text(rows[rowIndex].heading)
                    .font(DesignSystem.Typography.captionBold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(rows[rowIndex].slots) { slot in
                        HotkeySlotView(slot: slot)
                    }
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: DesignSystem.Radius.large)
        .padding([.horizontal, .top])
    }
}
