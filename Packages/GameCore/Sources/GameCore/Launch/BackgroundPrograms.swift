import Darwin
import Foundation

/// Store clients and launchers that run next to a game but seldom do anything for it while it plays.
/// On request they run at Darwin background priority meanwhile: on the efficiency cores, with low
/// CPU, disk and network priority. Steam's web helper is Chromium drawing in software under Rosetta.
///
/// Never wineserver, winedevice (controllers), explorer or the game itself: every Wine call of the
/// game goes through wineserver.
public enum BackgroundPrograms {
    /// Windows program names, lowercased.
    static let names: Set<String> = [
        "steam.exe", "steamwebhelper.exe", "steamwebhelper_real.exe", "steamservice.exe",
        // Rockstar Games Launcher; `launcher.exe` only in its own folder (games have launchers too).
        "rockstarservice.exe", "socialclubhelper.exe",
    ]

    /// Whether the program is one to lower, sparing `games` (lowercased Windows names).
    static func isBackground(_ program: String, sparing games: Set<String>) -> Bool {
        let name = program.split(separator: "\\").last.map(String.init) ?? program
        guard !games.contains(name) else { return false }
        return names.contains(name) || program.hasSuffix("\\rockstar games\\launcher\\launcher.exe")
    }

    /// Lowers the bottle's background programs; returns the pids now lowered.
    @discardableResult
    public static func lower(prefix: URL, sparing games: Set<String>) -> Set<pid_t> {
        var lowered = Set<pid_t>()
        for entry in BottleProcesses.list(prefix: prefix) where isBackground(entry.program, sparing: games) {
            if isLowered(entry.pid) || setpriority(PRIO_DARWIN_PROCESS, id_t(entry.pid), PRIO_DARWIN_BG) == 0 {
                lowered.insert(entry.pid)
            }
        }
        return lowered
    }

    /// Back to normal priority, so Steam syncs saves and quits quickly after the game.
    public static func restore(_ pids: Set<pid_t>) {
        for pid in pids where isLowered(pid) { setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0) }
    }

    /// `PROC_FLAG_EXT_DARWINBG` (mach/task_policy.h): background set from outside the process.
    private static let externalBackgroundFlag: UInt32 = 0x10000

    /// getpriority doesn't say for another process; its process info does.
    static func isLowered(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_flags & externalBackgroundFlag != 0
    }
}
