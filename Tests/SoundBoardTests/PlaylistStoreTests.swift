import XCTest
@testable import SoundBoard

final class PlaylistStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testFreshStoreHasOneEmptyLibrary() {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        XCTAssertEqual(store.playlists.count, 1)
        XCTAssertEqual(store.library.name, PlaylistStore.libraryName)
        XCTAssertTrue(store.library.allSounds.isEmpty)
    }

    func testOlderPlaylistsMergeIntoOneLibraryKeepingEverySound() {
        let a = Sound(name: "A", fileName: "a.wav")
        let b = Sound(name: "B", fileName: "b.wav")
        let c = Sound(name: "C", fileName: "c.wav")
        let d = Sound(name: "D", fileName: "d.wav")
        var first = Playlist(name: "Game 1", sounds: [a])
        first.tabs.append(SoundTab(name: "Goals", sounds: [b]))
        var second = Playlist(name: "Game 2", sounds: [c])
        second.tabs.append(SoundTab(name: "Goals", sounds: [d]))
        second.tabs.append(SoundTab(name: "Intros"))

        let library = PlaylistStore.mergedLibrary(from: [first, second])

        XCTAssertEqual(library.id, first.id)
        XCTAssertEqual(library.name, PlaylistStore.libraryName)
        XCTAssertEqual(library.tabs.map(\.name), [Playlist.defaultTabName, "Goals", "Intros"])
        XCTAssertEqual(library.sounds.map(\.name), ["A", "C"])
        XCTAssertEqual(library.tabs[1].sounds.map(\.name), ["B", "D"], "same-named folders merge")
    }

    func testImportSoundsCopiesFileAndAppendsToPlaylist() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library

        let sourceURL = tempDirectory.appendingPathComponent("source.wav")
        try Data([0x01, 0x02, 0x03]).write(to: sourceURL)

        let imported = try store.importSounds(from: [sourceURL], into: playlist.id)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first?.name, "source")

        let storedSound = store.playlists.first?.sounds.first
        XCTAssertNotNil(storedSound)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: storedSound!).path))
    }

    func testRemoveSoundDeletesFileAndRecord() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library
        let sourceURL = tempDirectory.appendingPathComponent("source.wav")
        try Data([0x01]).write(to: sourceURL)
        let sound = try store.importSounds(from: [sourceURL], into: playlist.id).first!
        let soundFileURL = store.url(for: sound)

        store.removeSound(sound.id, from: playlist.id)

        XCTAssertTrue(store.playlists.first!.sounds.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: soundFileURL.path))
    }

    func testShortcutAssignmentAndConflictLookup() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library
        let sourceA = tempDirectory.appendingPathComponent("a.wav")
        let sourceB = tempDirectory.appendingPathComponent("b.wav")
        try Data([0x01]).write(to: sourceA)
        try Data([0x02]).write(to: sourceB)
        let sounds = try store.importSounds(from: [sourceA, sourceB], into: playlist.id)
        let soundA = sounds[0]
        let soundB = sounds[1]

        let shortcut = SoundShortcut(keyCode: 1, modifierFlags: [.command])
        store.setShortcut(shortcut, forSound: soundA.id, inPlaylist: playlist.id)

        let conflict = store.sound(withShortcut: shortcut, excludingSoundID: soundB.id)
        XCTAssertEqual(conflict?.sound.id, soundA.id)

        let noConflict = store.sound(withShortcut: shortcut, excludingSoundID: soundA.id)
        XCTAssertNil(noConflict)
    }

    func testSoundLookupByIDAcrossPlaylists() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library
        let sourceURL = tempDirectory.appendingPathComponent("a.wav")
        try Data([0x01]).write(to: sourceURL)
        let sound = try store.importSounds(from: [sourceURL], into: playlist.id).first!

        XCTAssertEqual(store.sound(withID: sound.id)?.name, sound.name)
        XCTAssertNil(store.sound(withID: UUID()))
    }

    func testAudioFileURLsFindsFilesRecursivelyByExtension() throws {
        let scanRoot = tempDirectory.appendingPathComponent("DropFolder")
        let nested = scanRoot.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0x01]).write(to: scanRoot.appendingPathComponent("top.wav"))
        try Data([0x02]).write(to: nested.appendingPathComponent("deep.mp3"))
        try Data([0x03]).write(to: scanRoot.appendingPathComponent("notes.txt"))

        let found = PlaylistStore.audioFileURLs(in: scanRoot)

        XCTAssertEqual(Set(found.map(\.lastPathComponent)), ["top.wav", "deep.mp3"])
    }

    func testImportFolderContentsPutsTopLevelFilesInDefaultTab() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library

        let dropRoot = tempDirectory.appendingPathComponent("DropFolder")
        try FileManager.default.createDirectory(at: dropRoot, withIntermediateDirectories: true)
        try Data([0x01]).write(to: dropRoot.appendingPathComponent("top.wav"))

        try store.importFolderContents(from: [dropRoot], into: playlist.id)

        let updated = store.playlists.first!
        XCTAssertEqual(updated.tabs.count, 1)
        XCTAssertEqual(updated.tabs.first?.name, Playlist.defaultTabName)
        XCTAssertEqual(updated.sounds.map(\.name), ["top"])
    }

    func testImportFolderContentsCreatesFlatTabsForNestedSubfolders() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library

        // Folder1 (dropped) > Folder2 > Folder3, per the nested-subfolder example.
        let folder1 = tempDirectory.appendingPathComponent("Folder1")
        let folder2 = folder1.appendingPathComponent("Folder2")
        let folder3 = folder2.appendingPathComponent("Folder3")
        try FileManager.default.createDirectory(at: folder3, withIntermediateDirectories: true)
        try Data([0x01]).write(to: folder1.appendingPathComponent("root.wav"))
        try Data([0x02]).write(to: folder2.appendingPathComponent("two.wav"))
        try Data([0x03]).write(to: folder3.appendingPathComponent("three.wav"))

        try store.importFolderContents(from: [folder1], into: playlist.id)

        let updated = store.playlists.first!
        XCTAssertEqual(updated.tabs.map(\.name), [Playlist.defaultTabName, "Folder2", "Folder3"])
        XCTAssertEqual(updated.sounds.map(\.name), ["root"])
        XCTAssertEqual(updated.tabs[1].sounds.map(\.name), ["two"])
        XCTAssertEqual(updated.tabs[2].sounds.map(\.name), ["three"])
        XCTAssertEqual(updated.allSounds.count, 3)
    }

    func testImportFolderContentsMergesSameNamedSubfoldersIntoOneTab() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library

        let dropRoot = tempDirectory.appendingPathComponent("DropFolder")
        let subA = dropRoot.appendingPathComponent("Category/A")
        let subB = dropRoot.appendingPathComponent("Other/A")
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        try Data([0x01]).write(to: subA.appendingPathComponent("one.wav"))
        try Data([0x02]).write(to: subB.appendingPathComponent("two.wav"))

        try store.importFolderContents(from: [dropRoot], into: playlist.id)

        let updated = store.playlists.first!
        let tabNamedA = updated.tabs.first { $0.name == "A" }
        XCTAssertEqual(updated.tabs.filter { $0.name == "A" }.count, 1)
        XCTAssertEqual(Set(tabNamedA?.sounds.map(\.name) ?? []), ["one", "two"])
    }

    private func makeFolder(_ name: String, files: [String], subfolders: [String: [String]] = [:]) throws -> URL {
        let folder = tempDirectory.appendingPathComponent("source-\(UUID().uuidString)").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data([0x01]).write(to: folder.appendingPathComponent(file))
        }
        for (subfolder, subfiles) in subfolders {
            let subURL = folder.appendingPathComponent(subfolder)
            try FileManager.default.createDirectory(at: subURL, withIntermediateDirectories: true)
            for file in subfiles {
                try Data([0x01]).write(to: subURL.appendingPathComponent(file))
            }
        }
        return folder
    }

    func testImportFolderAddsFolderAsNewTabNamedAfterIt() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library
        let folder = try makeFolder("Horns", files: ["a.wav", "b.mp3"], subfolders: ["Short": ["c.wav"]])

        try store.importFolder(folder, into: playlist.id)

        let tabs = try XCTUnwrap(store.playlists.first).tabs
        XCTAssertEqual(tabs.map(\.name), [Playlist.defaultTabName, "Horns", "Short"])
        XCTAssertTrue(tabs[0].sounds.isEmpty)
        XCTAssertEqual(tabs[1].sounds.map(\.name), ["a", "b"])
        XCTAssertEqual(tabs[2].sounds.map(\.name), ["c"])
    }

    func testImportFolderReplacingTabSwapsNameAndContentsAndDeletesOldFiles() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library
        try store.importFolder(try makeFolder("Old", files: ["old.wav"]), into: playlist.id)
        let oldTab = try XCTUnwrap(store.playlists.first?.tabs.last)
        let oldFileURL = store.url(for: try XCTUnwrap(oldTab.sounds.first))

        try store.importFolder(try makeFolder("New", files: ["x.wav", "y.wav"]), into: playlist.id, replacing: oldTab.id)

        let tabs = try XCTUnwrap(store.playlists.first).tabs
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(tabs[1].id, oldTab.id)
        XCTAssertEqual(tabs[1].name, "New")
        XCTAssertEqual(tabs[1].sounds.map(\.name), ["x", "y"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFileURL.path))
    }

    func testImportFolderNeverReplacesRootTab() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library
        let sourceURL = tempDirectory.appendingPathComponent("loose.wav")
        try Data([0x01]).write(to: sourceURL)
        try store.importSounds(from: [sourceURL], into: playlist.id)
        let rootID = try XCTUnwrap(store.playlists.first?.tabs.first?.id)

        try store.importFolder(try makeFolder("New", files: ["x.wav"]), into: playlist.id, replacing: rootID)

        let tabs = try XCTUnwrap(store.playlists.first).tabs
        XCTAssertEqual(tabs.map(\.name), [Playlist.defaultTabName, "New"])
        XCTAssertEqual(tabs[0].sounds.map(\.name), ["loose"])
    }

    func testSoundOperationsWorkAcrossTabs() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library

        let wrapper = tempDirectory.appendingPathComponent("Wrapper")
        let folder = wrapper.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sourceURL = folder.appendingPathComponent("nested.wav")
        try Data([0x01]).write(to: sourceURL)
        try store.importFolderContents(from: [wrapper], into: playlist.id)

        let tabbedSound = store.playlists.first!.tabs.first { $0.name == "Sub" }!.sounds.first!
        let soundFileURL = store.url(for: tabbedSound)

        store.renameSound(tabbedSound.id, in: playlist.id, to: "Renamed")
        XCTAssertEqual(store.sound(withID: tabbedSound.id)?.name, "Renamed")

        let shortcut = SoundShortcut(keyCode: 1, modifierFlags: [.command])
        store.setShortcut(shortcut, forSound: tabbedSound.id, inPlaylist: playlist.id)
        XCTAssertEqual(store.sound(withShortcut: shortcut)?.sound.id, tabbedSound.id)

        store.removeSound(tabbedSound.id, from: playlist.id)
        XCTAssertNil(store.sound(withID: tabbedSound.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: soundFileURL.path))
    }

    func testAddTabAppendsEmptyTab() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library

        let tab = store.addTab(name: "Extras", toPlaylist: playlist.id)

        XCTAssertEqual(store.playlists.first?.tabs.map(\.name), [Playlist.defaultTabName, "Extras"])
        XCTAssertEqual(tab?.sounds, [])
    }

    func testDeleteTabRemovesTabAndItsSoundFiles() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library
        let tab = store.addTab(name: "Extras", toPlaylist: playlist.id)!
        let sourceURL = tempDirectory.appendingPathComponent("extra.wav")
        try Data([0x01]).write(to: sourceURL)
        let sound = try store.importSounds(from: [sourceURL], into: playlist.id, tabID: tab.id).first!
        let soundFileURL = store.url(for: sound)

        store.deleteTab(tab.id, from: playlist.id)

        XCTAssertEqual(store.playlists.first?.tabs.map(\.name), [Playlist.defaultTabName])
        XCTAssertFalse(FileManager.default.fileExists(atPath: soundFileURL.path))
    }

    func testDeleteTabRefusesToRemoveTheLastRemainingTab() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let playlist = store.library
        let onlyTabID = store.playlists.first!.tabs.first!.id

        store.deleteTab(onlyTabID, from: playlist.id)

        XCTAssertEqual(store.playlists.first?.tabs.count, 1)
    }

    func testPlaylistDecodesLegacySoundsOnlyFormatIntoDefaultTab() throws {
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","name":"Legacy","sounds":[{"id":"\(UUID().uuidString)","name":"Old","fileName":"old.wav"}]}
        """
        let playlist = try JSONDecoder().decode(Playlist.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(playlist.tabs.count, 1)
        XCTAssertEqual(playlist.tabs.first?.name, Playlist.defaultTabName)
        XCTAssertEqual(playlist.sounds.map(\.name), ["Old"])
    }

    func testPersistenceRoundTrip() throws {
        let store = PlaylistStore(baseDirectory: tempDirectory)
        let sourceURL = tempDirectory.appendingPathComponent("a.wav")
        try Data([0x01]).write(to: sourceURL)
        try store.importSounds(from: [sourceURL], into: store.library.id)
        store.flush()

        let reloaded = PlaylistStore(baseDirectory: tempDirectory)
        XCTAssertEqual(reloaded.playlists, store.playlists)
    }
}
