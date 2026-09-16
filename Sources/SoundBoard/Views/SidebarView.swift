import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    @Binding var selectedPlaylistID: UUID?

    @State private var isAddingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var renamingPlaylistID: UUID?
    @State private var renameText = ""

    var body: some View {
        List(selection: $selectedPlaylistID) {
            ForEach(playlistStore.playlists) { playlist in
                Text("\(playlist.name)  (\(playlist.allSounds.count))")
                    .tag(playlist.id)
                    .contextMenu {
                        Button("Rename…") {
                            renamingPlaylistID = playlist.id
                            renameText = playlist.name
                        }
                        Button("Delete", role: .destructive) {
                            deletePlaylist(playlist.id)
                        }
                    }
            }

            // Placed after the list of playlists so it naturally sits below the last one, or at
            // the top when the list is empty, without needing separate placement logic.
            Button {
                newPlaylistName = ""
                isAddingPlaylist = true
            } label: {
                Label("Add Playlist", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .navigationTitle("Playlists")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    newPlaylistName = ""
                    isAddingPlaylist = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .pointerCursor()
                .help("Create a new playlist")
                Spacer()
            }
            .padding(8)
        }
        .alert("New Playlist", isPresented: $isAddingPlaylist) {
            TextField("Playlist Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createPlaylist() }
        }
        .alert("Rename Playlist", isPresented: Binding(
            get: { renamingPlaylistID != nil },
            set: { if !$0 { renamingPlaylistID = nil } }
        )) {
            TextField("Playlist Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { commitRename() }
        }
    }

    private func createPlaylist() {
        let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = playlistStore.addPlaylist(name: trimmed)
        selectedPlaylistID = playlist.id
    }

    private func commitRename() {
        guard let id = renamingPlaylistID else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlistStore.renamePlaylist(id, to: trimmed)
        renamingPlaylistID = nil
    }

    private func deletePlaylist(_ id: UUID) {
        if selectedPlaylistID == id {
            selectedPlaylistID = nil
        }
        playlistStore.deletePlaylist(id)
    }
}
