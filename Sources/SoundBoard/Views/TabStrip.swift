import SwiftUI

/// Windows Explorer-style tab, shared by every tab strip in the app (the sound grid's browsing
/// tabs and the hotkey preset strip) so they all look and behave identically: same icon/text
/// sizing, same rounded-top shape and active underline, same close-button behavior. Pass extra
/// context-menu items (e.g. "Rename…") via `extraMenuItems`; a "Close" item is added for you
/// whenever `canClose` is true. Click-and-drag one tab onto another to reorder them; the caller
/// (which owns the underlying array) does the actual reordering in `onMove`.
struct TabStripButton<ExtraMenuItems: View>: View {
    let id: UUID
    let icon: String
    let title: String
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMove: (_ draggedID: UUID, _ targetID: UUID) -> Void
    @ViewBuilder var extraMenuItems: () -> ExtraMenuItems

    @State private var isHovering = false
    @State private var isDropTargeted = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(DesignSystem.Colors.accentPrimary)

                Text(title)
                    .font(.system(size: 14, weight: isActive ? .bold : .medium, design: .rounded))
                    .lineLimit(1)

                if canClose {
                    // Pins the close button to the tab's right edge regardless of title length,
                    // instead of it trailing right after the text.
                    Spacer(minLength: 8)
                    TabStripCloseButton(isVisible: isHovering || isActive, action: onClose)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minWidth: 150, maxWidth: 240, alignment: .leading)
            // Without this, only the icon/text/close-button's own drawn pixels register taps —
            // the rest of the tab's padded width (e.g. empty trailing space on a short title)
            // would be dead space. This makes the whole tab clickable.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .fill(isActive ? DesignSystem.Colors.background : (isHovering ? DesignSystem.Colors.surfaceTint.opacity(0.7) : DesignSystem.Colors.surfaceTint.opacity(0.3)))
        )
        .overlay(alignment: .bottom) {
            if isActive {
                Rectangle()
                    .fill(DesignSystem.Colors.accentPrimary)
                    .frame(height: 2)
            }
        }
        .overlay {
            if isDropTargeted {
                UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                    .strokeBorder(DesignSystem.Colors.accentPrimary, lineWidth: 2)
            }
        }
        .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
        .onHover { isHovering = $0 }
        .pointerCursor()
        .contextMenu {
            extraMenuItems()
            if canClose {
                Button("Close", role: .destructive, action: onClose)
            }
        }
        .onDrag {
            NSItemProvider(object: id.uuidString as NSString)
        }
        .onDrop(of: [.text], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let string = object as? String, let draggedID = UUID(uuidString: string) else { return }
                DispatchQueue.main.async {
                    onMove(draggedID, id)
                }
            }
            return true
        }
    }
}

extension TabStripButton where ExtraMenuItems == EmptyView {
    init(id: UUID, icon: String, title: String, isActive: Bool, canClose: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void, onMove: @escaping (UUID, UUID) -> Void) {
        self.init(id: id, icon: icon, title: title, isActive: isActive, canClose: canClose, onSelect: onSelect, onClose: onClose, onMove: onMove) {
            EmptyView()
        }
    }
}

/// A tab's close "×" — invisible until the tab is hovered/active, and separately highlighted
/// with its own background circle when the pointer is directly over it, the way browser and
/// Explorer tab close buttons behave.
private struct TabStripCloseButton: View {
    let isVisible: Bool
    let action: () -> Void

    @State private var isHoveringCloseButton = false

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(isHoveringCloseButton ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
            .frame(width: 18, height: 18)
            .background(
                Circle().fill(isHoveringCloseButton ? DesignSystem.Colors.dangerGlow.opacity(0.3) : Color.clear)
            )
            .contentShape(Rectangle())
            .opacity(isVisible ? 1 : 0)
            .onTapGesture(perform: action)
            .onHover { isHoveringCloseButton = $0 }
            .pointerCursor()
    }
}

/// Square "+" button that sits directly beside the last tab in any tab strip, matching the
/// add-tab button in Windows Explorer's tab strip.
struct TabStripAddButton: View {
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignSystem.Colors.textPrimary)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                .fill(isHovering ? DesignSystem.Colors.surfaceTint.opacity(0.8) : DesignSystem.Colors.surfaceTint.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.small)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .help(help)
        .pointerCursor()
    }
}
