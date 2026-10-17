import Darwin
import Foundation
import Testing
@testable import GameCore

struct BackgroundProgramsTests {
    @Test func picksLaunchersNotGames() {
        let steam = #"c:\program files (x86)\steam\"#
        #expect(BackgroundPrograms.isBackground(steam + "steam.exe", sparing: []))
        #expect(BackgroundPrograms.isBackground(steam + #"bin\cef\cef.win7x64\steamwebhelper_real.exe"#, sparing: []))
        #expect(BackgroundPrograms.isBackground(#"c:\program files\rockstar games\launcher\launcher.exe"#, sparing: []))
        #expect(!BackgroundPrograms.isBackground(#"c:\games\some game\launcher.exe"#, sparing: []), "a game's own launcher")
        #expect(!BackgroundPrograms.isBackground(#"c:\windows\system32\winedevice.exe"#, sparing: []))
        #expect(!BackgroundPrograms.isBackground(steam + "steam.exe", sparing: ["steam.exe"]), "the game itself")
    }

    @Test func lowersAndRestoresAProcess() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let pid = sleeper.processIdentifier
        #expect(!BackgroundPrograms.isLowered(pid))
        #expect(setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) == 0)
        #expect(BackgroundPrograms.isLowered(pid))
        BackgroundPrograms.restore([pid])
        #expect(!BackgroundPrograms.isLowered(pid))
    }
}

/// Each test uses its own folders and never turns the exclusion on and then off again: macOS writes
/// it at once and again a moment later from a queue in this process (after it calls Spotlight, so
/// seconds later when Spotlight is busy). That late write of "on" could land after an "off".
struct BackupExclusionTests {
    static let games = ["Games", "Program Files (x86)/Steam/steamapps", "Program Files/Some Game"]

    /// A bottle with three game folders and the saves that must stay in backups; returns drive_c.
    static func makeBottle(_ prefix: URL) throws -> URL {
        let driveC = prefix.appending(path: "drive_c")
        let made = ["Program Files/Some Game", "Program Files (x86)/Steam/steamapps/common/Game", "Program Files (x86)/Steam/userdata",
                    "Games/Repack", "users/me/Documents"]
        for path in made { try driveC.appending(path: path).makeDirectory() }
        return driveC
    }

    /// Reads afresh: a URL keeps the resource values it has read.
    static func isExcluded(_ folder: URL) -> Bool {
        var folder = folder
        folder.removeAllCachedResourceValues()
        return (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
    }

    @Test func excludesInstallsButNotSaves() throws {
        try withTempDir { prefix in
            let driveC = try Self.makeBottle(prefix)
            #expect(BackupExclusion.gameFolders(prefix: prefix).map(\.path) == Self.games.map { driveC.appending(path: $0).path })

            #expect(BackupExclusion.apply(true, prefix: prefix).count == 3)
            for path in Self.games { #expect(Self.isExcluded(driveC.appending(path: path)), "\(path)") }
            for path in ["Program Files (x86)/Steam", "Program Files (x86)/Steam/userdata", "users"] {
                #expect(!Self.isExcluded(driveC.appending(path: path)), "\(path)")
            }
            #expect(BackupExclusion.apply(true, prefix: prefix).isEmpty, "already excluded")
        }
    }

    @Test func includesThemAgain() throws {
        try withTempDir { prefix in
            let driveC = try Self.makeBottle(prefix)
            // Excluded by an earlier run of the app: the attribute macOS writes, set directly (no late write).
            let marker = try PropertyListSerialization.data(fromPropertyList: "com.apple.backupd", format: .binary, options: 0)
            for path in Self.games {
                let set = marker.withUnsafeBytes {
                    setxattr(driveC.appending(path: path).path, "com.apple.metadata:com_apple_backup_excludeItem", $0.baseAddress, $0.count, 0, 0)
                }
                #expect(set == 0)
                #expect(Self.isExcluded(driveC.appending(path: path)), "\(path)")
            }

            #expect(BackupExclusion.apply(false, prefix: prefix).count == 3)
            for path in Self.games { #expect(!Self.isExcluded(driveC.appending(path: path)), "\(path)") }
            #expect(BackupExclusion.apply(false, prefix: prefix).isEmpty, "already included")
        }
    }
}
