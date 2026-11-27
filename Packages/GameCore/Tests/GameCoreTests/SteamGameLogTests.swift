import Foundation
import Testing
@testable import GameCore

struct SteamGameLogTests {
    static let folder = #"C:\Program Files (x86)\Steam\steamapps\common\Red Dead Redemption 2\"#
    // RDR2 from Corkscrew on 2026-10-25, as Steam logged it: Steam started PlayRDR2.exe, which
    // started Rockstar's launcher, which started the game, which started its crash handler.
    static let started = """
        [2026-10-25 18:14:06] AppID 1174180 adding PID 940 as a tracked process ""\(folder)PlayRDR2.exe""
        [2026-10-25 18:14:06] SSGL: InternalUpdateClientGame indicates change to games list
        [2026-10-25 18:14:09] AppID 1174180 adding PID 948 as a tracked process ""C:\\Program Files\\Rockstar Games\\Launcher\\Launcher.exe" -skipPatcherCheck -steamAppId=1174180 -steamLocation "\(folder)" @args.txt"
        [2026-10-25 18:16:31] AppID 1174180 adding PID 300 as a tracked process ""\(folder)RDR2.exe" -skipPatcherCheck -useSteam"
        [2026-10-25 18:18:02] AppID 1174180 adding PID 608 as a tracked process ""\(folder)x64\\crashpad\\release\\crashpad_handler.exe" "--database=C:\\x""

        """
    // The quit from the game's menu: the game and its crash handler exit, Steam stops following the
    // launchers that still run, and ends the game.
    static let quit = """
        [2026-10-25 18:30:28] AppID 1174180 no longer tracking PID 608, exit code 0
        [2026-10-25 18:30:28] AppID 1174180 no longer tracking PID 300, exit code 0
        [2026-10-25 18:30:28] Game 1174180 going away; no longer tracking PID 940
        [2026-10-25 18:30:28] Game 1174180 going away; no longer tracking PID 948
        [2026-10-25 18:30:28] Remove 1174180 from running list

        """

    private func logFile(in root: URL, _ text: String = "") throws -> URL {
        let file = root.appending(path: "logs/gameprocess_log.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func followsTheProgramsSteamFollowsForTheGame() throws {
        try withTempDir { root in
            // The log holds the launches before this one.
            let file = try logFile(in: root, Self.started + Self.quit)
            var log = SteamGameLog(steamRoot: root, appID: "1174180")
            var changed = log.update()
            #expect(!changed)
            #expect(log.started.isEmpty && !log.hasEnded)

            // Other games, and an id that only starts like this one's, aren't it.
            try append("[2026-10-25 18:14:00] AppID 228980 adding PID 12 as a tracked process \"\"C:\\x.exe\"\"\n"
                       + "[2026-10-25 18:14:00] AppID 11741800 adding PID 13 as a tracked process \"\"C:\\y.exe\"\"\n", to: file)
            changed = log.update()
            #expect(!changed)

            try append(Self.started, to: file)
            changed = log.update()
            #expect(changed)
            #expect(log.programs.map(\.pid) == [940, 948, 300, 608])
            #expect(log.programs.map { $0.path.split(separator: "\\").last! } == ["PlayRDR2.exe", "Launcher.exe", "RDR2.exe", "crashpad_handler.exe"])
            #expect(log.programs[1].path == #"C:\Program Files\Rockstar Games\Launcher\Launcher.exe"#)
            #expect(!log.hasEnded)

            try append(Self.quit, to: file)
            changed = log.update()
            #expect(changed)
            #expect(log.programs.isEmpty && log.hasEnded)
            #expect(log.started.count == 4, "what the launch saw")

            // Started again (from Steam's library, say).
            try append(Self.started, to: file)
            log.update()
            #expect(!log.hasEnded && log.programs.count == 4)
        }
    }

    /// Steam's lines end with "\r\n", and at a quit it writes them all at once (2026-10-25 21:14:37).
    @Test func readsSteamsWindowsLineEnds() throws {
        try withTempDir { root in
            let file = try logFile(in: root)
            var log = SteamGameLog(steamRoot: root, appID: "1174180")
            try append(Self.started.replacingOccurrences(of: "\n", with: "\r\n"), to: file)
            log.update()
            #expect(log.programs.count == 4)
            try append(Self.quit.replacingOccurrences(of: "\n", with: "\r\n"), to: file)
            log.update()
            #expect(log.programs.isEmpty && log.hasEnded)
        }
    }

    /// Steam can end a game whose own program never ran: the launcher quit before starting it.
    @Test func aGameCanEndBeforeItsProgramRuns() throws {
        var log = SteamGameLog(steamRoot: URL(fileURLWithPath: "/nonexistent"), appID: "1174180")
        log.ingest("""
            [2026-10-25 18:04:49] AppID 1174180 adding PID 3076 as a tracked process ""\(Self.folder)PlayRDR2.exe""
            [2026-10-25 18:05:30] AppID 1174180 no longer tracking PID 3076, exit code 0
            """)
        #expect(log.programs.isEmpty && !log.hasEnded, "not until Steam says so")
        log.ingest("[2026-10-25 18:05:30] Remove 1174180 from running list")
        #expect(log.hasEnded)

        // An end Steam logs without having started the game in this launch isn't this launch's.
        var other = SteamGameLog(steamRoot: URL(fileURLWithPath: "/nonexistent"), appID: "1174180")
        other.ingest("[2026-10-25 18:05:30] Remove 1174180 from running list")
        #expect(!other.hasEnded)
    }

    @Test func readsALineOnlyOnceItIsComplete() throws {
        try withTempDir { root in
            let file = try logFile(in: root)
            var log = SteamGameLog(steamRoot: root, appID: "1174180")
            // Steam is in the middle of writing the line.
            try append("[2026-10-25 18:14:06] AppID 1174180 adding PID 940 as a tracked process \"\"C:\\Pl", to: file)
            var changed = log.update()
            #expect(!changed)
            try append("ayRDR2.exe\"\"\n", to: file)
            changed = log.update()
            #expect(changed)
            #expect(log.programs == [.init(pid: 940, path: #"C:\PlayRDR2.exe"#)])
        }
    }

    @Test func copesWithNoLogAndWithANewOne() throws {
        try withTempDir { root in
            // Steam hasn't written a log yet.
            var log = SteamGameLog(steamRoot: root, appID: "1174180")
            let changed = log.update()
            #expect(!changed)

            // The log appears with the game's lines.
            _ = try logFile(in: root, Self.started)
            log.update()
            #expect(log.programs.count == 4)

            // Steam starts a new log, shorter than what was read.
            var again = SteamGameLog(steamRoot: root, appID: "1174180")
            _ = try logFile(in: root, Self.quit)
            again.update()
            #expect(!again.hasEnded, "it never started the game")
        }
    }
}
