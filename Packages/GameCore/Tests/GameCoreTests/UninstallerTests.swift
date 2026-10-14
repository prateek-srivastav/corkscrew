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
