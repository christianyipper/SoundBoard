import SwiftUI

/// Playlist-driven background music player shown below the hotkey bar, styled like a Spotify
/// "now playing" bar: playlist picker + current track on the left, transport controls and
/// timeline centered, mic toggle and volume on the right. Press Space (or the center Play
/// button) to shuffle through the selected playlist's sounds. Pressing Space again stops the
/// current track and cues the next one for next time, rather than resuming it; a track that
/// finishes on its own advances automatically. Back/Skip jump to the previous/next track in the
/// shuffle order, preserving play/pause state: they play immediately if music was already
/// playing, or just cue the new track (silent) if it was paused. "Reset" re-shuffles the
/// selected playlist from scratch, discarding the current play order.
struct MusicPlayerView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var musicPlayerStore: MusicPlayerStore
    @EnvironmentObject private var microphoneManager: MicrophoneManager
    @EnvironmentObject private var settingsStore: SettingsStore

    private var selectedPlaylist: Playlist? {
        playlistStore.playlists.first { $0.id == musicPlayerStore.selectedPlaylistID }
    }

    private var trackLabel: String {
        guard selectedPlaylist != nil else { return "No Playlist Selected" }
        guard let sound = musicPlayerStore.currentSound else { return "No Sounds in Playlist" }
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
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(DesignSystem.Colors.surfaceTint.opacity(0.35))
    }

    // MARK: - Left: playlist selector + current track

    private var leftSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Playlist", selection: $musicPlayerStore.selectedPlaylistID) {
                Text("Select Playlist").tag(UUID?.none)
                ForEach(playlistStore.playlists) { playlist in
                    Text(playlist.name).tag(Optional(playlist.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200, alignment: .leading)
            .pointerCursor()

            Text(trackLabel)
                .font(DesignSystem.Typography.callout)
                .foregroundStyle(musicPlayerStore.isPlaying ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .lineLimit(1)
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
                    .help("Play/pause the shuffled playlist (Space)")

                    TransportButton(systemImage: "forward.fill", size: 15) {
                        musicPlayerStore.skipToNext()
                    }
                    .disabled(musicPlayerStore.currentSound == nil)
                    .help("Next track")
                }

                HStack {
                    Spacer()
                    TransportButton(systemImage: "shuffle", size: 13) {
                        musicPlayerStore.resetShuffle()
                    }
                    .disabled(musicPlayerStore.selectedPlaylistID == nil)
                    .help("Re-shuffle this playlist from the start")
                }
            }

            TimelineView(
                elapsed: musicPlayerStore.elapsedTime,
                duration: musicPlayerStore.currentDuration
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

            HStack(spacing: 6) {
                Image(systemName: volumeIconName)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 14)

                Slider(value: $settingsStore.settings.volume, in: 0...1)
                    .frame(width: 90)
            }
        }
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
/// play/pause control.
private struct TransportButton: View {
    let systemImage: String
    var size: CGFloat = 14
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// Thin progress bar with elapsed/remaining time labels, mirroring Spotify's now-playing
/// timeline. Read-only: the player has no seek capability, so it's a status display, not a
/// scrubber.
private struct TimelineView: View {
    let elapsed: TimeInterval
    let duration: TimeInterval?

    private var progress: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(elapsed / duration, 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.format(elapsed))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(DesignSystem.Colors.border)
                    Capsule()
                        .fill(DesignSystem.Colors.textPrimary)
                        .frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 4)

            Text(duration.map(Self.format) ?? "--:--")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .monospacedDigit()
                .frame(width: 32, alignment: .leading)
        }
    }

    private static func format(_ time: TimeInterval) -> String {
        let total = max(Int(time.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
