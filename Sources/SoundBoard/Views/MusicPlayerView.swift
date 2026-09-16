import SwiftUI

/// Playlist-driven background music player shown below the hotkey bar: pick a playlist, then
/// press Space (or the Play button) to shuffle through its sounds. Pressing Space again stops the
/// current track and cues the next one for next time, rather than resuming it; a track that
/// finishes on its own advances automatically. "Reset" re-shuffles the selected playlist from
/// scratch, discarding the current play order.
struct MusicPlayerView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var musicPlayerStore: MusicPlayerStore

    private var selectedPlaylist: Playlist? {
        playlistStore.playlists.first { $0.id == musicPlayerStore.selectedPlaylistID }
    }

    private var trackLabel: String {
        guard selectedPlaylist != nil else { return "No Playlist Selected" }
        guard let sound = musicPlayerStore.currentSound else { return "No Sounds in Playlist" }
        return sound.name
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("Music Player")
                .font(DesignSystem.Typography.captionBold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Picker("Playlist", selection: $musicPlayerStore.selectedPlaylistID) {
                Text("Select Playlist").tag(UUID?.none)
                ForEach(playlistStore.playlists) { playlist in
                    Text(playlist.name).tag(Optional(playlist.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)

            Button {
                musicPlayerStore.togglePlayPause()
            } label: {
                Image(systemName: musicPlayerStore.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderedProminent)
            .disabled(musicPlayerStore.currentSound == nil)
            .pointerCursor()
            .help("Play/pause the shuffled playlist (Space)")

            Text(trackLabel)
                .font(DesignSystem.Typography.callout)
                .foregroundStyle(musicPlayerStore.isPlaying ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                musicPlayerStore.resetShuffle()
            } label: {
                Label("Reset", systemImage: "shuffle")
            }
            .buttonStyle(.bordered)
            .disabled(musicPlayerStore.selectedPlaylistID == nil)
            .pointerCursor()
            .help("Re-shuffle this playlist from the start")
        }
        .padding(12)
        .glassCard(cornerRadius: DesignSystem.Radius.large)
        .padding([.horizontal, .top])
    }
}
