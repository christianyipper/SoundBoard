import Foundation

/// Owns the list of playlists, persists them to disk as JSON, and manages the on-disk
/// copies of imported audio files so playback never depends on the original file's location.
final class PlaylistStore: ObservableObject {
    @Published var playlists: [Playlist] = []

    let appSupportDirectory: URL
    let soundsDirectory: URL
    private let playlistsFileURL: URL
    private let fileManager: FileManager

    private var saveWorkItem: DispatchWorkItem?

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let baseDirectory {
            appSupportDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            appSupportDirectory = appSupport.appendingPathComponent("SoundBoard", isDirectory: true)
        }
        soundsDirectory = appSupportDirectory.appendingPathComponent("Sounds", isDirectory: true)
        playlistsFileURL = appSupportDirectory.appendingPathComponent("playlists.json")

        try? fileManager.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        playlists = Self.load(from: playlistsFileURL) ?? []
    }

    func url(for sound: Sound) -> URL {
        soundsDirectory.appendingPathComponent(sound.fileName)
    }

    // MARK: - Playlists

    @discardableResult
    func addPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        scheduleSave()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to newName: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = newName
        scheduleSave()
    }

    func deletePlaylist(_ id: UUID) {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return }
        for sound in playlist.allSounds {
            try? fileManager.removeItem(at: url(for: sound))
        }
        playlists.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - Tabs

    @discardableResult
    func addTab(name: String, toPlaylist playlistID: UUID) -> SoundTab? {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return nil }
        let tab = SoundTab(name: name)
        playlists[playlistIndex].tabs.append(tab)
        scheduleSave()
        return tab
    }

    /// Deletes a tab and the sound files it contains. A playlist always keeps at least one tab,
    /// so this is a no-op if `tabID` is the playlist's only remaining tab.
    func deleteTab(_ tabID: UUID, from playlistID: UUID) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              playlists[playlistIndex].tabs.count > 1,
              let tabIndex = playlists[playlistIndex].tabs.firstIndex(where: { $0.id == tabID }) else { return }

        for sound in playlists[playlistIndex].tabs[tabIndex].sounds {
            try? fileManager.removeItem(at: url(for: sound))
        }
        playlists[playlistIndex].tabs.remove(at: tabIndex)
        scheduleSave()
    }

    // MARK: - Sounds

    /// Copies each source file into the Sounds directory and appends a new Sound to the given
    /// playlist's tab (the default/first tab if `tabID` is nil or unrecognized).
    @discardableResult
    func importSounds(from urls: [URL], into playlistID: UUID, tabID: UUID? = nil) throws -> [Sound] {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return [] }

        let tabIndex = tabID.flatMap { id in
            playlists[playlistIndex].tabs.firstIndex { $0.id == id }
        } ?? 0

        let imported = try copySounds(from: urls, intoTabAt: tabIndex, ofPlaylistAt: playlistIndex)
        scheduleSave()
        return imported
    }

    /// Imports a mix of files and folders into a playlist's default tab. Files found directly at
    /// the top level (or dropped/selected directly, not inside a folder) land in the default tab;
    /// each subfolder, at any depth, becomes its own tab (named after that subfolder, merging into
    /// an existing same-named tab if present) containing the audio files found directly inside it.
    @discardableResult
    func importFolderContents(from urls: [URL], into playlistID: UUID) throws -> [Sound] {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return [] }

        let plan = Self.planFolderImport(from: urls)
        var imported: [Sound] = []

        imported += try copySounds(from: plan.rootFiles, intoTabAt: 0, ofPlaylistAt: playlistIndex)

        for group in plan.tabFiles {
            let tabIndex = tabIndex(named: group.name, inPlaylistAt: playlistIndex)
            imported += try copySounds(from: group.files, intoTabAt: tabIndex, ofPlaylistAt: playlistIndex)
        }

        scheduleSave()
        return imported
    }

    /// Points a playlist at a single on-disk parent folder: imports its contents the same way
    /// `importFolderContents` does (subfolders become tabs) and marks the playlist as having a
    /// root folder selected, so the picker is offered only once per playlist.
    @discardableResult
    func selectRootFolder(_ url: URL, forPlaylist playlistID: UUID) throws -> [Sound] {
        let imported = try importFolderContents(from: [url], into: playlistID)
        if let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) {
            playlists[playlistIndex].rootFolderSelected = true
            scheduleSave()
        }
        return imported
    }

    func renameSound(_ soundID: UUID, in playlistID: UUID, to newName: String) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              let location = soundLocation(soundID, inPlaylistAt: playlistIndex) else { return }
        playlists[playlistIndex].tabs[location.tabIndex].sounds[location.soundIndex].name = newName
        scheduleSave()
    }

    func removeSound(_ soundID: UUID, from playlistID: UUID) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              let location = soundLocation(soundID, inPlaylistAt: playlistIndex) else { return }
        let sound = playlists[playlistIndex].tabs[location.tabIndex].sounds[location.soundIndex]
        try? fileManager.removeItem(at: url(for: sound))
        playlists[playlistIndex].tabs[location.tabIndex].sounds.remove(at: location.soundIndex)
        scheduleSave()
    }

    func setShortcut(_ shortcut: SoundShortcut?, forSound soundID: UUID, inPlaylist playlistID: UUID) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              let location = soundLocation(soundID, inPlaylistAt: playlistIndex) else { return }
        playlists[playlistIndex].tabs[location.tabIndex].sounds[location.soundIndex].shortcut = shortcut
        scheduleSave()
    }

    /// Finds the playlist that already uses a shortcut equal to `shortcut`, if any, excluding `excludingSoundID`.
    func sound(withShortcut shortcut: SoundShortcut, excludingSoundID: UUID? = nil) -> (playlist: Playlist, sound: Sound)? {
        for playlist in playlists {
            for sound in playlist.allSounds where sound.shortcut == shortcut && sound.id != excludingSoundID {
                return (playlist, sound)
            }
        }
        return nil
    }

    /// Finds a sound by id regardless of which playlist or tab it belongs to.
    func sound(withID id: UUID) -> Sound? {
        for playlist in playlists {
            if let sound = playlist.allSounds.first(where: { $0.id == id }) {
                return sound
            }
        }
        return nil
    }

    private func soundLocation(_ soundID: UUID, inPlaylistAt playlistIndex: Int) -> (tabIndex: Int, soundIndex: Int)? {
        for (tabIndex, tab) in playlists[playlistIndex].tabs.enumerated() {
            if let soundIndex = tab.sounds.firstIndex(where: { $0.id == soundID }) {
                return (tabIndex, soundIndex)
            }
        }
        return nil
    }

    /// Finds the tab with the given name in the playlist, creating it if it doesn't exist yet.
    private func tabIndex(named name: String, inPlaylistAt playlistIndex: Int) -> Int {
        if let index = playlists[playlistIndex].tabs.firstIndex(where: { $0.name == name }) {
            return index
        }
        playlists[playlistIndex].tabs.append(SoundTab(name: name))
        return playlists[playlistIndex].tabs.count - 1
    }

    private func copySounds(from urls: [URL], intoTabAt tabIndex: Int, ofPlaylistAt playlistIndex: Int) throws -> [Sound] {
        var imported: [Sound] = []
        for sourceURL in urls {
            let ext = sourceURL.pathExtension
            let fileName = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)")
            let destinationURL = soundsDirectory.appendingPathComponent(fileName)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)

            let name = sourceURL.deletingPathExtension().lastPathComponent
            let sound = Sound(name: name, fileName: fileName)
            playlists[playlistIndex].tabs[tabIndex].sounds.append(sound)
            imported.append(sound)
        }
        return imported
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.writeToDisk()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func writeToDisk() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: playlistsFileURL, options: .atomic)
    }

    /// Synchronously flushes any pending save. Useful for tests and app termination.
    func flush() {
        saveWorkItem?.cancel()
        writeToDisk()
    }

    private static func load(from url: URL) -> [Playlist]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Playlist].self, from: data)
    }

    // MARK: - Folder scanning

    static let audioExtensions: Set<String> = ["mp3", "wav", "aiff", "aif", "m4a", "caf", "aac"]

    /// Recursively finds audio files (by extension) under `folder`, sorted by name.
    static func audioFileURLs(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator where audioExtensions.contains(url.pathExtension.lowercased()) {
            results.append(url)
        }
        return results.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The result of scanning a set of dropped/imported files and folders for `importFolderContents`.
    struct FolderImportPlan {
        /// Files that belong in the playlist's default tab: loose files passed in directly, plus
        /// files found directly at the top level of a dropped/imported folder.
        var rootFiles: [URL] = []
        /// Files found directly inside a subfolder (at any depth), grouped by that subfolder's own
        /// name — each group becomes its own tab. Order matches discovery order; names are unique.
        var tabFiles: [(name: String, files: [URL])] = []
    }

    /// Scans `urls` (a mix of loose audio files and/or folders) into a FolderImportPlan: files land
    /// in the default tab, and every subfolder at any depth becomes its own tab named after itself,
    /// containing the audio files found directly inside it. See `importFolderContents`.
    static func planFolderImport(from urls: [URL]) -> FolderImportPlan {
        var plan = FolderImportPlan()
        var tabIndexByName: [String: Int] = [:]

        func addToTab(named name: String, file: URL) {
            if let index = tabIndexByName[name] {
                plan.tabFiles[index].files.append(file)
            } else {
                tabIndexByName[name] = plan.tabFiles.count
                plan.tabFiles.append((name: name, files: [file]))
            }
        }

        func scan(directory: URL, isRoot: Bool) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            let sortedEntries = entries.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            // Files directly in this directory are recorded (and its tab, if any, registered)
            // before descending into subdirectories, so a parent folder's tab always appears
            // before any of its descendants' tabs regardless of alphabetical interleaving.
            var subdirectories: [URL] = []
            for entry in sortedEntries {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    subdirectories.append(entry)
                } else if audioExtensions.contains(entry.pathExtension.lowercased()) {
                    if isRoot {
                        plan.rootFiles.append(entry)
                    } else {
                        addToTab(named: directory.lastPathComponent, file: entry)
                    }
                }
            }

            for subdirectory in subdirectories {
                scan(directory: subdirectory, isRoot: false)
            }
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                scan(directory: url, isRoot: true)
            } else if audioExtensions.contains(url.pathExtension.lowercased()) {
                plan.rootFiles.append(url)
            }
        }

        return plan
    }
}
