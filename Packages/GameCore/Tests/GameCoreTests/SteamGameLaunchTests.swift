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

    /// What a Steam game's launch saw run, for its crash dumps: the game's programs, not Steam's.
    @Test func namesASteamGamesPrograms() {
        let processes = [
            BottleProcesses.Entry(pid: 1, arguments: [#"C:\Program Files (x86)\Steam\steam.exe"#, "-applaunch", "1174180"]),
            BottleProcesses.Entry(pid: 2, arguments: [#"C:\Program Files (x86)\Steam\steamapps\common\Red Dead Redemption 2\PlayRDR2.exe"#]),
            BottleProcesses.Entry(pid: 3, arguments: [#"C:\Program Files (x86)\Steam\steamapps\common\Red Dead Redemption 2\RDR2.exe"#, "-x"]),
            BottleProcesses.Entry(pid: 4, arguments: [#"C:\Program Files\Rockstar Games\Launcher\Launcher.exe"#]),
        ]
        #expect(Launcher.steamGamePrograms(processes, installDir: "Red Dead Redemption 2") == ["playrdr2.exe", "rdr2.exe"])
        #expect(Launcher.steamGamePrograms(processes, installDir: "Other Game").isEmpty)
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

    @Test func knowsASteamGamesFolderAndLauncher() throws {
        try withTempDir { prefix in
            let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
            try steam.appending(path: "steam.exe").write(PEBuilder().build())
            try steam.appending(path: "steamapps/appmanifest_1174180.acf").write(
                "\"AppState\"\n{\n\t\"appid\"\t\t\"1174180\"\n\t\"name\"\t\t\"Red Dead Redemption 2\"\n\t\"installdir\"\t\t\"Red Dead Redemption 2\"\n}")
            let folder = steam.appending(path: "steamapps/common/Red Dead Redemption 2")
            try folder.appending(path: "Redistributables/Rockstar-Games-Launcher.exe").write(PEBuilder().build())
            let client = steam.appending(path: "steam.exe")

            let game = try #require(Launcher.steamGameLaunch(
                executable: client, arguments: ["-noverifyfiles", "-silent", "-applaunch", "1174180"], prefix: prefix))
            #expect(game == Launcher.SteamGameLaunch(installDir: "Red Dead Redemption 2", steamWasRunning: false,
                                                     usesRockstarLauncher: true))
            #expect(Launcher.steamGameLaunch(executable: client, arguments: ["-silent"], prefix: prefix) == nil, "Steam itself")
            #expect(Launcher.steamGameLaunch(executable: client, arguments: ["-applaunch", "999"], prefix: prefix) == nil)
        }
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

    /// Steam's close button hides its window and keeps Steam in the tray; that counts as closed
    /// once it lasts. Before its first window, and while minimized (`.open`), it doesn't.
    @Test func steamIsClosedOnceItsWindowStaysGone() async throws {
        var looks: [Launcher.SteamLook] = [.noWindow, .noWindow, .noWindow, .open, .open]
        let closed = try await Launcher.waitForSteamToBeClosed(grace: .milliseconds(30), poll: .milliseconds(10)) {
            looks.isEmpty ? .noWindow : looks.removeFirst()
        }
        #expect(closed)
        #expect(looks.isEmpty, "not before the first window")

        // Quit from its own menu, or restarting: one miss is a restart, two are a quit.
        var quitLooks: [Launcher.SteamLook] = [.open, .notRunning, .open, .notRunning, .notRunning]
        let quit = try await Launcher.waitForSteamToBeClosed(grace: .seconds(60), poll: .milliseconds(10)) {
            quitLooks.removeFirst()
        }
        #expect(!quit)
        #expect(quitLooks.isEmpty)
    }

    @Test func installsTheWindowHelperOnTheBottlesDrive() throws {
        try withTempDir { root in
            let helper = root.appending(path: "visible-windows.exe")
            try helper.write(PEBuilder().build())
            let prefix = try root.appending(path: "prefix").makeDirectory()
            #expect(try Launcher.installVisibleWindowsHelper(helper, prefix: prefix) == #"C:\ProgramData\Corkscrew\visible-windows.exe"#)
            #expect(FileManager.default.contentsEqual(
                atPath: helper.path, andPath: prefix.appending(path: "drive_c/ProgramData/Corkscrew/visible-windows.exe").path))
            #expect(try Launcher.installVisibleWindowsHelper(helper, prefix: prefix) == #"C:\ProgramData\Corkscrew\visible-windows.exe"#)
        }
    }

    @Test func aGameHasQuitOnceItsProgramsStayGone() async throws {
        // Checks elapsed time, not poll counts: on a busy CI runner a 10 ms sleep can take far longer
        // (over 5 s once), so the timeout for the programs to appear is long.
        let clock = ContinuousClock()

        // Seen for three polls, then gone: quit after the grace period.
        var polls = 0
        var lastSeen = clock.now
        try await Launcher.waitForQuit(poll: .milliseconds(10)) {
            polls += 1
            guard (2...4).contains(polls) else { return polls > 4 ? .milliseconds(30) : .seconds(60) }
            lastSeen = clock.now
            return nil
        }
        #expect(polls > 4)
        #expect(clock.now - lastSeen >= .milliseconds(30), "waited out the grace period")

        // A restart within the grace period doesn't count as quitting. The grace is generous so the
        // two-poll gap stays inside it on a slow machine.
        polls = 0
        try await Launcher.waitForQuit(poll: .milliseconds(10)) {
            polls += 1
            guard polls == 1 || (4...6).contains(polls) else { return .milliseconds(500) }
            lastSeen = clock.now
            return nil
        }
        #expect(polls > 6, "the second run is the one that ended")
        #expect(clock.now - lastSeen >= .milliseconds(500))

        // Never started: the timeout counts from the start.
        let start = clock.now
        try await Launcher.waitForQuit(poll: .milliseconds(10)) { .milliseconds(50) }
        #expect(clock.now - start >= .milliseconds(50))
    }

    // Process lists from RDR2's launches (2026-10-21), as `ps` showed them.
    static let steam = [
        BottleProcesses.Entry(pid: 1, arguments: ["/Users/me/Bottles/X/prefix/drive_c/Program Files (x86)/Steam/steam.exe", "-silent"]),
        BottleProcesses.Entry(pid: 2, arguments: [#"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe"#, "-nocrashdialog"]),
        BottleProcesses.Entry(pid: 3, arguments: [#"C:\Program Files (x86)\Common Files\Steam\steamservice.exe"#, "/RunAsService"]),
        BottleProcesses.Entry(pid: 4, arguments: [#"C:\windows\system32\explorer.exe"#, "/desktop"]),
    ]
    static let rdr2Folder = #"C:\Program Files (x86)\Steam\steamapps\common\Red Dead Redemption 2\"#
    static let rdr2 = Launcher.SteamGameLaunch(installDir: "Red Dead Redemption 2", steamWasRunning: true, usesRockstarLauncher: true)

    static func running(_ programs: String...) -> [BottleProcesses.Entry] {
        steam + programs.enumerated().map { index, line in
            // The program, then its arguments: `name.exe /a /b`.
            let split = line.range(of: ".exe ").map { [String(line[..<$0.lowerBound]) + ".exe"] + line[$0.upperBound...].split(separator: " ").map(String.init) }
            return BottleProcesses.Entry(pid: pid_t(100 + index), arguments: split ?? [line])
        }
    }

    /// Follows a launch through `looks`: the phase each shows, and when the wait would end.
    static func follow(_ looks: [[BottleProcesses.Entry]], game: Launcher.SteamGameLaunch = rdr2)
        -> (phases: [Launcher.LaunchPhase], graces: [Duration?]) {
        var started = false
        let looks = looks.map { Launcher.SteamGameLook($0, installDir: game.installDir, usesRockstarLauncher: game.usesRockstarLauncher) }
        return (looks.map(\.phase), looks.map { $0.grace(started: &started, usesRockstarLauncher: game.usesRockstarLauncher) })
    }

    /// RDR2's first launch: Steam runs its install script and the game's installers for minutes
    /// before the game starts. They aren't the game: the launch waited 10 s after the Rockstar
    /// launcher's installer and closed Steam during DirectX's.
    @Test func aFirstLaunchWaitsForSteamsInstallers() {
        let script = #"C:\Program Files (x86)\Steam\bin\SteamService.exe /installscript "# + Self.rdr2Folder
        let redist = #"C:\Program Files (x86)\Steam\steamapps\common\Steamworks Shared\_CommonRedist\"#
        let looks = [
            Self.running(script, Self.rdr2Folder + #"Redistributables\Social-Club-Setup.exe /silent"#),
            Self.running(script, Self.rdr2Folder + #"Redistributables\Rockstar-Games-Launcher.exe /s /t"#,
                         #"C:\Program Files\Rockstar Games\Launcher\Redistributables\VCRed\vc_redist.x86.exe /install /norestart /quiet"#),
            Self.running(script, Self.rdr2Folder + #"Redistributables\Rockstar-Games-Launcher.exe /s /t"#,
                         #"C:\Program Files\Rockstar Games\Launcher\RockstarService.exe install"#),
            Self.running(script, #"C:\windows\system32\cmd.exe /s/c"#, redist + #"vcredist\2017\vc_redist.x86.exe /q /norestart"#),
            Self.running(script, redist + #"DirectX\Jun2010\DXSETUP.exe /silent"#),
        ]
        #expect(!Launcher.steamGamePrograms(looks[1], installDir: "Red Dead Redemption 2").isEmpty, "what the launch took for the game")
        let (phases, graces) = Self.follow(looks)
        #expect(phases == Array(repeating: .installing, count: 5))
        #expect(graces == Array(repeating: nil, count: 5))
        // Then Steam starts the game: in the gap, the launch waits as long as for Steam to start it.
        #expect(Self.follow([Self.running()]).graces == [Launcher.gameStartTimeout])
    }

    /// RDR2's second launch: Rockstar's launcher updated itself. `PlayRDR2.exe` (which waits for the
    /// launcher) quit with the old launcher, and the launch ended 10 s later, while the new one ran.
    @Test func aLaunchWaitsWhileRockstarsLauncherUpdatesItself() {
        let launcher = #"C:\Program Files\Rockstar Games\Launcher\"#
        let looks = [
            Self.running(Self.rdr2Folder + "PlayRDR2.exe", launcher + "Launcher.exe -skipPatcherCheck -steamAppId=1174180",
                         launcher + "RockstarService.exe start"),
            Self.running(launcher + "Launcher.exe -upgrade", launcher + "RockstarService.exe start"),
            Self.running(launcher + "Launcher.exe -upgrade", launcher + #"ThirdParty\Crashpad\RockstarErrorHandler.exe"#,
                         #"C:\Program Files\Rockstar Games\Social Club\SocialClubHelper.exe --allow-file-access-from-files"#),
            Self.running(Self.rdr2Folder + "PlayRDR2.exe", launcher + "Launcher.exe -skipPatcherCheck"),
        ]
        let (phases, graces) = Self.follow(looks)
        #expect(phases == Array(repeating: .rockstar, count: 4))
        #expect(graces == Array(repeating: nil, count: 4))
    }

    /// While Steam gets the game ready, a window it opens comes forward (RDR2 ran on another
    /// computer: Steam asked, behind Corkscrew, for 4 minutes). Steam's windows are its client's and
    /// its interface's, not its service's.
    @Test func knowsSteamsOwnPrograms() {
        let real = #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper_real.exe -nocrashdialog"#
        let look = Launcher.SteamGameLook(Self.running(real, Self.rdr2Folder + "PlayRDR2.exe"),
                                          installDir: Self.rdr2.installDir, usesRockstarLauncher: true)
        #expect(look.steam.map(\.pid) == [1, 2, 100])
        #expect(look.rockstar.map(\.pid) == [101])
    }

    /// A warm launch, and a quit from the game's menu: Play shows again once `RDR2.exe` and its crash
    /// handler are gone, while the launcher still saves to the cloud.
    @Test func aRockstarGameHasQuitOnceItsOwnProgramsAreGone() {
        let launcher = #"C:\Program Files\Rockstar Games\Launcher\Launcher.exe -skipPatcherCheck"#
        let helper = #"C:\Program Files\Rockstar Games\Social Club\SocialClubHelper.exe --type=renderer"#
        let play = Self.rdr2Folder + "PlayRDR2.exe"
        let game = Self.rdr2Folder + "RDR2.exe -skipPatcherCheck"
        let crashpad = Self.rdr2Folder + #"x64\crashpad\release\crashpad_handler.exe --attachment=x"#
        let (phases, graces) = Self.follow([
            Self.running(), Self.running(play), Self.running(play, launcher), Self.running(play, launcher, helper),
            Self.running(play, launcher, helper, game), Self.running(play, launcher, helper, game, crashpad),
            Self.running(play, launcher, helper, crashpad), Self.running(play, launcher, helper),
        ])
        #expect(phases == [.steam, .rockstar, .rockstar, .rockstar, .loading, .loading, .loading, .rockstar])
        #expect(graces == [Launcher.gameStartTimeout, nil, nil, nil, nil, nil, nil, .zero])

        // Other games can restart themselves: they keep the grace period.
        let other = Launcher.SteamGameLaunch(installDir: "Other", steamWasRunning: true, usesRockstarLauncher: false)
        let folder = #"C:\Program Files (x86)\Steam\steamapps\common\Other\"#
        #expect(Self.follow([Self.running(folder + "PlayOther.exe"), Self.running()], game: other).graces == [nil, Launcher.gameQuitGrace])
    }
}
