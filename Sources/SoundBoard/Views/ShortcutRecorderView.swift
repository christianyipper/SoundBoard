import SwiftUI

struct ShortcutRecorderView: View {
    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var shortcutManager: ShortcutManager
    @Environment(\.dismiss) private var dismiss

    let playlistID: UUID
    let sound: Sound

    @State private var isRecording = false
    @State private var capturedShortcut: SoundShortcut?
    @State private var conflict: (playlist: Playlist, sound: Sound)?

    var body: some View {
        VStack(spacing: 12) {
            Text("Assign Shortcut to “\(sound.name)”")
                .font(.headline)

            Button {
                startRecording()
            } label: {
                Text(isRecording ? "Press any key…" : (capturedShortcut?.displayString ?? sound.shortcut?.displayString ?? "Click to Record"))
                    .frame(minWidth: 160)
            }
            .buttonStyle(.bordered)
            .pointerCursor()

            if let conflict {
                Text("“\(conflict.sound.name)” in “\(conflict.playlist.name)” already uses this shortcut.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Cancel") {
                    shortcutManager.cancelRecording()
                    dismiss()
                }
                .pointerCursor()
                if capturedShortcut != nil {
                    Button("Save") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
                }
            }
        }
        .padding()
        .frame(width: 260)
        .onDisappear {
            shortcutManager.cancelRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        conflict = nil
        shortcutManager.beginRecording { shortcut in
            DispatchQueue.main.async {
                isRecording = false
                capturedShortcut = shortcut
                conflict = playlistStore.sound(withShortcut: shortcut, excludingSoundID: sound.id)
            }
        }
    }

    private func save() {
        guard let capturedShortcut else { return }
        playlistStore.setShortcut(capturedShortcut, forSound: sound.id, inPlaylist: playlistID)
        dismiss()
    }
}
