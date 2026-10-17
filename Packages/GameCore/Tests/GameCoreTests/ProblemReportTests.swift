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
