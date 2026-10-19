import Foundation
import Testing
@testable import GameCore

struct SpotlightExclusionTests {
    @Test func newDataGoesInFoldersSpotlightSkips() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            #expect([paths.runtimes, paths.components, paths.bottles, paths.gameModeBundles].map(\.lastPathComponent)
                == ["Runtimes.noindex", "Components.noindex", "Bottles.noindex", "GameModeBundles.noindex"])
            #expect(try SpotlightExclusion.moveFolders(paths: paths).isEmpty)

            // An older version ran again and made the old folder: both stay.
            try paths.bottles.makeDirectory()
            try paths.supportRoot.appending(path: "Bottles").makeDirectory()
            #expect(try SpotlightExclusion.moveFolders(paths: paths).isEmpty)
            #expect(paths.bottles.lastPathComponent == "Bottles")
        }
    }

    @Test func movesOldFoldersAndTheLibrarysPaths() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let support = paths.supportRoot
            let exe = support.appending(path: "Bottles/B/prefix/drive_c/Games/Demo/Demo.exe")
            try exe.write("MZ")
            try support.appending(path: "Runtimes/winecx-test/bin/wine").write("")
            try support.appending(path: "Components/dxmt/x").write("")
            try support.appending(path: "GameModeBundles/winecx-test/Demo.exe.app/Contents/Info.plist").write("")
            #expect(paths.bottles.lastPathComponent == "Bottles", "the old name until it moves")
            let elsewhere = root.appending(path: "Elsewhere/Other.exe")
            try LibraryStore(paths: paths).save(Library(games: [
                Game(name: "Demo", executable: exe, bottleID: UUID(), iconSource: exe),
                Game(name: "Other", executable: elsewhere, bottleID: UUID()),
            ]))

            // Wine's temporary folders: ours links to the runtime's old path, another Wine's elsewhere.
            let temporary = root.appending(path: "T")
            let ours = try temporary.appending(path: "winetemp-1-2-3-4").makeDirectory()
            try FileManager.default.createSymbolicLink(atPath: ours.appending(path: "ntdll.so").path,
                                                       withDestinationPath: support.appending(path: "Runtimes/winecx-test/lib/wine/x86_64-unix/ntdll.so").path)
            let other = try temporary.appending(path: "winetemp-5-6-7-8").makeDirectory()
            try FileManager.default.createSymbolicLink(atPath: other.appending(path: "ntdll.so").path, withDestinationPath: "/Applications/Other.app/ntdll.so")

            let moved = try SpotlightExclusion.moveFolders(paths: paths, temporary: temporary)
            #expect(moved.map(\.lastPathComponent) == ["Runtimes.noindex", "Components.noindex", "Bottles.noindex"])
            #expect(!FileManager.default.fileExists(atPath: ours.path), "Wine would reuse it and load the old path")
            #expect(FileManager.default.fileExists(atPath: other.path))
            #expect(paths.bottles.lastPathComponent == "Bottles.noindex")
            #expect(FileManager.default.fileExists(atPath: paths.runtimes.appending(path: "winecx-test/bin/wine").path))
            #expect(!FileManager.default.fileExists(atPath: support.appending(path: "GameModeBundles").path), "launches make them again")
            let games = try LibraryStore(paths: paths).load().games
            let movedExe = support.appending(path: "Bottles.noindex/B/prefix/drive_c/Games/Demo/Demo.exe")
            #expect(games.map(\.executable.path) == [movedExe.path, elsewhere.path])
            #expect(games.map(\.iconSource?.path) == [movedExe.path, nil])
            #expect(FileManager.default.fileExists(atPath: games[0].executable.path))
            #expect(try SpotlightExclusion.moveFolders(paths: paths).isEmpty, "once")
        }
    }

    @Test func waitsWhileWineRunsFromTheData() async throws {
        try await withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let prefix = try paths.supportRoot.appending(path: "Bottles/B/prefix").makeDirectory()
            let process = Process()
            process.executableURL = try await signedSleep(in: root)
            process.arguments = ["30"]
            process.environment = ["WINEPREFIX": prefix.path]
            try process.run()
            defer { process.terminate() }
            #expect(try SpotlightExclusion.moveFolders(paths: paths).isEmpty)
            #expect(paths.bottles.lastPathComponent == "Bottles")

            process.terminate()
            await exited(process)
            #expect(try SpotlightExclusion.moveFolders(paths: paths).map(\.lastPathComponent) == ["Bottles.noindex"])
        }
    }
}
