import Foundation
import Testing
@testable import GameCore

struct LoaderBundlesTests {
    private func makeBundle(_ name: String, in folder: URL, identifier: String) throws {
        let contents = folder.appending(path: "\(name).app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
    }

    /// Only our runtime's bundles in `winetemp-*` folders: other Wine builds keep theirs.
    @Test func findsOnlyOurBundles() throws {
        try withTempDir { temporary in
            let ours = temporary.appending(path: "winetemp-1-2-3-4", directoryHint: .isDirectory)
            try makeBundle("RDR2.exe", in: ours, identifier: LoaderBundles.identifier)
            try makeBundle("wine", in: ours, identifier: LoaderBundles.identifier)
            try makeBundle("GoW.exe", in: ours, identifier: LoaderBundles.identifier(for: "GoW.exe"))
            try makeBundle("Lookalike.exe", in: ours, identifier: LoaderBundles.identifier + "s")
            try makeBundle("Other.exe", in: ours, identifier: "com.codeweavers.CrossOver.wineloader")
            try makeBundle("Elsewhere", in: temporary.appending(path: "not-wine"), identifier: LoaderBundles.identifier)
            FileManager.default.createFile(atPath: ours.appending(path: "steam.exe").path, contents: Data())

            #expect(LoaderBundles.find(in: temporary).map(\.lastPathComponent) == ["GoW.exe.app", "RDR2.exe.app", "wine.app"])
            #expect(LoaderBundles.find(in: temporary.appending(path: "missing")).isEmpty)
        }
    }

    /// The names Wine's loader gives bundles (`extract_exe_name`).
    @Test func namesBundlesAsWineDoes() {
        #expect(LoaderBundles.bundleName(for: "GoW.exe") == "GoW.exe")
        #expect(LoaderBundles.bundleName(for: #"C:\Games\God of War\GoW.exe"#) == "GoW.exe")
        #expect(LoaderBundles.bundleName(for: "/Users/me/Game.Setup.exe") == "Game.Setup.exe")
        #expect(LoaderBundles.bundleName(for: "0123456789abcdef0123456789ABCDEF.setup.exe") == "setup.exe")
        #expect(LoaderBundles.bundleName(for: "Tom & Jerry.exe") == nil)
        #expect(LoaderBundles.displayName(of: "Game.Setup.exe") == "Game.Setup")
        #expect(LoaderBundles.displayName(of: ".hidden") == ".hidden")
        #expect(LoaderBundles.identifier(for: "b1-Win64 Shipping.exe") == "io.github.prateek-srivastav.Corkscrew.wineloader.b1-Win64-Shipping-exe")
    }

    /// Isolated bottles: the app's bundle holds the loader itself (a hard link), and is made again
    /// when the runtime's loader changes.
    @Test func preparesAnIsolatedGamesBundle() throws {
        try withTempDir { root in
            let engine = Engine(id: "test", root: root.appending(path: "runtime"), architecture: .x86_64)
            let loader = LoaderBundles.loader(of: engine)
            try FileManager.default.createDirectory(at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("loader 1".utf8).write(to: loader)
            let folder = root.appending(path: "bundles")
            let game = URL(fileURLWithPath: "/games/GoW.exe")

            let bundle = try #require(try LoaderBundles.prepare(for: game, engine: engine, in: folder))
            #expect(bundle.lastPathComponent == "GoW.exe.app")
            let executable = bundle.appending(path: "Contents/MacOS/GoW.exe")
            func inode(_ url: URL) throws -> Int? { try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int }
            #expect(try inode(executable) == inode(loader))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: bundle.appending(path: "Contents/MacOS/ntdll.so").path)
                == loader.deletingLastPathComponent().appending(path: "ntdll.so").path)
            let plist = try #require(try PropertyListSerialization.propertyList(
                from: Data(contentsOf: bundle.appending(path: "Contents/Info.plist")), format: nil) as? [String: Any])
            #expect(plist["CFBundleExecutable"] as? String == "GoW.exe" && plist["CFBundleName"] as? String == "GoW")
            #expect(plist["LSSupportsGameMode"] as? Bool == true)
            #expect(plist["CFBundleIdentifier"] as? String == "io.github.prateek-srivastav.Corkscrew.wineloader.GoW-exe")
            #expect(LoaderBundles.bundles(in: folder).map(\.lastPathComponent) == ["GoW.exe.app"])

            // A runtime update replaces the loader file.
            try FileManager.default.removeItem(at: loader)
            try Data("loader 2".utf8).write(to: loader)
            #expect(try LoaderBundles.prepare(for: game, engine: engine, in: folder) == bundle)
            #expect(try inode(executable) == inode(loader))
            #expect(try String(contentsOf: executable, encoding: .utf8) == "loader 2")

            // Bundles from before games had their own identifier.
            try makeBundle("GoW.exe", in: folder, identifier: LoaderBundles.identifier)
            #expect(try LoaderBundles.prepare(for: game, engine: engine, in: folder) == bundle)
            #expect(LoaderBundles.bundleIdentifier(of: bundle) == LoaderBundles.identifier(for: "GoW.exe"))
        }
    }

    /// Wine's per-user temporary folder (`/var/folders/…/T`), not `TMPDIR`.
    @Test func temporaryDirectoryIsTheUsersTempFolder() {
        let folder = LoaderBundles.temporaryDirectory
        #expect(folder?.lastPathComponent == "T")
        #expect(folder.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }
}
