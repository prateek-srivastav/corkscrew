import Foundation
import Testing
@testable import GameCore

struct BottleImportTests {
    private func bottle(in paths: AppPaths, kind: Bottle.Kind = .isolated) throws -> Bottle {
        let bottle = Bottle(name: "Sandbox", kind: kind, engineID: "winecx-test")
        try BottleStore(paths: paths).save(bottle)
        try BottleLocation(bottleID: bottle.id, paths: paths).prefix.appending(path: "drive_c/users/crossover/AppData").makeDirectory()
        try BottleLocation(bottleID: bottle.id, paths: paths).prefix.appending(path: "drive_c/users/Public").makeDirectory()
        return bottle
    }

    @Test func importsAProgramWithItsSplitFilesIntoDownloads() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let store = BottleStore(paths: paths)
            let target = try bottle(in: paths)
            let downloads = root.appending(path: "Downloads")
            for name in ["setup_game.exe", "setup_game-1.bin", "Setup_Game-2.bin", "setup_game_editor.exe", "other.exe"] {
                try downloads.appending(path: name).write(name)
            }

            let imported = try store.importProgram(downloads.appending(path: "setup_game.exe"), into: target)
            let expected = BottleLocation(bottleID: target.id, paths: paths).prefix.appending(path: "drive_c/users/crossover/Downloads")
            #expect(imported == expected.appending(path: "setup_game.exe"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: expected.path).sorted()
                    == ["Setup_Game-2.bin", "setup_game-1.bin", "setup_game.exe"])
            // Importing again reuses the copies; a changed file is replaced.
            try downloads.appending(path: "setup_game-1.bin").write("a newer, longer part")
            #expect(try store.importProgram(downloads.appending(path: "setup_game.exe"), into: target) == imported)
            #expect(try String(contentsOf: expected.appending(path: "setup_game-1.bin"), encoding: .utf8) == "a newer, longer part")
        }
    }

    /// Issue #52: Unreal's launcher stub copied alone couldn't find `<Project>\Binaries\Win64`, and the
    /// launch, which inspects the copy, picked WineD3D for a DX12 game.
    @Test func importsAnUnrealGameWithItsWholeFolder() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)  // `root` is the home folder
            let store = BottleStore(paths: paths)
            let target = try bottle(in: paths)
            let folder = root.appending(path: "Downloads/SparkingZERO")
            let stub = folder.appending(path: "SparkingZERO.exe")
            try stub.write(PEBuilder(imports: ["kernel32.dll"]).build())
            let shipping = folder.appending(path: "SparkingZERO/Binaries/Win64/SparkingZERO-Win64-Shipping.exe")
            try shipping.write(PEBuilder(imports: ["kernel32.dll", "dxgi.dll"], payload: utf16LE("D3D12.dll")).build())
            try folder.appending(path: "SparkingZERO/Content/Paks/pakchunk0.pak").write("pak")
            try folder.appending(path: "Engine/Binaries/ThirdParty/x.dll").write("dll")

            #expect(store.programFolder(of: stub)?.path == folder.path)
            #expect(store.programFolder(of: shipping)?.path == folder.path)
            #expect(store.spaceNeeded(toImport: folder) == 0)

            let imported = try store.importProgram(stub, folder: folder, into: target)
            let games = store.location(of: target).prefix.appending(path: "drive_c/Games")
            #expect(imported.path == games.appending(path: "SparkingZERO/SparkingZERO.exe").path)
            #expect(FileManager.default.fileExists(atPath: games.appending(path: "SparkingZERO/SparkingZERO/Content/Paks/pakchunk0.pak").path))
            let inspection = try GameDetector.inspect(executable: imported)
            #expect(inspection.inspectedBinary.lastPathComponent == "SparkingZERO-Win64-Shipping.exe")
            #expect(inspection.recommendedBackend == .d3dmetal)
            #expect(FileManager.default.fileExists(atPath: shipping.path))

            // Picked again, or by its Shipping exe: a second copy, never over the first.
            #expect(try store.importProgram(shipping, folder: folder, into: target).path
                    == games.appending(path: "SparkingZERO 2/SparkingZERO/Binaries/Win64/SparkingZERO-Win64-Shipping.exe").path)
        }
    }

    @Test func leavesFoldersOthersShareBehind() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)  // `root` is the home folder
            let store = BottleStore(paths: paths)
            let other = store.location(of: try bottle(in: paths)).prefix.appending(path: "drive_c")
            let home = root
            func folder(_ program: URL) -> String? { store.programFolder(of: program)?.path }

            #expect(folder(home.appending(path: "Downloads/setup.exe")) == nil)
            #expect(folder(home.appending(path: "setup.exe")) == nil)
            #expect(folder(URL(fileURLWithPath: "/Volumes/Disk/setup.exe")) == nil)
            #expect(folder(URL(fileURLWithPath: "/Applications/setup.exe")) == nil)
            #expect(folder(other.appending(path: "users/crossover/Downloads/setup.exe")) == nil)
            #expect(folder(other.appending(path: "Games/tool.exe")) == nil)
            #expect(folder(home.appending(path: "Downloads/Tool/tool.exe")) == home.appending(path: "Downloads/Tool").path)
            #expect(folder(other.appending(path: "Games/Tool/tool.exe")) == other.appending(path: "Games/Tool").path)
            #expect(folder(other.appending(path: "Program Files/Tool/bin/tool.exe")) == other.appending(path: "Program Files/Tool/bin").path)
        }
    }

    @Test func leavesNoHalfCopiedFolder() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root.appending(path: "data"))
            let store = BottleStore(paths: paths)
            let target = try bottle(in: paths)
            let folder = root.appending(path: "Tool")
            try folder.appending(path: "tool.exe").write("MZ")
            let unreadable = folder.appending(path: "data/locked.bin")
            try unreadable.write("locked")
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

            #expect(throws: (any Error).self) { try store.importProgram(folder.appending(path: "tool.exe"), folder: folder, into: target) }
            let games = store.location(of: target).prefix.appending(path: "drive_c/Games")
            #expect(try FileManager.default.contentsOfDirectory(atPath: games.path).isEmpty)
        }
    }

    @Test func countsTheSpaceACopyFromAnotherDiskTakes() async throws {
        try await withTempDir { root in
            let store = BottleStore(paths: RuntimeStoreTests.paths(root.appending(path: "data")))
            try store.paths.bottles.makeDirectory()
            let source = root.appending(path: "disc")
            try source.appending(path: "Tool/tool.exe").write(Data(count: 100_000))
            let image = root.appending(path: "Tool.iso")
            let make = Process()
            make.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            make.arguments = ["makehybrid", "-iso", "-joliet", "-quiet", "-o", image.path, source.path]
            try make.run()
            await exited(make)
            let prefix = root.appending(path: "prefix")
            try prefix.appending(path: "dosdevices").makeDirectory()
            let mounted = try await offThePool { try DiscImage.attach([image], prefix: prefix) }
            let onDisc = prefix.appending(path: "dosdevices/d:/Tool")

            #expect(store.spaceNeeded(toImport: onDisc) >= 100_000)
            #expect(store.spaceNeeded(toImport: source.appending(path: "Tool")) == 0)
            try await offThePool { DiscImage.detach(mounted, prefix: prefix) }
        }
    }

    @Test func importsABottleFolderOnce() throws {
        try withTempDir { root in
            let elsewhere = RuntimeStoreTests.paths(root.appending(path: "dev-data"))
            let original = try bottle(in: elsewhere)
            let paths = RuntimeStoreTests.paths(root.appending(path: "app"))
            let store = BottleStore(paths: paths)

            let folder = BottleLocation(bottleID: original.id, paths: elsewhere).directory
            // bottle.json stores whole seconds, so compare what identifies the bottle.
            #expect(try store.importBottle(from: folder).id == original.id)
            #expect(try store.list().map(\.id) == [original.id])
            #expect(FileManager.default.fileExists(atPath: store.location(of: original).prefix.appending(path: "drive_c/users/crossover").path))
            #expect(throws: BottleStore.StoreError.alreadyExists("Sandbox")) { try store.importBottle(from: folder) }
        }
    }

    @Test func importsKnownComponentsAndKeepsExistingOnes() throws {
        try withTempDir { root in
            let source = root.appending(path: "build/components")
            for name in ["dxmt-0.80", "d3dmetal-3.0", "moltenvk-1.4.2"] { try source.appending(path: "\(name)/marker").write(name) }
            let components = RuntimeStoreTests.paths(root).components
            try components.appending(path: "d3dmetal-3.0/marker").write("already here")

            #expect(try ComponentCatalog.importComponents(from: source, into: components) == ["dxmt-0.80"])
            #expect(ComponentCatalog.staged(in: components) == ["d3dmetal-3.0", "dxmt-0.80"])
            #expect(try String(contentsOf: components.appending(path: "d3dmetal-3.0/marker"), encoding: .utf8) == "already here")
        }
    }

    @Test func findsTheEngineForABottlesRuntime() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let store = RuntimeStore(paths: paths)
            #expect(try store.engine() == nil)
            for id in ["winecx-a-x86_64", "winecx-b-x86_64"] {
                try RuntimeStoreTests.makeRuntime(at: root.appending(path: "src/\(id)"), id: id)
                try store.install(directory: root.appending(path: "src/\(id)"))
            }
            try paths.components.appending(path: "dxmt-0.80/x86_64-windows").makeDirectory()

            #expect(try store.engine(id: "winecx-a-x86_64")?.id == "winecx-a-x86_64")
            #expect(try store.engine(id: "missing")?.id == "winecx-b-x86_64")
            let engine = try #require(try store.engine())
            #expect(engine.root == store.location(of: "winecx-b-x86_64"))
            #expect(engine.backendDLLPaths[.dxmt]?.map(\.lastPathComponent) == ["dxmt-0.80"])
        }
    }
}
