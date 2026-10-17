import Darwin
import Foundation
import Testing
@testable import GameCore

struct WineServerTests {
    /// A process that holds a write lock on `file`, as a wineserver holds its `lock`. The test process
    /// can't stand in: F_GETLK doesn't report a process's own locks. It makes a marker file once it
    /// has the lock, which the test polls (a blocking read would hold one of the tests' threads).
    static func lockHolder(_ file: URL) async throws -> Process {
        let marker = FileManager.default.temporaryDirectory.appending(path: "GameCoreTests-locked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", "import fcntl,sys,time; f=open(sys.argv[1],'w'); fcntl.lockf(f, fcntl.LOCK_EX, 1); open(sys.argv[2],'w').close(); time.sleep(30)",
                             file.path, marker.path]
        try process.run()
        while process.isRunning, !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        return process
    }

    static var hasPython: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") }

    @Test(.enabled(if: hasPython)) func seesTheServersLock() async throws {
        try await withTempDir { dir in
            let server = try dir.appending(path: "server-1-2").makeDirectory()
            #expect(!WineServer.isLocked(server), "no lock file")
            try Data().write(to: server.appending(path: "lock"))
            #expect(!WineServer.isLocked(server), "a lock file no one holds")
            let holder = try await Self.lockHolder(server.appending(path: "lock"))
            defer { holder.terminate() }
            #expect(WineServer.isLocked(server))
        }
    }

    @Test(.enabled(if: hasPython)) func removesOnlyDeadServersFolders() async throws {
        try await withTempDir { base in
            func folder(_ name: String, age: TimeInterval) throws -> URL {
                let server = try base.appending(path: name).makeDirectory()
                try Data().write(to: server.appending(path: "lock"))
                try Data().write(to: server.appending(path: "socket"))
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: server.path)
                return server
            }
            let dead = try folder("server-1-1", age: 3600)
            let live = try folder("server-1-2", age: 3600)
            let starting = try folder("server-1-3", age: 5)
            let other = try base.appending(path: "tmp-other").makeDirectory()
            let holder = try await Self.lockHolder(live.appending(path: "lock"))
            defer { holder.terminate() }
            #expect(WineServer.removeStaleDirectories(base: base).map(\.lastPathComponent) == [dead.lastPathComponent])
            for kept in [live, starting, other] { #expect(FileManager.default.fileExists(atPath: kept.path)) }
        }
    }

    @Test func stopsProgramsWhoseServerIsGone() async throws {
        try await withTempDir { dir in
            let sleep = try await signedSleep(in: dir)
            let prefix = try dir.appending(path: "prefix").makeDirectory()
            let base = try dir.appending(path: "wine-base").makeDirectory()
            let process = Process()
            process.executableURL = sleep
            process.arguments = ["30"]
            process.environment = ["WINEPREFIX": prefix.path]
            try process.run()
            defer { process.terminate() }
            let stopped = await WineServer.stopOrphans(prefix: prefix, base: base, confirm: .milliseconds(200))
            #expect(stopped == [process.processIdentifier])
            await exited(process)
            #expect(process.terminationReason == .uncaughtSignal)
            #expect(await WineServer.stopOrphans(prefix: prefix, base: base, confirm: .milliseconds(200)).isEmpty)
        }
    }

    @Test(.enabled(if: hasPython)) func leavesALiveServersProgramsAlone() async throws {
        try await withTempDir { dir in
            let sleep = try await signedSleep(in: dir)
            let prefix = try dir.appending(path: "prefix").makeDirectory()
            let base = try dir.appending(path: "wine-base").makeDirectory()
            let server = try WineServer.directory(forPrefix: prefix, base: base).makeDirectory()
            try Data().write(to: server.appending(path: "lock"))
            let holder = try await Self.lockHolder(server.appending(path: "lock"))
            defer { holder.terminate() }
            let process = Process()
            process.executableURL = sleep
            process.arguments = ["30"]
            process.environment = ["WINEPREFIX": prefix.path]
            try process.run()
            defer { process.terminate() }
            #expect(await WineServer.stopOrphans(prefix: prefix, base: base, confirm: .milliseconds(200)).isEmpty)
            #expect(process.isRunning)
        }
    }
}
