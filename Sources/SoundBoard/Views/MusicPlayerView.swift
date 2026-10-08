import SwiftUI

/// Folder-driven background music player shown below the hotkey bar, styled like a Spotify
/// "now playing" bar: folder picker + current track on the left, transport controls and
/// timeline centered, mic toggle and volume on the right. The picker lists the folders of the
/// sound library every game shares; press Space (or the center Play button) to play through the
/// selected folder's sounds. Pressing Space again stops the current track and cues the next one
/// for next time, rather than resuming it; a track that finishes on its own does the same,
/// cueing the next one without playing it. Back/Skip jump to the previous/next track in the play
/// order, preserving play/pause state: they play immediately if music was already playing, or
/// just cue the new track (silent) if it was paused. The shuffle button toggles between a
/// shuffled order and folder order, carrying on from the current track either way.
struct MusicPlayerView: View {
    /// The shared sound library, whose folders the picker offers.
    let playlist: Playlist

    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var musicPlayerStore: MusicPlayerStore
    @EnvironmentObject private var microphoneManager: MicrophoneManager
    @EnvironmentObject private var settingsStore: SettingsStore

    private var selectedFolder: SoundTab? {
        musicPlayerStore.selectedFolderID.flatMap(playlistStore.folder(withID:))
    }

    /// The library's folders: its root (named after the library, as in the sound grid's
    /// breadcrumb) when it holds loose sounds, then each imported folder.
    private var folderOptions: [(id: UUID, name: String)] {
        playlist.tabs.enumerated().compactMap { index, folder in
            if index == 0 {
                return folder.sounds.isEmpty ? nil : (folder.id, playlist.name)
            }
            return (folder.id, folder.name)
        }
    }

    private var trackLabel: String {
        guard selectedFolder != nil else { return "No Folder Selected" }
        guard let sound = musicPlayerStore.currentSound else { return "No Sounds in Folder" }
        return sound.name
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            leftSection
                .frame(maxWidth: .infinity, alignment: .leading)

            centerSection
                .frame(maxWidth: 480)

            rightSection
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(DesignSystem.Colors.surfaceTint.opacity(0.35))
    }

    // MARK: - Left: folder selector + current track

    private var leftSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Folder", selection: $musicPlayerStore.selectedFolderID) {
                Text("Select Folder").tag(UUID?.none)
                ForEach(folderOptions, id: \.id) { option in
                    Text(option.name).tag(Optional(option.id))
                }
                // Keep the selected folder listed even once it's no longer offered (e.g. the
                // root after its loose sounds are removed), so the picker doesn't blank mid-song.
                if let selectedFolder, !folderOptions.contains(where: { $0.id == selectedFolder.id }) {
                    Divider()
                    Text(selectedFolder.name).tag(Optional(selectedFolder.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200, alignment: .leading)
            .pointerCursor()

            HStack(spacing: 6) {
                if musicPlayerStore.currentSound != nil {
                    LevelsIndicator(isAnimating: musicPlayerStore.isPlaying)
                }

                Text(trackLabel)
                    .font(DesignSystem.Typography.callout)
                    .foregroundStyle(musicPlayerStore.isPlaying ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Center: transport controls + timeline

    private var centerSection: some View {
        VStack(spacing: 6) {
            ZStack {
                // Back/play/forward as their own centered group, so the shuffle button (which
                // has no counterpart on the left) doesn't throw off the play button's centering.
                HStack(spacing: 20) {
                    TransportButton(systemImage: "backward.fill", size: 15) {
                        musicPlayerStore.skipToPrevious()
                    }
                    .disabled(musicPlayerStore.currentSound == nil)
                    .help("Previous track")

                    Button {
                        musicPlayerStore.togglePlayPause()
                    } label: {
                        Circle()
                            .fill(DesignSystem.Colors.textPrimary)
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(systemName: musicPlayerStore.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(DesignSystem.Colors.background)
                                    // play.fill isn't optically centered in its bounding box.
                                    .offset(x: musicPlayerStore.isPlaying ? 0 : 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(musicPlayerStore.currentSound == nil)
                    .pointerCursor()
                    .help("Play/pause this folder (Space)")

                    TransportButton(systemImage: "forward.fill", size: 15) {
                        musicPlayerStore.skipToNext()
                    }
                    .disabled(musicPlayerStore.currentSound == nil)
                    .help("Next track")
                }

                HStack {
                    Spacer()
                    TransportButton(
                        systemImage: "shuffle",
                        size: 13,
                        isActive: musicPlayerStore.isShuffled
                    ) {
                        musicPlayerStore.toggleShuffle()
                    }
                    .help(musicPlayerStore.isShuffled ? "Turn shuffle off" : "Shuffle this folder")
                }
            }

            TimelineView(
                elapsed: musicPlayerStore.elapsedTime,
                duration: musicPlayerStore.currentDuration,
                onSeek: musicPlayerStore.seek(to:)
            )
        }
    }

    // MARK: - Right: microphone + volume

    private var rightSection: some View {
        HStack(spacing: 14) {
            Button {
                microphoneManager.toggle()
            } label: {
                Image(systemName: microphoneManager.isLive ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(microphoneManager.isLive ? DesignSystem.Colors.onAccent : DesignSystem.Colors.textSecondary)
                    .frame(width: 30, height: 30)
                    .background {
                        Circle()
                            .fill(microphoneManager.isLive ? DesignSystem.Colors.dangerGlow : Color.clear)
                    }
                    .overlay {
                        Circle().strokeBorder(DesignSystem.Colors.border, lineWidth: microphoneManager.isLive ? 0 : 1)
                    }
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(microphoneManager.isLive ? "Mute the microphone" : "Go live on the microphone")

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: volumeIconName)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 14)

                    SnappingSlider(value: $settingsStore.settings.volume)
                        .frame(width: 144)

                    percentLabel(settingsStore.settings.volume)
                }
                .help("Sound volume")

                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 14)

                    SnappingSlider(value: $settingsStore.settings.microphoneVolume)
                        .frame(width: 144)

                    percentLabel(settingsStore.settings.microphoneVolume)
                }
                .help("Mic volume")
            }
        }
    }

    /// Fixed-width so the sliders don't shift as the value goes between 1, 2 and 3 digits.
    private func percentLabel(_ value: Float) -> some View {
        Text("\(Int((value * 100).rounded()))%")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .frame(width: 36, alignment: .trailing)
    }

    private var volumeIconName: String {
        switch settingsStore.settings.volume {
        case 0: return "speaker.slash.fill"
        case ..<0.5: return "speaker.wave.1.fill"
        default: return "speaker.wave.2.fill"
        }
    }
}

/// Small round icon-only transport button (back/skip/shuffle), lighter weight than the primary
/// play/pause control. `isActive` brightens the icon for toggles that are switched on.
private struct TransportButton: View {
    let systemImage: String
    var size: CGFloat = 14
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// Three bouncing level bars next to the track name, like Spotify's now-playing indicator.
/// Bounces in the accent color while playing; rests as short, dim bars while paused.
private struct LevelsIndicator: View {
    let isAnimating: Bool

    private static let barWidth: CGFloat = 3
    private static let maxHeight: CGFloat = 12
    private static let restingFraction: CGFloat = 0.3
    /// Each bar bounces at its own speed and phase so they don't move in lockstep.
    private static let bars: [(speed: Double, phase: Double)] = [(7.0, 0), (9.5, 1.7), (6.0, 3.1)]

    var body: some View {
        // Fully qualified: this file's own TimelineView (the progress bar) shadows SwiftUI's.
        SwiftUI.TimelineView(.animation(paused: !isAnimating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Self.bars.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isAnimating ? DesignSystem.Colors.accentPrimary : DesignSystem.Colors.textSecondary)
                        .frame(width: Self.barWidth, height: Self.maxHeight * fraction(for: index, at: time))
                }
            }
            .frame(height: Self.maxHeight, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    private func fraction(for index: Int, at time: TimeInterval) -> CGFloat {
        guard isAnimating else { return Self.restingFraction }
        let bar = Self.bars[index]
        let wave = (sin(time * bar.speed + bar.phase) + 1) / 2
        return Self.restingFraction + (1 - Self.restingFraction) * CGFloat(wave)
    }
}

/// Thin progress bar with elapsed/total time labels, mirroring Spotify's now-playing timeline.
/// Click or drag anywhere on the bar to scrub: the playhead follows the pointer while dragging
/// and the audio jumps there on release (or, while paused, the next play starts from there).
private struct TimelineView: View {
    let elapsed: TimeInterval
    let duration: TimeInterval?
    let onSeek: (TimeInterval) -> Void

    /// Progress (0...1) under the pointer mid-drag; overrides `elapsed` until released so the
    /// playhead doesn't snap back between the store's ticks.
    @State private var dragProgress: Double?
    @State private var isHovering = false

    private static let barHeight: CGFloat = 4
    private static let knobSize: CGFloat = 12

    private var progress: Double {
        if let dragProgress { return dragProgress }
        guard let duration, duration > 0 else { return 0 }
        return min(elapsed / duration, 1)
    }

    private var displayedElapsed: TimeInterval {
        guard let dragProgress, let duration else { return elapsed }
        return dragProgress * duration
    }

    private var canSeek: Bool {
        (duration ?? 0) > 0
    }

    private var isActive: Bool {
        canSeek && (isHovering || dragProgress != nil)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.format(displayedElapsed))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)

            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignSystem.Colors.border)
                        .frame(height: Self.barHeight)
                    Capsule()
                        .fill(isActive ? DesignSystem.Colors.accentPrimary : DesignSystem.Colors.textPrimary)
                        .frame(width: width * progress, height: Self.barHeight)
                    if isActive {
                        Circle()
                            .fill(DesignSystem.Colors.textPrimary)
                            .frame(width: Self.knobSize, height: Self.knobSize)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .offset(x: width * progress - Self.knobSize / 2)
                    }
                }
                .frame(maxHeight: .infinity)
                // The whole row (not just the 4pt-tall bar) is the hit target.
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard canSeek, width > 0 else { return }
                            dragProgress = min(max(value.location.x / width, 0), 1)
                        }
                        .onEnded { value in
                            guard canSeek, let duration, width > 0 else { return }
                            let fraction = min(max(value.location.x / width, 0), 1)
                            onSeek(fraction * duration)
                            dragProgress = nil
                        }
                )
                .onHover { isHovering = $0 }
            }
            .frame(height: Self.knobSize + 4)
            .pointerCursor()
            .help(canSeek ? "Drag to scrub" : "")

            Text(duration.map(Self.format) ?? "--:--")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .monospacedDigit()
                .frame(width: 40, alignment: .leading)
        }
    }

    private static func format(_ time: TimeInterval) -> String {
        let total = max(Int(time.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
