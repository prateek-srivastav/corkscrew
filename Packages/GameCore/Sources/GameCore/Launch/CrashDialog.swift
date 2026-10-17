import Foundation

/// Wine's "Program Error" dialog, turned off in each bottle. With it off, winedbg (started with
/// `--auto` when a program crashes) prints the backtrace, the registers and the loaded modules to
/// the program's output, which is the launch log, and `ProblemReport.crash(inLog:)` finds it there.
/// With it on, the trace is only in the dialog (its Save button writes backtrace.txt).
enum CrashDialog {
    static let key = #"Software\Wine\WineDbg"#
    static let name = "ShowCrashDialog"

    static let command = ["reg", "add", "HKCU\\" + key, "/v", name, "/t", "REG_DWORD", "/d", "0", "/f"]

    /// What the bottle's `user.reg` last saved; a missing value means on.
    static func isOff(prefix: URL) -> Bool {
        WineRegistry.value(name, inKey: key, file: prefix.appending(path: "user.reg")) == "dword:00000000"
    }

    /// Turns the dialog off once for each bottle (one short Wine run). While the bottle runs, its
    /// user.reg can lag, and the next launch sets the value again. A failure only leaves the dialog on.
    static func turnOff(in context: WineContext, log: URL) async {
        guard !isOff(prefix: context.location.prefix),
              let plan = try? LaunchPlanner.plan(wineArguments: command, in: context) else { return }
        _ = try? await ProcessRunner.run(plan, log: log, wineserver: context.engine.wineserver)
    }
}
