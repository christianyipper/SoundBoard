import SwiftUI

struct HotkeySlotView: View {
    @EnvironmentObject private var hotkeyBarStore: HotkeyBarStore
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var audioPlayerManager: AudioPlayerManager
    @EnvironmentObject private var microphoneManager: MicrophoneManager

    let slot: HotkeyBarStore.Slot

    @State private var isDropTargeted = false
    @State private var isPulsing = false

    private var isMicSlot: Bool { slot.kind == .microphone }

    private var assignment: HotkeyAssignment? {
        hotkeyBarStore.assignment(at: slot.index)
    }

    private var state: PlayState {
        guard let assignment else { return .idle }
        return audioPlayerManager.state(for: assignment.soundID)
    }

    /// Whether this slot should currently show as "lit": playing for a sound slot, live for the mic slot.
    private var isActive: Bool {
        isMicSlot ? microphoneManager.isLive : state == .playing
    }

    private var subtitle: String {
        isMicSlot ? (microphoneManager.isLive ? "On" : "Off") : (assignment?.name ?? "Drop Sound")
    }

    private var tintColor: Color {
        if isMicSlot { return microphoneManager.isLive ? DesignSystem.Colors.dangerGlow : .clear }
        return state.tileColor
    }

    private var foregroundColor: Color {
        if isMicSlot { return microphoneManager.isLive ? DesignSystem.Colors.onAccent : DesignSystem.Colors.textPrimary }
        return state.foregroundColor
    }

    private var borderColor: Color {
        if isDropTargeted { return DesignSystem.Colors.accentPrimary }
        if isMicSlot { return microphoneManager.isLive ? DesignSystem.Colors.dangerGlow : DesignSystem.Colors.border }
        return state == .playing ? DesignSystem.Colors.successGlow : DesignSystem.Colors.border
    }

    private var glowColor: Color {
        isMicSlot ? DesignSystem.Colors.dangerGlow : (state.glowColor ?? .clear)
    }

    private var pulseAnimation: Animation? {
        isActive ? DesignSystem.Motion.gentlePulse : DesignSystem.Motion.quickFade
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                Text(slot.title)
                    .font(DesignSystem.Typography.headline)
                    .lineLimit(1)

                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .opacity(!isMicSlot && assignment == nil ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: 72)
            .padding(6)

            Text(slot.displayKey)
                .font(DesignSystem.Typography.keyBadge)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule())
                .padding(4)
        }
        .foregroundStyle(foregroundColor)
        .glassCard(cornerRadius: DesignSystem.Radius.medium, tint: tintColor, borderColor: borderColor, borderWidth: 2)
        .softGlow(glowColor, radius: 10, isActive: isPulsing)
        .pointerCursor()
        .onTapGesture {
            if isMicSlot {
                microphoneManager.toggle()
            } else {
                guard let assignment else { return }
                audioPlayerManager.toggle(
                    assignment.asSound,
                    fileURL: playlistStore.soundsDirectory.appendingPathComponent(assignment.fileName)
                )
            }
        }
        .contextMenu {
            if !isMicSlot, assignment != nil {
                Button("Clear", role: .destructive) {
                    hotkeyBarStore.clear(slot: slot.index)
                }
            }
        }
        // The mic slot isn't sound-assignable, so it registers no droppable types rather than
        // handling drops and rejecting them.
        .onDrop(of: isMicSlot ? [] : [.text], isTargeted: $isDropTargeted) { providers in
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
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String, let soundID = UUID(uuidString: string) else { return }
            DispatchQueue.main.async {
                guard let sound = playlistStore.sound(withID: soundID) else { return }
                hotkeyBarStore.assign(sound, toSlot: slot.index)
            }
        }
    }
}
