import SwiftUI

struct HotkeySlotView: View {
    @EnvironmentObject private var hotkeyBarStore: HotkeyBarStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var audioPlayerManager: AudioPlayerManager

    let keySlot: HotkeyBarStore.KeySlot

    @State private var isDropTargeted = false
    @State private var isPulsing = false
    @State private var isRenaming = false
    @State private var renameText = ""

    private var title: String {
        hotkeyBarStore.title(at: keySlot.index)
    }

    private var assignment: HotkeyAssignment? {
        hotkeyBarStore.assignment(at: keySlot.index)
    }

    private var state: PlayState {
        guard let assignment else { return .idle }
        return audioPlayerManager.state(for: assignment.soundID)
    }

    private var isActive: Bool { state == .playing }

    private var subtitle: String { assignment?.name ?? "Drop Sound" }

    private var borderColor: Color {
        if isDropTargeted { return DesignSystem.Colors.accentPrimary }
        return state == .playing ? DesignSystem.Colors.successGlow : DesignSystem.Colors.border
    }

    private var pulseAnimation: Animation? {
        isActive ? DesignSystem.Motion.gentlePulse : DesignSystem.Motion.quickFade
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                Text(title)
                    .font(DesignSystem.Typography.headline)
                    .lineLimit(1)

                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .opacity(assignment == nil ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(6)

            Text(keySlot.displayKey)
                .font(DesignSystem.Typography.keyBadge)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isActive ? DesignSystem.Colors.successGlow.opacity(0.6) : DesignSystem.Colors.textSecondary.opacity(0.25))
                )
                .padding(.top, 8)
                .padding(.leading, 8)
        }
        .foregroundStyle(state.foregroundColor)
        .glassCard(cornerRadius: DesignSystem.Radius.medium, tint: state.tileColor, borderColor: borderColor, borderWidth: 2)
        .softGlow(state.glowColor ?? .clear, radius: 10, isActive: isPulsing)
        .pointerCursor()
        .onTapGesture {
            guard let assignment else { return }
            audioPlayerManager.toggle(
                assignment.asSound,
                fileURL: playlistStore.soundsDirectory.appendingPathComponent(assignment.fileName)
            )
        }
        .contextMenu {
            Button("Rename Slot…") {
                renameText = title
                isRenaming = true
            }
            if assignment != nil {
                Button("Clear Sound") {
                    hotkeyBarStore.clear(slot: keySlot.index)
                }
            }
            Divider()
            Button("Remove Hotkey", role: .destructive) {
                hotkeyBarStore.removeKey(at: keySlot.index)
            }
            .disabled(!hotkeyBarStore.canRemoveKey)
        }
        .onDrop(of: [.text], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .onChange(of: isActive, initial: true) { _, newValue in
            isPulsing = newValue
        }
        // Tying the animation curve itself to `isPulsing` (rather than wrapping each assignment
        // in its own withAnimation) is what actually lets switching to a non-repeating curve here
        // cancel the repeatForever loop above; toggling the state alone doesn't reliably stop it.
        .animation(pulseAnimation, value: isPulsing)
        // Fades the tint/border/foreground into their active colors instead of snapping instantly.
        .animation(DesignSystem.Motion.quickFade, value: isActive)
        .alert("Rename Slot", isPresented: $isRenaming) {
            TextField("Slot Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                hotkeyBarStore.renameSlot(keySlot.index, title: trimmed)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let soundID = UUID(uuidString: string) else { return }
            DispatchQueue.main.async {
                guard let sound = playlistStore.sound(withID: soundID) else { return }
                hotkeyBarStore.assign(sound, toSlot: keySlot.index)
            }
        }
    }
}
