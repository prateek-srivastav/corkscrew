import Foundation
import Testing
@testable import GameCore

struct SteamGameLaunchTests {
    @Test func recognizesSteamAndAGamesPrograms() {
        #expect(BottleProcesses.isSteamClient(#"c:\program files (x86)\steam\steam.exe"#))
        #expect(!BottleProcesses.isSteamClient(#"c:\program files (x86)\steam\bin\cef\cef.win64\steamwebhelper.exe"#))
        // Steam as the app starts it: Wine keeps the Mac path of the program it was given.
        let started = BottleProcesses.Entry(pid: 1, arguments: ["/Users/me/Bottles/X/prefix/drive_c/Program Files (x86)/Steam/steam.exe", "-silent"])
        #expect(BottleProcesses.isSteamClient(started.program))
        // Open Steam waits for the web helper's window, not the updater window steam.exe shows first.
        #expect(BottleProcesses.Entry(pid: 2, arguments: [#"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe"#]).isSteamWebHelper)
        #expect(!started.isSteamWebHelper)
        let rdr2 = "Red Dead Redemption 2"
        #expect(BottleProcesses.isFromSteamGame(
            #"c:\program files (x86)\steam\steamapps\common\red dead redemption 2\rdr2.exe"#, installDir: rdr2))
        #expect(BottleProcesses.isFromSteamGame(#"d:\steamlibrary\steamapps\common\red dead redemption 2\playrdr2.exe"#,
                                                installDir: rdr2), "any library folder")
        #expect(!BottleProcesses.isFromSteamGame(#"c:\program files\rockstar games\launcher\launcher.exe"#, installDir: rdr2))
        #expect(!BottleProcesses.isFromSteamGame(
            #"c:\program files (x86)\steam\steamapps\common\red dead redemption 2 extra\x.exe"#, installDir: rdr2))
    }

    @Test func findsSteamsWebHelperRunningWithoutTheWrapper() {
        let cef = #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\"#
        let steam = BottleProcesses.Entry(pid: 1, arguments: [#"C:\Program Files (x86)\Steam\steam.exe"#])
        let main = BottleProcesses.Entry(pid: 2, arguments: [cef + "steamwebhelper.exe", "-nocrashdialog", "-steampid=368"])
        let gpu = BottleProcesses.Entry(pid: 3, arguments: [cef + "steamwebhelper.exe", "--type=gpu-process"])
        let real = BottleProcesses.Entry(pid: 4, arguments: [cef + "steamwebhelper_real.exe", "-nocrashdialog", "--disable-gpu"])
        let realChild = BottleProcesses.Entry(pid: 5, arguments: [cef + "steamwebhelper_real.exe", "--type=utility"])
        #expect(Launcher.unwrappedWebHelpers([steam, main, gpu]) == [main, gpu])
        #expect(Launcher.unwrappedWebHelpers([steam, main, real, realChild]).isEmpty, "through the wrapper")
        #expect(Launcher.unwrappedWebHelpers([steam, main]).isEmpty, "the wrapper alone, before it starts the real helper")
    }

    @Test func readsAProcesssArgumentsAndEnvironment() throws {
        let process = try #require(BottleProcesses.processArguments(of: getpid()))
        #expect(process.arguments.first == CommandLine.arguments.first)
        #expect(process.environment["HOME"] == ProcessInfo.processInfo.environment["HOME"])
    }

    @Test func knowsASteamGamesLaunch() throws {
        try withTempDir { prefix in
            let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
            try steam.appending(path: "steam.exe").write(PEBuilder().build())
            try steam.appending(path: "steamapps/appmanifest_1174180.acf").write(
                "\"AppState\"\n{\n\t\"appid\"\t\t\"1174180\"\n\t\"name\"\t\t\"Red Dead Redemption 2\"\n\t\"installdir\"\t\t\"Red Dead Redemption 2\"\n}")
            let client = steam.appending(path: "steam.exe")

            let game = try #require(Launcher.steamGameLaunch(
                executable: client, arguments: ["-noverifyfiles", "-silent", "-applaunch", "1174180"], prefix: prefix))
            #expect(game == Launcher.SteamGameLaunch(appID: "1174180", steamRoot: client.deletingLastPathComponent(), startsSteam: true),
                    "no Steam runs in the bottle")
            #expect(Launcher.driveCFolder(game.steamRoot, prefix: prefix) == #"\program files (x86)\steam\"#)
            #expect(Launcher.steamGameLaunch(executable: client, arguments: ["-silent"], prefix: prefix) == nil, "Steam itself")
            #expect(Launcher.steamGameLaunch(executable: client, arguments: ["-applaunch", "999"], prefix: prefix) == nil)
        }
    }

    /// Steam quits after the game only when the launch started it, Steam ended the game, and no
    /// other Steam game runs.
    @Test func quitsSteamItStartedOnceTheGameEnds() {
        let root = URL(fileURLWithPath: "/tmp/bottle/prefix/drive_c/Program Files (x86)/Steam")
        let started = Launcher.SteamGameLaunch(appID: "1174180", steamRoot: root, startsSteam: true)
        let opened = Launcher.SteamGameLaunch(appID: "1174180", steamRoot: root, startsSteam: false)
        #expect(Launcher.quitsSteam(after: started, gameEnded: true, running: [:]))
        #expect(Launcher.quitsSteam(after: started, gameEnded: true, running: ["1174180": [42]]),
                "a program of this game that stays doesn't keep Steam")
        #expect(Launcher.quitsSteam(after: started, gameEnded: true, running: ["730": []]))
        #expect(!Launcher.quitsSteam(after: opened, gameEnded: true, running: [:]), "the player opened Steam")
        #expect(!Launcher.quitsSteam(after: started, gameEnded: false, running: [:]), "Steam quit or crashed itself")
        #expect(!Launcher.quitsSteam(after: started, gameEnded: true, running: ["730": [7]]), "another game runs")
    }

    /// A launcher can start the game and quit; the launch follows the programs from its folder,
    /// which Wine shows as `c:\…` or, for the first program, the Mac path.
    @Test func knowsAGamesFolderUnderDriveC() {
        let prefix = URL(fileURLWithPath: "/tmp/bottle/prefix")
        let folder = Launcher.gameFolder(of: prefix.appending(path: "drive_c/Program Files (x86)/EA Games/FIFA 23/Launcher.exe"), prefix: prefix)
        #expect(folder == #"\program files (x86)\ea games\fifa 23\"#)
        #expect(#"c:\program files (x86)\ea games\fifa 23\fifa23.exe"#.contains(folder!))
        #expect(!#"c:\program files (x86)\ea games\fifa 23 demo\fifa23.exe"#.contains(folder!))
        #expect(Launcher.gameFolder(of: prefix.appending(path: "drive_c/setup.exe"), prefix: prefix) == nil, "drive_c itself")
        #expect(Launcher.gameFolder(of: URL(fileURLWithPath: "/Users/me/Downloads/setup.exe"), prefix: prefix) == nil)
    }

    /// After Steam ends RDR2, its launcher and Social Club close by themselves, a few seconds apart.
    /// What closes is what didn't run when Steam started the game, apart from Wine's and Steam's own.
    @Test func knowsWhatAGameLeavesRunning() {
        let entries = [
            // When Steam started the game.
            (1, "/Users/me/Bottles/X/prefix/drive_c/Program Files (x86)/Steam/steam.exe"),
            (2, #"C:\windows\system32\explorer.exe"#),
            // Since.
            (3, #"C:\windows\system32\conhost.exe"#),
            (4, #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper_real.exe"#),
            (5, #"C:\Program Files (x86)\Steam\gameoverlayui.exe"#),
            (6, #"C:\Program Files (x86)\Steam\steamapps\common\Red Dead Redemption 2\PlayRDR2.exe"#),
            (7, #"C:\Program Files\Rockstar Games\Launcher\Launcher.exe"#),
            (8, #"C:\Program Files\Rockstar Games\Social Club\SocialClubHelper.exe"#),
        ].map { BottleProcesses.Entry(pid: pid_t($0.0), arguments: [$0.1]) }
        let left = Launcher.leftovers(entries, before: [1, 2], steamFolder: #"\program files (x86)\steam\"#)
        #expect(left.map(\.pid) == [6, 7, 8])
        #expect(Launcher.isSteamInterface(entries[0]) && Launcher.isSteamInterface(entries[3]))
        #expect(!Launcher.isSteamInterface(entries[4]))
    }

    /// The name a program shows with: its description, as Task Manager shows it, else its file's.
    @Test func namesAProgramForTheUser() throws {
        try withTempDir { prefix in
            let drive = try prefix.appending(path: "drive_c/Program Files/Rockstar Games/Launcher").makeDirectory()
            try FileManager.default.createDirectory(at: prefix.appending(path: "dosdevices"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/c:").path, withDestinationPath: "../drive_c")
            var pe = PEBuilder()
            pe.resources = [16: [(id: 1, data: PEVersionTests.versionInfo(description: "Rockstar Games Launcher"))]]
            try drive.appending(path: "Launcher.exe").write(pe.build())
            #expect(Launcher.programName(#"C:\Program Files\Rockstar Games\Launcher\Launcher.exe"#, prefix: prefix) == "Rockstar Games Launcher")
            #expect(Launcher.programName(#"c:\program files\rockstar games\launcher\launcher.exe"#, prefix: prefix) == "Rockstar Games Launcher",
                    "as the bottle's process list has it")
            #expect(Launcher.programName(#"C:\Games\crashpad_handler.exe"#, prefix: prefix) == "crashpad_handler")
        }
    }
}
