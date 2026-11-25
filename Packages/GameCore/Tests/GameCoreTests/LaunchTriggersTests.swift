import Foundation
import Testing
@testable import GameCore

@Suite(.timeLimit(.minutes(1)))
struct LaunchTriggersTests {
    @Test func wakesWhenTheLogIsWrittenOrAppears() async throws {
        try await withTempDir { root in
            let file = root.appending(path: "logs/gameprocess_log.txt")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let triggers = LaunchTriggers(watching: file)
            defer { triggers.stop() }
            var events = triggers.events.makeAsyncIterator()

            // Not there yet: its folder is watched until it is.
            try Data("first\n".utf8).write(to: file)
            var woke = await events.next()
            #expect(woke != nil)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("second\n".utf8))
            try handle.close()
            woke = await events.next()
            #expect(woke != nil)
        }
    }

    @Test func wakesWhenAProgramExits() async throws {
        let triggers = LaunchTriggers(watching: URL(fileURLWithPath: "/nonexistent/log.txt"))
        defer { triggers.stop() }
        var events = triggers.events.makeAsyncIterator()
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.2"]
        try sleeper.run()
        triggers.watchExits(of: [sleeper.processIdentifier])
        let woke = await events.next()
        #expect(woke != nil)
        sleeper.waitUntilExit()
    }

    @Test func endsWhenStopped() async {
        let triggers = LaunchTriggers(watching: URL(fileURLWithPath: "/nonexistent/log.txt"))
        triggers.stop()
        var events = triggers.events.makeAsyncIterator()
        let woke = await events.next()
        #expect(woke == nil)
    }
}
