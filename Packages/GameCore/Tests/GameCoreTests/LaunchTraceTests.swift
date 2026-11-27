import Foundation
import Testing
@testable import GameCore

struct LaunchTraceTests {
    @Test func listsTheProgramsThatMatter() {
        let entries = [
            #"/Users/me/Bottles/X/prefix/drive_c/Program Files (x86)/Steam/steam.exe"#,
            #"C:\windows\system32\services.exe"#,
            #"C:\Program Files\Rockstar Games\Launcher\Launcher.exe"#,
            #"C:\Program Files\Rockstar Games\Launcher\Launcher.exe"#,
        ].enumerated().map { BottleProcesses.Entry(pid: pid_t($0.offset + 1), arguments: [$0.element]) }
        #expect(LaunchTrace.programs(entries) == "launcher.exe steam.exe")
    }

    @Test func writesAChangeOnlyOnce() throws {
        try withTempDir { folder in
            var trace = LaunchTrace(besides: folder.appending(path: "launch-1.log"))
            trace.note("steam=running steam.exe")
            trace.note("steam=running steam.exe")
            trace.note("steam=stopped steam.exe")
            let text = try String(contentsOf: folder.appending(path: "launch-tracking.log"), encoding: .utf8)
            #expect(text.split(separator: "\n").count == 3, "the header and two states")
            #expect(text.contains("steam=stopped steam.exe"))
        }
    }
}
