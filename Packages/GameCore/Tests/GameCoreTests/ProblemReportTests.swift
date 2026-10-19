import Foundation
import Testing
@testable import GameCore

struct ProblemReportTests {
    /// What Wine and winedbg print when a program crashes and the crash dialog is off.
    static let crash = """
        0024:err:module:import_dll Loading library xinput9_1_0.dll failed
        wine: Unhandled page fault on read access to 0000000000000010 at address 00000001428AA602 (thread 0180), starting debugger...
        0184:fixme:dbghelp:elf_search_auxv can't find symbol in module
        Unhandled exception: page fault on read access to 0x0000000000000010 in 64-bit code (0x00000001428aa602).
        Register dump:
         rip:00000001428aa602 rsp:000000000011f9e0 rbp:000000000011fa80 eflags:00010246 (  R- --  I  Z- -P- )
        Stack dump:
        0x000000000011f9e0:  0000000000000000 0000000000000001
        Backtrace:
        =>0 0x00000001428aa602 in game (+0x28aa602) (0x000000000011fa80)
          1 0x0000000140001234 in game (+0x1234) (0x0000000000000000)
        0x00000001428aa602 game+0x28aa602: movq 0x10(%rax),%rcx
        Modules:
        Module\tAddress\t\t\t\t\tDebug info\tName (1 modules)
        PE\t        140000000-        14a000000\tDeferred        game
        Threads:
        process  tid      prio    name (all IDs are in hex)
        System information:
            Wine build: wine-11.0
            Platform: x86_64
            Version: Windows 10
            Host system: Darwin
            Host version: 25.0.0
        0024:fixme:ntdll:NtQuerySystemInformation info_class SYSTEM_PERFORMANCE_INFORMATION
        """

    @Test func findsWinesBacktrace() throws {
        let crash = try #require(ProblemReport.crash(in: Self.crash))
        #expect(crash.summary.hasPrefix("Unhandled exception: page fault on read access"))
        #expect(crash.backtrace.contains("=>0 0x00000001428aa602 in game (+0x28aa602)"))
        #expect(crash.backtrace.hasSuffix("Host version: 25.0.0"))
        #expect(!crash.backtrace.contains("SYSTEM_PERFORMANCE_INFORMATION"))
    }

    @Test func readsWindowsLineEnds() throws {
        let crash = try #require(ProblemReport.crash(in: Self.crash.replacingOccurrences(of: "\n", with: "\r\n")))
        #expect(crash.backtrace.contains("Backtrace:"))
    }

    @Test func noCrashNoReport() {
        #expect(ProblemReport.crash(in: "0024:fixme:heap:RtlSetHeapInformation\nexit 0\n") == nil)
    }

    /// Steam restarts its web pages when they crash; the program's own crash before it counts.
    @Test func skipsCrashesOfSteamsWebHelper() throws {
        let helper = Self.crash.replacingOccurrences(of: "in game", with: "in libcef")
        #expect(ProblemReport.crash(in: helper) == nil)
        let crash = try #require(ProblemReport.crash(in: Self.crash + "\n" + helper))
        #expect(crash.backtrace.contains("in game (+0x28aa602)"))
    }

    @Test func callsToMissingFunctionsAreCrashes() throws {
        let log = "wine: Call from 00006FFFFFC0A1B2 to unimplemented function api-ms-win-core-sysinfo-l1-2-3.dll.GetIntegratedDisplaySize, aborting"
        #expect(try #require(ProblemReport.crash(in: log)).summary.contains("GetIntegratedDisplaySize"))
    }

    @Test func readsTheEndOfALargeLog() throws {
        try withTempDir { dir in
            let log = dir.appending(path: "launch.log")
            try (String(repeating: "0024:trace:x:y padding line\n", count: 20_000) + Self.crash).write(to: log, atomically: true, encoding: .utf8)
            #expect(ProblemReport.crash(inLog: log, maxBytes: 64 << 10) != nil)
            let tail = try #require(ProblemReport.logTail(of: log, lines: 5))
            #expect(tail.split(separator: "\n").count == 5)
            #expect(tail.hasSuffix("SYSTEM_PERFORMANCE_INFORMATION"))
        }
    }

    /// The end of a real log (2026-10-19, WINEDEBUG=-all,+msgbox): a game couldn't bind 127.0.0.1 in
    /// a bottle without network, showed this message box, and quit with exit code 255.
    static let dialog = """
        Parsing C:\\Program Files (x86)\\Game\\game.cfg.
        00d0:trace:msgbox:MSGBOX_OnInit L"bind: Access denied.: Access denied."
        Exception: bind: Access denied.: Access denied.
        """

    @Test func findsTheLastErrorDialog() throws {
        #expect(ProblemReport.errorDialog(in: Self.dialog) == "bind: Access denied.: Access denied.")
        // With Wine's +pid and +timestamp, and Windows line ends.
        let later = "1234.567:0020:0024:trace:msgbox:MSGBOX_OnInit L\"Failed to create the Direct3D device.\"\r\n0024:fixme:d3d:x\r\n"
        #expect(ProblemReport.errorDialog(in: Self.dialog + "\n" + later) == "Failed to create the Direct3D device.")
        try withTempDir { dir in
            let log = dir.appending(path: "launch.log")
            try (String(repeating: "padding line\n", count: 20_000) + Self.dialog).write(to: log, atomically: true, encoding: .utf8)
            #expect(ProblemReport.errorDialog(inLog: log, maxBytes: 64 << 10) == "bind: Access denied.: Access denied.")
        }
    }

    /// Wine's quoting: escapes, characters outside ASCII as UTF-16 hex, and `...` for a cut text.
    @Test func readsWinesQuotedText() {
        let line = #"00d0:trace:msgbox:MSGBOX_OnInit L"Can't load\nC:\\Games\\x.dll: \"missing\"\r\n\t\00e9t\00e9 \d83d\de00"..."#
        #expect(ProblemReport.errorDialog(in: line) == "Can't load C:\\Games\\x.dll: \"missing\" été 😀…")
    }

    @Test func noDialogOrAQuestionNoReport() {
        #expect(ProblemReport.errorDialog(in: "Exception: bind: Access denied.\n") == nil)
        // The player answered a question (a setup's "Exit Setup?"): quitting was their choice.
        let question = "0024:trace:msgbox:MSGBOX_OnInit L\"Setup is not complete.\\n\\nExit Setup?\""
        #expect(ProblemReport.errorDialog(in: Self.dialog + "\n" + question) == nil)
        #expect(ProblemReport.errorDialog(in: question + "\n" + Self.dialog) == "bind: Access denied.: Access denied.")
    }

    /// A minidump with only what the reader uses: a module list, and an exception unless nil, with
    /// an access violation's parameters (a write to `wrote`).
    static func minidump(_ modules: [(path: String, base: UInt64, size: UInt32)],
                         exception: (code: UInt32, address: UInt64)? = (0xc000_0005, 0x1_427c_2fc9), wrote: UInt64 = 0) -> Data {
        var bytes: [UInt8] = []
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        let streams = exception == nil ? 1 : 2
        let list = 32 + 12 * streams, names = list + 4 + 108 * modules.count
        let exceptionStream = names + modules.reduce(0) { $0 + 4 + 2 * $1.path.utf16.count }
        bytes += "MDMP".utf8
        put(UInt32(0xa793)); put(UInt32(streams)); put(UInt32(32)); put(UInt32(0)); put(UInt32(0)); put(UInt64(0))
        put(UInt32(4)); put(UInt32(names - list)); put(UInt32(list))
        if exception != nil { put(UInt32(6)); put(UInt32(168)); put(UInt32(exceptionStream)) }
        put(UInt32(modules.count))
        var name = names
        for module in modules {
            put(module.base); put(module.size); put(UInt32(0)); put(UInt32(0)); put(UInt32(name))
            bytes += [UInt8](repeating: 0, count: 108 - 24)
            name += 4 + 2 * module.path.utf16.count
        }
        for module in modules {
            put(UInt32(2 * module.path.utf16.count))
            module.path.utf16.forEach { put($0) }
        }
        if let exception {
            put(UInt32(0x1a0)); put(UInt32(0)); put(exception.code); put(UInt32(0)); put(UInt64(0)); put(exception.address)
            put(UInt32(2)); put(UInt32(0)); put(UInt64(1)); put(wrote)
            bytes += [UInt8](repeating: 0, count: 168 - 56)
        }
        return Data(bytes)
    }

    static let gameModules: [(path: String, base: UInt64, size: UInt32)] = [
        (#"C:\Games\Game\Game.exe"#, 0x1_4000_0000, 0x2000_0000), (#"C:\windows\system32\ntdll.dll"#, 0x6fff_ff00_0000, 0x20_0000)]

    @Test func readsCrashDumps() {
        #expect(ProblemReport.crashDump(Self.minidump(Self.gameModules), executable: "Game.exe")?.summary
                == "Access violation (c0000005) at Game.exe+0x27c2fc9")
        // Windows file names: any case.
        #expect(ProblemReport.crashDump(Self.minidump(Self.gameModules), executable: "game.EXE") != nil)
        #expect(ProblemReport.crashDump(Self.minidump(Self.gameModules, exception: (0xc000_00fd, 0x6fff_ff00_1234)), executable: "Game.exe")?.summary
                == "Stack overflow (c00000fd) at ntdll.dll+0x1234")
        #expect(ProblemReport.crashDump(Self.minidump(Self.gameModules, exception: (0xe043_4352, 0x5000)), executable: "Game.exe")?.summary
                == "Exception (e0434352) at 0x5000")
        // Where an access violation wrote; other exceptions' parameters mean something else.
        #expect(ProblemReport.crashDump(Self.minidump(Self.gameModules, wrote: 0x2_1235_e14e), executable: "Game.exe")?.wrote == 0x2_1235_e14e)
        #expect(ProblemReport.crashDump(Self.minidump(Self.gameModules, exception: (0xc000_00fd, 0x5000), wrote: 0x2_1235_e14e),
                                        executable: "Game.exe")?.wrote == nil)
    }

    /// FIFA 23's Live Editor: Wine refused to make D3DMetal's code writable, the mod wrote its hook
    /// there anyway, and the game crashed. The setting that allows the change is offered then only.
    @Test func matchesACrashToARefusedHook() {
        let log = """
            [+] Info: Prologue to overwrite:
            wine: refused VirtualProtect on host memory 0x21235e000-0x21235f000
            0170:err:module:x
            """
        #expect(ProblemReport.refusedHook(in: log, wrote: 0x2_1235_e14e))
        #expect(!ProblemReport.refusedHook(in: log, wrote: 0x2_1235_f000), "the end is outside")
        #expect(!ProblemReport.refusedHook(in: log, wrote: 0))
        #expect(!ProblemReport.refusedHook(in: "0170:err:module:x", wrote: 0x2_1235_e14e))

        #expect(ProblemReport.writeAddress(inCrash: "wine: Unhandled page fault on write access to 000000021235E14E at address 000000018026"
                                           + "0AE7 (thread 0170), starting debugger...") == 0x2_1235_e14e)
        #expect(ProblemReport.writeAddress(inCrash: "Unhandled exception: page fault on write access to 0x21235e14e in 64-bit code") == 0x2_1235_e14e)
        #expect(ProblemReport.writeAddress(inCrash: "wine: Unhandled page fault on read access to 0000000000000090 at address 0") == nil)
    }

    @Test func skipsOtherProgramsDumpsAndDumpsWithoutACrash() {
        // A helper's dump: its own program comes first.
        let steam = [(path: #"C:\Program Files (x86)\Steam\steam.exe"#, base: UInt64(0x40_0000), size: UInt32(0x10_0000))] + Self.gameModules
        #expect(ProblemReport.crashDump(Self.minidump(steam), executable: "Game.exe") == nil)
        // No exception: a snapshot, not a crash.
        #expect(ProblemReport.crashDump(Self.minidump(Self.gameModules, exception: nil), executable: "Game.exe") == nil)
        // Not a minidump, or cut short.
        let dump = Self.minidump(Self.gameModules)
        #expect(ProblemReport.crashDump(Data("MDMP".utf8), executable: "Game.exe") == nil)
        #expect(ProblemReport.crashDump(dump.prefix(200), executable: "Game.exe") == nil)
        #expect(ProblemReport.crashDump(Data(repeating: 0xff, count: 1_000), executable: "Game.exe") == nil)
    }

    @Test func findsTheNewestCrashDumpSinceTheLaunch() throws {
        try withTempDir { dir in
            let launched = Date(timeIntervalSinceNow: -60)
            func write(_ data: Data, _ path: String, at date: Date) throws {
                let file = dir.appending(path: path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
            }
            let steam = [(path: #"C:\Steam\steam.exe"#, base: UInt64(0x40_0000), size: UInt32(0x10_0000))]
            try write(Self.minidump(Self.gameModules), "game/old.dmp", at: launched - 3_600)
            try write(Self.minidump(Self.gameModules), "users/me/AppData/Local/Game/crash 1.mdmp", at: launched + 10)
            try write(Self.minidump(Self.gameModules), "game/xcpt MACNAME 26-10-19.MDMP", at: launched + 20)
            try write(Self.minidump(steam), "users/me/Steam/dumps/crash_steam.exe.dmp", at: launched + 30)
            try write(Data("not a dump".utf8), "game/notes.dmp", at: launched + 40)
            let folders = [dir.appending(path: "game"), dir.appending(path: "users")]
            let found = try #require(ProblemReport.crashDump(in: folders, since: launched, executables: ["Launcher.exe", "Game.exe"], host: "macname"))
            #expect(found.summary == "Access violation (c0000005) at Game.exe+0x27c2fc9")
            #expect(found.file == "xcpt <host> 26-10-19.MDMP")
            #expect(found.wrote == 0)
            #expect(ProblemReport.crashDump(in: folders, since: launched + 25, executables: ["Game.exe"]) == nil)
            #expect(ProblemReport.crashDump(in: [dir.appending(path: "missing")], since: launched, executables: ["Game.exe"]) == nil)
        }
    }

    /// A Steam game's launch runs steam.exe: its dumps are looked for in its install folder and in
    /// Steam's dumps folder, where Steam's crash handler writes them, and matched against the
    /// game's programs the launch saw.
    @Test func findsASteamGamesCrashDumps() throws {
        try withTempDir { prefix in
            let steam = prefix.appending(path: "drive_c/Program Files (x86)/Steam"), client = steam.appending(path: "steam.exe")
            try steam.appending(path: "steamapps/appmanifest_1174180.acf").write(
                "\"AppState\"\n{\n\t\"appid\"\t\t\"1174180\"\n\t\"name\"\t\t\"Red Dead Redemption 2\"\n\t\"installdir\"\t\t\"Red Dead Redemption 2\"\n}")
            let users = prefix.appending(path: "drive_c/users")
            let game = Game(name: "Red Dead Redemption 2", executable: client, bottleID: UUID(), store: StoreItem(store: "steam", appID: "1174180"))
            #expect(ProblemReport.dumpFolders(for: game, prefix: prefix).map(\.path)
                    == [steam.appending(path: "steamapps/common/Red Dead Redemption 2"), steam.appending(path: "dumps"), users].map(\.path))
            let steamItself = Game(name: "Steam", executable: client, bottleID: UUID(), store: StoreItem(store: "steam"))
            #expect(ProblemReport.dumpFolders(for: steamItself, prefix: prefix).isEmpty)
            let exe = prefix.appending(path: "drive_c/Games/Demo/Demo.exe")
            #expect(ProblemReport.dumpFolders(for: Game(name: "Demo", executable: exe, bottleID: UUID()), prefix: prefix).map(\.path)
                    == [exe.deletingLastPathComponent(), users].map(\.path))

            // The game's dump from Steam's crash handler, next to Steam's own.
            let rdr2 = [(path: #"C:\Program Files (x86)\Steam\steamapps\common\Red Dead Redemption 2\RDR2.exe"#,
                         base: UInt64(0x1_4000_0000), size: UInt32(0x2000_0000))]
            let steamModules = [(path: #"C:\Program Files (x86)\Steam\steam.exe"#, base: UInt64(0x1_4000_0000), size: UInt32(0x2000_0000))]
            try steam.appending(path: "dumps/crash_RDR2.exe_20261020101500_1.dmp").write(Self.minidump(rdr2))
            try steam.appending(path: "dumps/crash_steam.exe_20261020101501_1.dmp").write(Self.minidump(steamModules))
            let found = ProblemReport.crashDump(in: ProblemReport.dumpFolders(for: game, prefix: prefix), since: .now - 60,
                                                executables: ["playrdr2.exe", "rdr2.exe"])
            #expect(found?.summary == "Access violation (c0000005) at RDR2.exe+0x27c2fc9")
            #expect(found?.file == "crash_RDR2.exe_20261020101500_1.dmp")
        }
    }

    @Test func hidesTheHomeFolderAndUserName() {
        let text = "/Users/pat/Library/Logs/Corkscrew/x.log C:\\users\\pat\\AppData /Users/pat/Downloads"
        #expect(ProblemReport.redacted(text, home: "/Users/pat", user: "pat")
                == "~/Library/Logs/Corkscrew/x.log C:\\users\\<user>\\AppData ~/Downloads")
        let report = ProblemReport(kind: .error, title: "x", summary: "\(NSHomeDirectory())/a", details: [])
        #expect(report.summary == "~/a")
    }

    /// The link fits GitHub's limit and fills the Bug report form's fields.
    @Test func issueLinkFitsAndFillsTheForm() throws {
        var report = ProblemReport(kind: .crash, title: "Game crashed", summary: "Unhandled exception: page fault",
                                   details: ["Corkscrew: 0.8.0 (11)", "macOS: 26.1", "Mac: Mac16,1, Apple M4 Pro, 16 GB"],
                                   backtrace: String(repeating: Self.crash, count: 20), log: String(repeating: "log line\n", count: 2_000))
        report.note = "Loading a save"
        let url = report.issueURL(repository: URL(string: "https://github.com/o/r")!, backend: "DXMT")
        #expect(url.absoluteString.count <= 7_500)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func field(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(url.path == "/o/r/issues/new")
        #expect(field("template") == "bug_report.yml")
        #expect(field("version") == "0.8.0 (11)")
        #expect(field("mac") == "26.1, Mac16,1, Apple M4 Pro, 16 GB")
        #expect(field("backend") == "DXMT")
        #expect(field("steps") == "Loading a save")
        #expect(field("logs")?.hasSuffix("paste it here)") == true)
        #expect(report.text.contains("**What I was doing:** Loading a save"))
    }

    /// A report server gets the whole report, not what fits in a link.
    @Test func relayGetsTheWholeReport() throws {
        var report = ProblemReport(kind: .crash, title: "Game crashed", summary: "Unhandled exception", details: ["Corkscrew: 0.8.0 (11)"],
                                   backtrace: String(repeating: Self.crash, count: 20), log: "log")
        report.note = "Loading a save"
        let request = try report.request(to: URL(string: "https://relay.example/reports")!)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sent = try decoder.decode(ProblemReport.self, from: body)
        #expect(sent.kind == .crash && sent.note == "Loading a save" && sent.backtrace == report.backtrace)
    }

    @Test func readsMacOSCrashReports() throws {
        try withTempDir { dir in
            let ips = dir.appending(path: "Corkscrew-2026-10-18-101010.ips")
            let body: [String: Any] = [
                "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
                "termination": ["indicator": "Segmentation fault: 11"],
                "faultingThread": 1,
                "threads": [["frames": []],
                            ["frames": [["imageOffset": 1234, "symbol": "AppModel.start(_:transient:)", "symbolLocation": 56, "imageIndex": 0],
                                        ["imageOffset": 99, "imageIndex": 1]]]],
                "usedImages": [["name": "Corkscrew"], ["name": "libsystem_kernel.dylib"]],
            ]
            let text = #"{"app_name":"Corkscrew","bug_type":"309"}"# + "\n"
                + String(decoding: try JSONSerialization.data(withJSONObject: body, options: .prettyPrinted), as: UTF8.self)
            try text.write(to: ips, atomically: true, encoding: .utf8)
            let report = try #require(ProblemReport.appCrash(ipsFile: ips, details: ["Corkscrew: 0.8.0 (11)"]))
            #expect(report.kind == .appCrash)
            #expect(report.summary == "EXC_BAD_ACCESS (SIGSEGV) Segmentation fault: 11")
            #expect(report.backtrace == "0  Corkscrew  AppModel.start(_:transient:) + 56\n1  libsystem_kernel.dylib  +99")
            #expect(ProblemReport.appCrash(ipsFile: dir.appending(path: "missing.ips"), details: []) == nil)
        }
    }

    @Test func crashDialogSettingIsReadFromTheBottle() throws {
        try withTempDir { prefix in
            #expect(!CrashDialog.isOff(prefix: prefix))
            try "WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\WineDbg] 1792000000\n\"ShowCrashDialog\"=dword:00000000\n"
                .write(to: prefix.appending(path: "user.reg"), atomically: true, encoding: .utf8)
            #expect(CrashDialog.isOff(prefix: prefix))
            #expect(CrashDialog.command == ["reg", "add", #"HKCU\Software\Wine\WineDbg"#, "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f"])
        }
    }
}
