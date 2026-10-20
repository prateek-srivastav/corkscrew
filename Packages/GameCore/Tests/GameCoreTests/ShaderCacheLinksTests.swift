import Foundation
import Testing
@testable import GameCore

struct ShaderCacheLinksTests {
    /// An isolated game's D3DMetal and Metal caches land in its own cache folder, in place of what
    /// was there; other launches take our D3DMetal link away and leave D3DMetal's own folders.
    @Test func linksIsolatedGamesAndUnlinksTheOthers() throws {
        try withTempDir { root in
            let fm = FileManager.default
            let paths = RuntimeStoreTests.paths(root.appending(path: "data"))
            let folder = root.appending(path: "C")
            let game = URL(fileURLWithPath: "/bottle/drive_c/Game/FIFA23.exe")
            let d3dm = folder.appending(path: "d3dm/FIFA23.exe")
            let metal = folder.appending(path: "io.github.prateek-srivastav.Corkscrew.wineloader.FIFA23-exe")
            let id = UUID(), other = UUID()
            // A cache an unsandboxed game of that name made.
            try d3dm.appending(path: "shaders.cache/old").write("x")

            try ShaderCacheLinks.prepare(for: game, gameID: id, isolated: true, paths: paths, in: folder)
            #expect(try fm.destinationOfSymbolicLink(atPath: d3dm.path) == paths.shaderCache(for: id).appending(path: "d3dm").path)
            #expect(try fm.destinationOfSymbolicLink(atPath: metal.path) == paths.shaderCache(for: id).appending(path: "metal").path)
            try d3dm.appending(path: "shaders.cache/new").write("x")
            try metal.appending(path: "com.apple.metal/functions.data").write("x")
            let saved = [paths.shaderCache(for: id).appending(path: "d3dm/shaders.cache/new"),
                         paths.shaderCache(for: id).appending(path: "metal/com.apple.metal/functions.data")]
            for file in saved { #expect(fm.fileExists(atPath: file.path)) }

            // The same name in another isolated bottle: the links follow the game that starts.
            try ShaderCacheLinks.prepare(for: game, gameID: other, isolated: true, paths: paths, in: folder)
            #expect(try fm.destinationOfSymbolicLink(atPath: d3dm.path) == paths.shaderCache(for: other).appending(path: "d3dm").path)
            #expect(try fm.destinationOfSymbolicLink(atPath: metal.path) == paths.shaderCache(for: other).appending(path: "metal").path)

            try ShaderCacheLinks.prepare(for: game, gameID: id, isolated: false, paths: paths, in: folder)
            #expect((try? fm.destinationOfSymbolicLink(atPath: d3dm.path)) == nil)
            #expect(!fm.fileExists(atPath: d3dm.path))
            for file in saved { #expect(fm.fileExists(atPath: file.path)) }

            let own = folder.appending(path: "d3dm/RDR2.exe/shaders.cache/x")
            try own.write("x")
            try ShaderCacheLinks.prepare(for: URL(fileURLWithPath: "/steam/RDR2.exe"), gameID: id, isolated: false, paths: paths, in: folder)
            #expect(fm.fileExists(atPath: own.path))
        }
    }
}
