import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var audioPlayerManager: AudioPlayerManager
    @EnvironmentObject private var microphoneManager: MicrophoneManager
    @EnvironmentObject private var hotkeyBarStore: HotkeyBarStore
    @Environment(\.openSettings) private var openSettings

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedPlaylistID: UUID?
    @State private var isImporting = false
    @State private var importError: String?
    @State private var mainMode: MainMode = .files

    private var selectedPlaylist: Playlist? {
        playlistStore.playlists.first { $0.id == selectedPlaylistID }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedPlaylistID: $selectedPlaylistID)
        } detail: {
            MainModePager(mode: $mainMode) {
                HotkeyBarView(mode: $mainMode)
                MusicPlayerView()
            } page: { mode in
                switch mode {
                case .files:
                    if let selectedPlaylist {
                        SoundGridView(playlist: selectedPlaylist)
                    } else {
                        ContentUnavailableView(
                            "No Playlist Selected",
                            systemImage: "music.note.list",
                            description: Text("Choose a playlist from the sidebar, or create a new one.")
                        )
                    }
                case .gamesheet:
                    GamesheetView()
                case .call:
                    CallView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DesignSystem.Colors.backgroundGradient.ignoresSafeArea())
        }
        .toolbar {
            ToolbarItem {
                Button {
                    isImporting = true
                } label: {
                    Label("Import Audio…", systemImage: "square.and.arrow.down")
                }
                .disabled(selectedPlaylistID == nil)
                .help(selectedPlaylistID == nil ? "Select a playlist first" : "Import audio files into this playlist. Use the folder button above the sounds to add folders.")
            }

            ToolbarItem {
                Button {
                    audioPlayerManager.resetPlayedStates()
                    hotkeyBarStore.resetAll()
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .help("Reset played states and clear every hotkey slot assignment")
            }

            ToolbarItem {
                Button {
                    openSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open settings")
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.mp3, .wav, .aiff, .mpeg4Audio, .audio],
            allowsMultipleSelection: true
        ) { result in
            handleImportResult(result)
        }
        .alert("Import Failed", isPresented: .constant(importError != nil), actions: {
            Button("OK") { importError = nil }
        }, message: {
            Text(importError ?? "")
        })
        // The Call view has its own "Goal Call" hotkey rack; the other views share "Default".
        .onChange(of: mainMode, initial: true) { _, mode in
            hotkeyBarStore.selectPreset(named: mode.hotkeyPresetName)
        }
        .onAppear {
            if selectedPlaylistID == nil {
                selectedPlaylistID = playlistStore.playlists.first?.id
            }
        }
        .overlay {
            if microphoneManager.isLive {
                PulsingMicBorder()
            }
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        guard let playlistID = selectedPlaylistID else { return }
        switch result {
        case .success(let urls):
            do {
                try playlistStore.importSounds(from: urls, into: playlistID)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
}

/// Full-window pulsing red border shown whenever the mic is live, so it's obvious from across
/// the room regardless of which part of the app is on screen.
private struct PulsingMicBorder: View {
    @State private var isPulsing = false

    var body: some View {
        Rectangle()
            .strokeBorder(DesignSystem.Colors.dangerGlow, lineWidth: isPulsing ? 8 : 3)
            .opacity(isPulsing ? 1 : 0.5)
            .softGlow(DesignSystem.Colors.dangerGlow, radius: 24, isActive: isPulsing)
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .onAppear {
                withAnimation(DesignSystem.Motion.glowPulse) {
                    isPulsing = true
                }
            }
    }
}
