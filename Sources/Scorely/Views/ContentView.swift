import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var audioPlayerManager: AudioPlayerManager
    @EnvironmentObject private var microphoneManager: MicrophoneManager
    @EnvironmentObject private var hotkeyBarStore: HotkeyBarStore
    @Environment(\.openSettings) private var openSettings

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isImporting = false
    @State private var importError: String?
    @State private var mainMode: MainMode = .files

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            MainModePager(mode: $mainMode) {
                HotkeyBarView(mode: $mainMode)
                MusicPlayerView(playlist: playlistStore.library)
            } page: { mode in
                switch mode {
                case .files:
                    SoundGridView(playlist: playlistStore.library)
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
                .help("Import audio files into the sound library every game shares. Use the folder button above the sounds to add folders.")
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
        .overlay {
            if microphoneManager.isLive {
                PulsingMicBorder()
            }
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            do {
                try playlistStore.importSounds(from: urls, into: playlistStore.library.id)
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
