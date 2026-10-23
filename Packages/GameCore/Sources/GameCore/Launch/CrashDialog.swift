import Foundation

/// Wine's "Program Error" dialog, turned off in each bottle, and the debugger Wine starts when a
/// program crashes, set to write to a file. With the dialog off, winedbg (started with `--auto`)
/// prints the backtrace, the registers and the loaded modules to the program's output, which is the
/// launch log, and `ProblemReport.crash(inLog:)` finds it there. With it on, the trace is only in the
/// dialog (its Save button writes backtrace.txt).
///
/// A GUI program has no console, so Wine's default debugger (`winedbg --auto %ld %ld`) gets a new
/// one and its output doesn't reach the log (seen in issues #55 and #64). `debugger` writes it to
/// `output(prefix:)` instead, for every program; `ProblemReport` reads it from there.
enum CrashDialog {
    static let key = #"Software\Wine\WineDbg"#
    static let name = "ShowCrashDialog"

    static let command = ["reg", "add", "HKCU\\" + key, "/v", name, "/t", "REG_DWORD", "/d", "0", "/f"]

    /// Where 64-bit and 32-bit programs look for their debugger.
    static let debuggerKeys = [#"Software\Microsoft\Windows NT\CurrentVersion\AeDebug"#,
                               #"Software\Wow6432Node\Microsoft\Windows NT\CurrentVersion\AeDebug"#]
    /// Wine's default, with winedbg's output added to `output(prefix:)`.
    static let debugger = #"cmd /c winedbg --auto %ld %ld >>C:\windows\temp\winedbg.txt 2>&1"#

    static func debuggerCommand(key: String) -> [String] {
        ["reg", "add", "HKLM\\" + key, "/v", "Debugger", "/t", "REG_SZ", "/d", debugger, "/f"]
    }

    /// The file `debugger` writes to.
    static func output(prefix: URL) -> URL {
        prefix.appending(path: "drive_c/windows/temp/winedbg.txt")
    }

    /// What the bottle's `user.reg` last saved; a missing value means on.
    static func isOff(prefix: URL) -> Bool {
        WineRegistry.value(name, inKey: key, file: prefix.appending(path: "user.reg")) == "dword:00000000"
    }

    /// Whether the bottle's `system.reg` has `debugger` under `key`.
    static func hasDebugger(prefix: URL, key: String) -> Bool {
        WineRegistry.value("Debugger", inKey: key, file: prefix.appending(path: "system.reg"))
            .map { WineRegistry.unescaped($0[...]) } == debugger
    }

    /// The commands that make all the settings, for a new bottle.
    static let commands = [command] + debuggerKeys.map(debuggerCommand(key:))

    /// The commands for the settings the bottle doesn't have yet.
    static func missingCommands(prefix: URL) -> [[String]] {
        (isOff(prefix: prefix) ? [] : [command])
            + debuggerKeys.filter { !hasDebugger(prefix: prefix, key: $0) }.map(debuggerCommand(key:))
    }

    /// Turns the dialog off and sets the debugger once for each bottle (short Wine runs). While the
    /// bottle runs, its registry files can lag, and the next launch sets the values again. A failure
    /// only leaves Wine's default.
    static func apply(in context: WineContext, log: URL) async {
        for command in missingCommands(prefix: context.location.prefix) {
            guard let plan = try? LaunchPlanner.plan(wineArguments: command, in: context) else { return }
            _ = try? await ProcessRunner.run(plan, log: log, wineserver: context.engine.wineserver)
        }
    }
}
