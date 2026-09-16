import AppKit
import SwiftUI

struct SoundTileView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var audioPlayerManager: AudioPlayerManager
    @EnvironmentObject private var hotkeyBarStore: HotkeyBarStore

    let playlistID: UUID
    let sound: Sound

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isAssigningShortcut = false

    private var state: PlayState {
        audioPlayerManager.state(for: sound.id)
    }

    private var assignedSlot: HotkeyBarStore.Slot? {
        hotkeyBarStore.slot(forSoundID: sound.id)
    }

    private var iconName: String {
        if let assignedSlot {
            return "\(assignedSlot.displayKey).circle.fill"
        }
        return state == .playing ? "pause.circle.fill" : "play.circle.fill"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 32))

            Text(sound.name)
                .font(DesignSystem.Typography.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .help(sound.name)

            if let shortcut = sound.shortcut {
                Text(shortcut.displayString)
                    .font(DesignSystem.Typography.captionBold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(state.foregroundColor)
        .frame(width: 140, height: 110)
        .glassCard(
            cornerRadius: DesignSystem.Radius.medium,
            tint: state.tileColor,
            borderColor: assignedSlot == nil ? DesignSystem.Colors.border : DesignSystem.Colors.accentPrimary,
            borderWidth: 2
        )
        .softGlow(state.glowColor ?? .clear, radius: 10, isActive: state.glowColor != nil)
        // Fades the tint/border/foreground into their active colors instead of snapping instantly.
        .animation(DesignSystem.Motion.quickFade, value: state)
        .pointerCursor()
        .onDrag {
            NSItemProvider(object: sound.id.uuidString as NSString)
        }
        // A plain tap gesture claims mouse-down and blocks onDrag's drag session from ever
        // starting on macOS, so the click handler has to be a simultaneous gesture instead.
        .simultaneousGesture(
            TapGesture().onEnded {
                audioPlayerManager.toggle(sound, fileURL: playlistStore.url(for: sound))
            }
        )
        .contextMenu {
            Button("Rename…") {
                renameText = sound.name
                isRenaming = true
            }
            Button("Assign Shortcut…") {
                isAssigningShortcut = true
            }
            if sound.shortcut != nil {
                Button("Clear Shortcut") {
                    playlistStore.setShortcut(nil, forSound: sound.id, inPlaylist: playlistID)
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([playlistStore.url(for: sound)])
            }
            Divider()
            Button("Remove", role: .destructive) {
                audioPlayerManager.invalidatePlayer(for: sound.id)
                playlistStore.removeSound(sound.id, from: playlistID)
            }
        }
        .alert("Rename Sound", isPresented: $isRenaming) {
            TextField("Sound Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                playlistStore.renameSound(sound.id, in: playlistID, to: trimmed)
            }
        }
        .popover(isPresented: $isAssigningShortcut) {
            ShortcutRecorderView(playlistID: playlistID, sound: sound)
        }
    }
}
