import SwiftUI
import UniformTypeIdentifiers

/// The sound grid, styled as a Windows File Explorer-style file browser: a strip of browsing
/// tabs along the top (each one an independent session with its own back/forward history, the
/// way Explorer's own tabs work), an address bar with back/forward buttons and a clickable
/// breadcrumb underneath, and the sound tiles for whichever folder (`SoundTab`) is current.
struct SoundGridView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    let playlist: Playlist

    @State private var isDropTargeted = false
    @State private var importError: String?
    @State private var explorerTabs: [ExplorerTab] = []
    @State private var activeExplorerTabID: UUID?
    @State private var isGridCollapsed = false
    @State private var isSelectingFolder = false

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)]

    /// A playlist's first tab is the root folder every new browsing tab starts at.
    private var rootFolderID: UUID {
        playlist.tabs.first?.id ?? UUID()
    }

    private var activeExplorerTabIndex: Int? {
        explorerTabs.firstIndex { $0.id == activeExplorerTabID }
    }

    private var activeExplorerTab: ExplorerTab? {
        activeExplorerTabIndex.map { explorerTabs[$0] }
    }

    private var currentFolder: SoundTab {
        let folderID = activeExplorerTab?.currentFolderID ?? rootFolderID
        return playlist.tabs.first { $0.id == folderID } ?? playlist.tabs.first ?? SoundTab(name: Playlist.defaultTabName)
    }

    /// Only the root folder shows the playlist's other folders as subfolder tiles — the model is
    /// a flat, single-level list of folders under the root, so a non-root folder has none of its
    /// own to show.
    private var subfoldersOfCurrentFolder: [SoundTab] {
        guard currentFolder.id == rootFolderID else { return [] }
        return playlist.tabs.filter { $0.id != rootFolderID }
    }

    var body: some View {
        VStack(spacing: 0) {
            ExplorerTabStrip(
                tabs: explorerTabs,
                folders: playlist.tabs,
                activeTabID: activeExplorerTabID,
                onSelect: { activeExplorerTabID = $0 },
                onClose: closeExplorerTab,
                onAdd: addExplorerTab,
                onMove: moveExplorerTab
            )

            ExplorerPathBar(
                playlistName: playlist.name,
                currentFolderID: currentFolder.id,
                currentFolderName: currentFolder.name,
                rootFolderID: rootFolderID,
                canGoBack: !(activeExplorerTab?.backStack.isEmpty ?? true),
                canGoForward: !(activeExplorerTab?.forwardStack.isEmpty ?? true),
                isGridCollapsed: $isGridCollapsed,
                onBack: goBack,
                onForward: goForward,
                onNavigateHome: { navigate(to: rootFolderID) },
                onSelectFolder: { isSelectingFolder = true },
                onDeleteFolder: deleteFolder
            )

            if !isGridCollapsed {
                ScrollView {
                    let subfolders = subfoldersOfCurrentFolder
                    if subfolders.isEmpty && currentFolder.sounds.isEmpty {
                        ContentUnavailableView(
                            "No Sounds Yet",
                            systemImage: "waveform",
                            description: Text("Import audio files, or drag files/folders here, to add them to “\(currentFolder.name)”.")
                        )
                        .padding(.top, 80)
                    } else {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(subfolders) { folder in
                                FolderTileView(folder: folder) {
                                    navigate(to: folder.id)
                                } onDelete: {
                                    deleteFolder(folder.id)
                                }
                            }
                            ForEach(currentFolder.sounds) { sound in
                                SoundTileView(playlistID: playlist.id, sound: sound)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
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
        .onAppear {
            if explorerTabs.isEmpty {
                resetExplorerTabs()
            }
        }
        .onChange(of: playlist.id) {
            resetExplorerTabs()
            isGridCollapsed = false
        }
        .fileImporter(
            isPresented: $isSelectingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .navigationTitle("Scorely")
    }

    // MARK: - Browsing tabs

    private func resetExplorerTabs() {
        let tab = ExplorerTab(currentFolderID: rootFolderID)
        explorerTabs = [tab]
        activeExplorerTabID = tab.id
    }

    private func addExplorerTab() {
        let tab = ExplorerTab(currentFolderID: rootFolderID)
        explorerTabs.append(tab)
        activeExplorerTabID = tab.id
    }

    private func closeExplorerTab(_ id: UUID) {
        guard explorerTabs.count > 1, let index = explorerTabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeExplorerTabID == id
        explorerTabs.remove(at: index)
        if wasActive {
            activeExplorerTabID = explorerTabs[min(index, explorerTabs.count - 1)].id
        }
    }

    private func moveExplorerTab(_ draggedID: UUID, before targetID: UUID) {
        guard draggedID != targetID, let fromIndex = explorerTabs.firstIndex(where: { $0.id == draggedID }) else { return }
        let tab = explorerTabs.remove(at: fromIndex)
        let toIndex = explorerTabs.firstIndex(where: { $0.id == targetID }) ?? explorerTabs.count
        explorerTabs.insert(tab, at: toIndex)
    }

    // MARK: - Navigation within the active tab

    private func navigate(to folderID: UUID) {
        guard let index = activeExplorerTabIndex, explorerTabs[index].currentFolderID != folderID else { return }
        explorerTabs[index].backStack.append(explorerTabs[index].currentFolderID)
        explorerTabs[index].forwardStack.removeAll()
        explorerTabs[index].currentFolderID = folderID
    }

    private func goBack() {
        guard let index = activeExplorerTabIndex, let previous = explorerTabs[index].backStack.popLast() else { return }
        explorerTabs[index].forwardStack.append(explorerTabs[index].currentFolderID)
        explorerTabs[index].currentFolderID = previous
    }

    private func goForward() {
        guard let index = activeExplorerTabIndex, let next = explorerTabs[index].forwardStack.popLast() else { return }
        explorerTabs[index].backStack.append(explorerTabs[index].currentFolderID)
        explorerTabs[index].currentFolderID = next
    }

    // MARK: - Folders

    /// At the root, adds the chosen folder as a new folder; inside a folder, replaces that folder
    /// with the chosen one (see PlaylistStore.importFolder).
    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let replacingID = currentFolder.id == rootFolderID ? nil : currentFolder.id
            do {
                try playlistStore.importFolder(url, into: playlist.id, replacing: replacingID)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func deleteFolder(_ folderID: UUID) {
        if activeExplorerTab?.currentFolderID == folderID {
            navigate(to: rootFolderID)
        }
        playlistStore.deleteTab(folderID, from: playlist.id)
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

/// One independent browsing session in the Explorer-style tab strip: which folder it's
/// currently showing, plus the back/forward history of folders previously visited in this
/// session. Purely local UI state — not persisted, and reset whenever the selected playlist
/// changes (each new tab starts at that playlist's root folder).
private struct ExplorerTab: Identifiable {
    let id = UUID()
    var currentFolderID: UUID
    var backStack: [UUID] = []
    var forwardStack: [UUID] = []
}

/// Windows Explorer-style row of browsing tabs: a folder icon + name per tab, a close button
/// that appears on hover (once more than one tab is open), and a trailing "+" to open another
/// tab at the playlist's root folder. Uses the same TabStripButton/TabStripAddButton as every
/// other tab strip in the app (e.g. the hotkey preset strip) so they all match.
private struct ExplorerTabStrip: View {
    let tabs: [ExplorerTab]
    let folders: [SoundTab]
    let activeTabID: UUID?
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onAdd: () -> Void
    let onMove: (UUID, UUID) -> Void

    private func folderName(for tab: ExplorerTab) -> String {
        folders.first { $0.id == tab.currentFolderID }?.name ?? Playlist.defaultTabName
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(tabs) { tab in
                        TabStripButton(
                            id: tab.id,
                            icon: "folder.fill",
                            title: folderName(for: tab),
                            isActive: tab.id == activeTabID,
                            canClose: tabs.count > 1,
                            onSelect: { onSelect(tab.id) },
                            onClose: { onClose(tab.id) },
                            onMove: onMove
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Hugs its content width instead of expanding to fill the HStack, so the add-tab
            // button lands immediately beside the last tab rather than floating off to the right.
            .fixedSize(horizontal: true, vertical: false)

            TabStripAddButton(help: "New tab (opens at the playlist's root folder)", action: onAdd)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .background(DesignSystem.Colors.surfaceTint.opacity(0.35))
    }
}

/// Windows Explorer-style address bar: back/forward buttons on the left, a clickable
/// playlist-name → folder-name breadcrumb in the middle (a single house icon marks "here",
/// consistent with a real path bar rather than one icon per segment), and folder-management/view
/// controls on the right. Switching to a sibling folder happens by going back to the root and
/// clicking its tile in the grid, so the breadcrumb itself only ever needs to go "up".
private struct ExplorerPathBar: View {
    let playlistName: String
    let currentFolderID: UUID
    let currentFolderName: String
    let rootFolderID: UUID
    let canGoBack: Bool
    let canGoForward: Bool
    @Binding var isGridCollapsed: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onNavigateHome: () -> Void
    let onSelectFolder: () -> Void
    let onDeleteFolder: (UUID) -> Void

    private var isAtRoot: Bool { currentFolderID == rootFolderID }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)
                .help("Back")

                Button(action: onForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForward)
                .help("Forward")
            }
            .buttonStyle(.borderless)
            .pointerCursor()

            breadcrumb
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(DesignSystem.Colors.background))
                .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 1))

            Spacer(minLength: 0)

            Button(action: onSelectFolder) {
                Image(systemName: isAtRoot ? "folder.badge.plus" : "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help(isAtRoot
                ? "Add a folder of sounds to this playlist"
                : "Replace “\(currentFolderName)” with another folder (its current sounds are removed)")
            .pointerCursor()

            if !isAtRoot {
                Button(role: .destructive) {
                    onDeleteFolder(currentFolderID)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete “\(currentFolderName)”")
                .pointerCursor()
            }

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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DesignSystem.Colors.background)
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button(action: onNavigateHome) {
                HStack(spacing: 4) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 12))
                    Text(playlistName)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(isAtRoot ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
            .pointerCursor()

            if !isAtRoot {
                Text("/")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text(currentFolderName)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
        }
        .font(DesignSystem.Typography.caption)
    }
}

/// A folder tile shown at the top of the root folder's grid, in the same square format as
/// SoundTileView, so folders and sounds read as one consistent file listing. Clicking it
/// navigates forward into that folder.
private struct FolderTileView: View {
    let folder: SoundTab
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(DesignSystem.Colors.accentPrimary)

                Text(folder.name)
                    .font(DesignSystem.Typography.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .help(folder.name)

                Text("\(folder.sounds.count) sound\(folder.sounds.count == 1 ? "" : "s")")
                    .font(DesignSystem.Typography.captionBold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .frame(width: 140, height: 110)
            // A .plain button only hit-tests the label's opaque pixels (icon + text), so clicks
            // on the tile's empty space did nothing. The glassCard's contentShape below sits
            // outside the Button and doesn't widen its hit area, so it has to be set here.
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: DesignSystem.Radius.medium, tint: DesignSystem.Colors.accentPrimary)
        .pointerCursor()
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
