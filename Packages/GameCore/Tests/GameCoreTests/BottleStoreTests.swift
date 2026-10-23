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
    private func engine(in root: URL, wine script: String, shell: String = "/bin/sh") throws -> Engine {
        let runtime = root.appending(path: "runtime")
        for (tool, script) in [("wine", script), ("wineserver", "exit 0")] {
            let file = runtime.appending(path: "bin/\(tool)")
            try file.write("#!\(shell)\n\(script)\n")
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

    /// The first launch used to make these settings itself, each in a Wine session it then waited
    /// out: 5 s before Steam's first start (2026-10-20).
    @Test(arguments: [false, true])
    func newBottleHasTheFirstLaunchsSettings(emulatedModes: Bool) async throws {
        try await withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let (engine, record) = try recordingEngine(in: root)
            if emulatedModes { try engine.root.appending(path: "lib/wine/x86_64-unix/win32u.so").write(ModeEmulation.marker) }
            let store = BottleStore(paths: paths, hostEnvironment: ["HOME": root.path])

            try await store.create(Bottle(name: "Steam", kind: .standard, engineID: engine.id), engine: engine)
            let commands = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
            #expect(commands.count == (emulatedModes ? 5 : 4))
            #expect(commands.first == "wineboot --init")
            #expect(commands.contains { $0.contains("ShowCrashDialog") && $0.hasSuffix("/d 0 /f") })
            #expect(commands.filter { $0.contains("AeDebug /v Debugger") && $0.hasSuffix("winedbg.txt 2>&1 /f") }.count == 2)
            #expect(commands.contains { $0.contains("EmulateModeset") && $0.hasSuffix("/d y /f") } == emulatedModes)
        }
    }

    /// An isolated bottle's first launch imported the Mac's root certificates in a Wine session of
    /// its own, then waited it out: 4 s before the program started (2026-10-20).
    @Test func newIsolatedBottleHasTheMacsRootCertificates() async throws {
        try await withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let store = BottleStore(paths: paths, hostEnvironment: ["HOME": root.path])
            let bottle = Bottle(name: "Offline Programs", kind: .isolated, engineID: "winecx-test")
            let location = store.location(of: bottle)
            // Setup runs in the sandbox: it starts only the runtime's programs (a re-signed copy of
            // dash for the script), and they write only into the bottle.
            let dash = try root.appending(path: "runtime/bin").makeDirectory().appending(path: "dash")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/dash"), to: dash)
            await exited(try Process.run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", dash.path]))
            let record = location.home.appending(path: "wine-arguments.txt")
            let imported = location.home.appending(path: "imported.reg")
            let file = HostRootCertificates.importFile(prefix: location.prefix)
            let engine = try engine(in: root, wine: """
                printf '%s\\n' "$*" >> '\(record.path)'
                if [ "$1" = regedit ]; then while IFS= read -r line; do printf '%s\\n' "$line"; done < '\(file.path)' > '\(imported.path)'; fi
                exit 0
                """, shell: dash.path)

            try await store.create(bottle, engine: engine)
            let commands = try String(contentsOf: record, encoding: .utf8).split(separator: "\n")
            #expect(commands.first == "wineboot --init")
            #expect(commands.last.map(String.init) == HostRootCertificates.importCommand.joined(separator: " "))
            let roots = HostRootCertificates.load()
            let registry = try String(contentsOf: imported, encoding: .utf8)
            #expect(!roots.isEmpty && roots.allSatisfy { registry.contains(HostRootCertificates.thumbprint($0)) })
            // The file is gone before the clean snapshot is taken.
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(!FileManager.default.fileExists(atPath: HostRootCertificates.importFile(prefix: location.cleanSnapshot).path))
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

    /// wineboot registers mscoree, which asks to download Wine Mono when it finds none. So setup
    /// turns mscoree off only for a runtime without Wine Mono.
    @Test func setupKeepsMscoreeOnlyWithTheRuntimesWineMono() async throws {
        try await withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let record = root.appending(path: "overrides.txt")
            let engine = try engine(in: root, wine: "echo \"$WINEDLLOVERRIDES\" >> '\(record.path)'")
            let store = BottleStore(paths: paths, hostEnvironment: ["HOME": root.path])
            let bottle = Bottle(name: "Games", kind: .standard, engineID: engine.id)
            try store.save(bottle)
            try store.location(of: bottle).prefix.makeDirectory()

            try await store.update(bottle, engine: engine)
            try engine.root.appending(path: "share/wine/mono/wine-mono-10.4.1").makeDirectory()
            try await store.update(bottle, engine: engine)
            #expect(try String(contentsOf: record, encoding: .utf8)
                == "mscoree=;mshtml=;winemenubuilder.exe=\nmshtml=;winemenubuilder.exe=\n")
        }
    }
}
