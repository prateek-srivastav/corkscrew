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

struct BackupExclusionTests {
    @Test func excludesInstallsButNotSaves() throws {
        try withTempDir { prefix in
            let driveC = prefix.appending(path: "drive_c")
            let made = ["Program Files/Some Game", "Program Files (x86)/Steam/steamapps/common/Game", "Program Files (x86)/Steam/userdata",
                        "Games/Repack", "users/me/Documents"]
            for path in made { try FileManager.default.createDirectory(at: driveC.appending(path: path), withIntermediateDirectories: true) }
            let expected = ["Games", "Program Files (x86)/Steam/steamapps", "Program Files/Some Game"].map { driveC.appending(path: $0).path }
            #expect(BackupExclusion.gameFolders(prefix: prefix).map(\.path) == expected)

            func isExcluded(_ path: String) -> Bool {
                (try? driveC.appending(path: path).resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
            }
            #expect(BackupExclusion.apply(true, prefix: prefix).count == 3)
            #expect(isExcluded("Program Files/Some Game") && isExcluded("Program Files (x86)/Steam/steamapps") && isExcluded("Games"))
            #expect(!isExcluded("Program Files (x86)/Steam") && !isExcluded("Program Files (x86)/Steam/userdata") && !isExcluded("users"))
            #expect(BackupExclusion.apply(true, prefix: prefix).isEmpty, "already excluded")
            #expect(BackupExclusion.apply(false, prefix: prefix).count == 3)
            #expect(!isExcluded("Program Files/Some Game"))
        }
    }
}
