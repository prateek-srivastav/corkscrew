import Foundation
import Testing
@testable import GameCore

struct UninstallerTests {
    /// Corkscrew's folders and its files in ~/Library go; other apps' files and the folders
    /// around ours stay.
    @Test func removesOnlyCorkscrewsFiles() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root.appending(path: "data"))
            let library = root.appending(path: "Library")
            let id = "io.github.prateek-srivastav.Corkscrew"
            let uninstaller = Uninstaller(paths: paths, bundleIdentifier: id, library: library)
            for item in uninstaller.items where item.pathExtension != "plist" && item.pathExtension != "binarycookies" {
                try item.appending(path: "file").write("x")
            }
            try library.appending(path: "Preferences/\(id).plist").write("x")
            let others = [library.appending(path: "Preferences/com.apple.finder.plist"),
                          library.appending(path: "Caches/\(id).other/file"),
                          root.appending(path: "data/keep.txt")]
            for other in others { try other.write("x") }

            #expect(uninstaller.removeFiles().isEmpty)
            for item in uninstaller.items { #expect(!FileManager.default.fileExists(atPath: item.path)) }
            for other in others { #expect(FileManager.default.fileExists(atPath: other.path)) }
        }
    }

    /// Our links in the user cache folder go; Metal's and D3DMetal's own folders and other links stay.
    @Test func removesOurShaderCacheLinks() throws {
        try withTempDir { root in
            let fm = FileManager.default
            let paths = RuntimeStoreTests.paths(root.appending(path: "data"))
            let folder = root.appending(path: "C")
            try ShaderCacheLinks.prepare(for: URL(fileURLWithPath: "/bottle/FIFA23.exe"), gameID: UUID(), isolated: true, paths: paths, in: folder)
            try folder.appending(path: "d3dm/RDR2.exe/shaders.cache/x").write("x")
            try folder.appending(path: "\(LoaderBundles.identifier)/com.apple.metal/x").write("x")
            try fm.createSymbolicLink(at: folder.appending(path: "d3dm/Other.exe"), withDestinationURL: root.appending(path: "elsewhere"))
            var uninstaller = Uninstaller(paths: paths, bundleIdentifier: "test", library: root.appending(path: "Library"))
            uninstaller.userCache = folder

            uninstaller.removeFiles()
            #expect(try fm.contentsOfDirectory(atPath: folder.path).sorted() == ["d3dm", LoaderBundles.identifier])
            #expect(try fm.contentsOfDirectory(atPath: folder.appending(path: "d3dm").path).sorted() == ["Other.exe", "RDR2.exe"])
        }
    }

    @Test func removesOurLoaderBundlesAndTheirEmptyFolder() throws {
        try withTempDir { temporary in
            func bundle(_ name: String, in folder: String, identifier: String) throws {
                let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
                try temporary.appending(path: "\(folder)/\(name).app/Contents/Info.plist").write(plist)
            }
            try bundle("RDR2.exe", in: "winetemp-1", identifier: LoaderBundles.identifier)
            try bundle("Other.exe", in: "winetemp-2", identifier: LoaderBundles.identifier)
            try bundle("CrossOver.exe", in: "winetemp-2", identifier: "com.codeweavers.CrossOver.wineloader")

            LoaderBundles.removeAll(in: temporary)
            let left = try FileManager.default.contentsOfDirectory(atPath: temporary.path).sorted()
            #expect(left == ["winetemp-2"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.appending(path: "winetemp-2").path) == ["CrossOver.exe.app"])
        }
    }
}
