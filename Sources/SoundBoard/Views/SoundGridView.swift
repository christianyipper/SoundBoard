import SwiftUI
import UniformTypeIdentifiers

struct SoundGridView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    let playlist: Playlist

    @State private var isDropTargeted = false
    @State private var importError: String?
    @State private var selectedTabID: UUID?
    @State private var isGridCollapsed = false
    @State private var isAddingTab = false
    @State private var newTabName = ""

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)]

    private var currentTab: SoundTab {
        playlist.tabs.first { $0.id == selectedTabID } ?? playlist.tabs.first ?? SoundTab(name: Playlist.defaultTabName)
    }

    var body: some View {
        VStack(spacing: 0) {
            PlaylistTabBar(
                tabs: playlist.tabs,
                selectedTabID: Binding(get: { currentTab.id }, set: { selectedTabID = $0 }),
                isGridCollapsed: $isGridCollapsed,
                onAddTab: {
                    newTabName = ""
                    isAddingTab = true
                },
                onDeleteTab: { tabID in
                    if tabID == currentTab.id {
                        selectedTabID = nil
                    }
                    playlistStore.deleteTab(tabID, from: playlist.id)
                }
            )
            .padding(.horizontal)
            .padding(.top, 8)

            if !isGridCollapsed {
                ScrollView {
                    if currentTab.sounds.isEmpty {
                        ContentUnavailableView(
                            "No Sounds Yet",
                            systemImage: "waveform",
                            description: Text("Import audio files, or drag files/folders here, to add them to “\(playlist.name)”.")
                        )
                        .padding(.top, 80)
                    } else {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(currentTab.sounds) { sound in
                                SoundTileView(playlistID: playlist.id, sound: sound)
                            }
                        }
                        .padding()
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.large)
                        .fill(isDropTargeted ? DesignSystem.Colors.accentPrimary.opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.large)
                        .strokeBorder(DesignSystem.Colors.accentPrimary, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .opacity(isDropTargeted ? 1 : 0)
                        .padding(4)
                )
                .animation(DesignSystem.Motion.quickFade, value: isDropTargeted)
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers)
                    return true
                }
            }
        }
        .onChange(of: playlist.id) {
            selectedTabID = nil
            isGridCollapsed = false
        }
        .alert("New Tab", isPresented: $isAddingTab) {
            TextField("Tab Name", text: $newTabName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createTab() }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .navigationTitle(playlist.name)
    }

    private func createTab() {
        let trimmed = newTabName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let tab = playlistStore.addTab(name: trimmed, toPlaylist: playlist.id) {
            selectedTabID = tab.id
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let playlistID = playlist.id
        let group = DispatchGroup()
        var droppedURLs: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    droppedURLs.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            guard !droppedURLs.isEmpty else { return }
            do {
                try playlistStore.importFolderContents(from: droppedURLs, into: playlistID)
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

/// Tab strip above the sound grid (below the hotkey bar): one chip per tab (subfolders imported
/// into the playlist become their own tab), a "+" button to add a tab, and a trailing button that
/// collapses the sound grid below, to reclaim space while keeping the tabs themselves reachable.
/// Right-click a tab to delete it.
private struct PlaylistTabBar: View {
    let tabs: [SoundTab]
    @Binding var selectedTabID: UUID?
    @Binding var isGridCollapsed: Bool
    let onAddTab: () -> Void
    let onDeleteTab: (UUID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        TabChip(
                            title: tab.name,
                            count: tab.sounds.count,
                            isSelected: tab.id == selectedTabID
                        ) {
                            selectedTabID = tab.id
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                onDeleteTab(tab.id)
                            }
                            .disabled(tabs.count <= 1)
                        }
                    }
                }
            }

            Button(action: onAddTab) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add a new tab")
            .pointerCursor()

            Spacer(minLength: 0)

            Button {
                withAnimation(DesignSystem.Motion.springSmooth) {
                    isGridCollapsed.toggle()
                }
            } label: {
                Image(systemName: isGridCollapsed ? "chevron.down" : "chevron.up")
            }
            .buttonStyle(.borderless)
            .help(isGridCollapsed ? "Show sounds" : "Collapse sounds")
            .pointerCursor()
        }
    }
}

private struct TabChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(title) (\(count))")
                .font(isSelected ? DesignSystem.Typography.captionBold : DesignSystem.Typography.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(isSelected ? DesignSystem.Colors.accentPrimary.opacity(0.18) : DesignSystem.Colors.surfaceTint.opacity(0.5), in: Capsule())
        .foregroundStyle(isSelected ? DesignSystem.Colors.accentPrimary : DesignSystem.Colors.textPrimary)
        .pointerCursor()
    }
}
