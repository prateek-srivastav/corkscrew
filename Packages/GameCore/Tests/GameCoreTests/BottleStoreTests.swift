import Foundation
import Testing
@testable import GameCore

struct BottleStoreTests {
    /// A runtime whose `wine` records its arguments and whose `wineserver` does nothing.
    private func recordingEngine(in root: URL) throws -> (Engine, URL) {
        let record = root.appending(path: "wine-arguments.txt")
        return (try engine(in: root, wine: "echo \"$@\" >> '\(record.path)'"), record)
    }

    /// A runtime whose `wine` runs `script` and whose `wineserver` does nothing.
    private func engine(in root: URL, wine script: String) throws -> Engine {
        let runtime = root.appending(path: "runtime")
        for (tool, script) in [("wine", script), ("wineserver", "exit 0")] {
            let file = runtime.appending(path: "bin/\(tool)")
            try file.write("#!/bin/sh\n\(script)\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return Engine(id: "winecx-test", root: runtime, architecture: .x86_64)
    }

    /// Seen 2026-10-14: Wine died while the Mac slept during `wineboot --init`. bottle.json was
    /// already saved, so the broken bottle counted as made and "Try Again" skipped it.
    @Test(arguments: ["kill -9 $$", "exit 1"])
    func failedSetupLeavesNoBottle(wine script: String) async throws {
        try await withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let engine = try engine(in: root, wine: script)
            let store = BottleStore(paths: paths, hostEnvironment: ["HOME": root.path])
            let bottle = Bottle(name: "Steam", kind: .standard, engineID: engine.id)

            await #expect {
                try await store.create(bottle, engine: engine)
            } throws: { error in
                guard case .setupFailed(_, let log) = error as? BottleStore.StoreError else { return false }
                return FileManager.default.fileExists(atPath: log)  // the log stays for the error message
            }
            #expect(try store.list().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.location(of: bottle).directory.path))
        }
    }

    @Test func bottleIsListedOnlyOnceWinebootSucceeds() async throws {
        try await withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let bottle = Bottle(name: "Steam", kind: .standard, engineID: "winecx-test")
            let store = BottleStore(paths: paths, hostEnvironment: ["HOME": root.path])
            let metadata = store.location(of: bottle).metadata
            let seen = root.appending(path: "seen.txt")
            let engine = try engine(in: root, wine: "[ -e '\(metadata.path)' ] && echo listed > '\(seen.path)'; exit 0")

            try await store.create(bottle, engine: engine)
            #expect(!FileManager.default.fileExists(atPath: seen.path))
            let listed = try store.list()
            #expect(listed.map(\.id) == [bottle.id])
            #expect(listed.first?.runtimeModules == RuntimeModules.fingerprint(runtime: engine.root))
        }
    }

    /// A plain `wineboot --update` also starts everything registered to run at Windows startup
    /// (Steam with -silent), so the setup session never ended and the launch waited forever.
    @Test func updatingABottleDoesNotStartItsStartupPrograms() async throws {
        try await withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let (engine, record) = try recordingEngine(in: root)
            let store = BottleStore(paths: paths, hostEnvironment: ["HOME": root.path])
            let bottle = Bottle(name: "Games", kind: .standard, engineID: engine.id)
            try store.save(bottle)
            try store.location(of: bottle).prefix.makeDirectory()

            let updated = try await store.update(bottle, engine: engine)
            #expect(try String(contentsOf: record, encoding: .utf8) == "wineboot --update --restart\n")
            #expect(updated.runtimeModules == RuntimeModules.fingerprint(runtime: engine.root))
        }
    }
}
