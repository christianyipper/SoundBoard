import SwiftUI

/// The playlists: one per saved game, newest first, all sharing the same sound library. Games
/// save themselves (see GameStore); the one on the gamesheet is selected. Click a game to open
/// it, or right-click to rename or delete it.
struct SidebarView: View {
    @EnvironmentObject private var gameStore: GameStore

    @State private var pendingDelete: SavedGame?
    @State private var renaming: SavedGame?
    @State private var renameText = ""

    /// Selecting a row opens that game; the selection always follows the active save.
    private var selection: Binding<UUID?> {
        Binding(
            get: { gameStore.activeSaveID },
            set: { id in
                guard let id, id != gameStore.activeSaveID else { return }
                gameStore.loadSave(id)
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            ForEach(gameStore.savedGames) { save in
                VStack(alignment: .leading, spacing: 1) {
                    Text(save.name)
                        .lineLimit(1)
                    Text("\(save.goalCount(for: .home))–\(save.goalCount(for: .away)) · \(save.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(DesignSystem.Typography.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .tag(save.id)
                .contextMenu {
                    Button("Rename…") {
                        renameText = save.name
                        renaming = save
                    }
                    Button("Delete…", role: .destructive) { pendingDelete = save }
                }
            }

            // Placed after the list of games so it naturally sits below the last one, or at the
            // top when the list is empty, without needing separate placement logic.
            Button {
                gameStore.newGame()
            } label: {
                Label("New Game", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Start a blank game. Every game shares the same sounds.")
        }
        .navigationTitle("Games")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    gameStore.newGame()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .pointerCursor()
                .help("Start a blank game")
                Spacer()
            }
            .padding(8)
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.name ?? "game")?",
            isPresented: isPresented($pendingDelete),
            presenting: pendingDelete
        ) { save in
            Button("Delete", role: .destructive) { gameStore.deleteSave(save.id) }
        } message: { save in
            Text(save.id == gameStore.activeSaveID
                 ? "This is the game on the gamesheet, so the next game will open in its place. The sounds aren't affected. This can't be undone."
                 : "The sounds aren't affected. This can't be undone.")
        }
        .alert("Rename Game", isPresented: isPresented($renaming), presenting: renaming) { save in
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { gameStore.renameSave(save.id, to: renameText) }
        }
    }

    private func isPresented(_ item: Binding<SavedGame?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}
