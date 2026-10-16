import CoreGraphics
import Darwin
import Foundation
import Synchronization

/// A bottle's running Wine processes, found by the `WINEPREFIX` in their environment. A Wine
/// process's first argument is its Windows path (`C:\Program Files (x86)\Steam\steam.exe`).
public enum BottleProcesses {
    public struct Entry: Equatable, Sendable {
        public var pid: pid_t
        public var arguments: [String]

        /// The Windows program, lowercased, with backslashes. The program Wine was started with
        /// keeps its Mac path (`…/drive_c/Program Files (x86)/Steam/steam.exe`); the ones it starts
        /// show their Windows path.
        var program: String { arguments.first?.lowercased().replacingOccurrences(of: "/", with: "\\") ?? "" }

        /// Steam's client (`steam.exe`).
        public var isSteamClient: Bool { BottleProcesses.isSteamClient(program) }
        /// Steam's interface (`steamwebhelper.exe`): its main and sign-in windows are this
        /// program's. `steam.exe` only shows the small updater and start-up windows.
        public var isSteamWebHelper: Bool { program.hasSuffix("\\steamwebhelper.exe") }
    }

    /// Our own processes whose environment has WINEPREFIX=prefix. Callers within `maxAge` of each
    /// other share one scan (the app, the launcher and the web helper guard all poll while a game
    /// runs).
    public static func list(prefix: URL, maxAge: Duration = .seconds(1)) -> [Entry] {
        snapshot(maxAge: maxAge)[prefix.standardizedFileURL.path] ?? []
    }

    /// Our Wine processes by their prefix (standardized path).
    static func snapshot(maxAge: Duration = .seconds(1)) -> [String: [Entry]] {
        scanner.withLock { scanner in
            let now = ContinuousClock.now
            if let last = scanner.last, now - last.time < maxAge { return last.entries }
            let entries = scanner.scan()
            scanner.last = (now, entries)
            return entries
        }
    }

    private static let scanner = Mutex(Scanner())

    /// Finds the processes with a WINEPREFIX. Reading a process's environment (KERN_PROCARGS2) costs
    /// far more than the rest, and the environment doesn't change after `exec`, so each process's
    /// prefix (or none) is remembered by pid, start time and name: most processes are read once in
    /// their life. The arguments of Wine processes are read on every scan: Wine rewrites them in
    /// place after it starts.
    struct Scanner {
        struct Identity: Equatable {
            var started: UInt64
            var name: String
        }
        var known: [pid_t: (identity: Identity, prefix: String?)] = [:]
        var last: (time: ContinuousClock.Instant, entries: [String: [Entry]])?

        mutating func scan() -> [String: [Entry]] {
            let count = proc_listallpids(nil, 0)
            guard count > 0 else { return [:] }
            var all = [pid_t](repeating: 0, count: Int(count) + 64)
            let filled = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size))
            let me = getuid()
            var result: [String: [Entry]] = [:]
            var seen: [pid_t: (identity: Identity, prefix: String?)] = [:]
            for pid in all.prefix(Int(max(filled, 0))) where pid > 0 {
                var info = proc_bsdinfo()
                let size = Int32(MemoryLayout<proc_bsdinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == me else { continue }
                let identity = Identity(started: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec,
                                        name: withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
                var prefix: String?
                var arguments: [String]?
                if let cached = known[pid], cached.identity == identity {
                    prefix = cached.prefix
                } else {
                    guard let process = BottleProcesses.processArguments(of: pid) else { continue }
                    prefix = process.environment["WINEPREFIX"].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                    arguments = process.arguments
                }
                seen[pid] = (identity, prefix)
                guard let prefix else { continue }
                guard let arguments = arguments ?? BottleProcesses.processArguments(of: pid)?.arguments else { continue }
                result[prefix, default: []].append(Entry(pid: pid, arguments: arguments))
            }
            known = seen
            return result
        }
    }

    /// Whether Steam's client runs in the bottle.
    public static func isSteamRunning(prefix: URL) -> Bool {
        list(prefix: prefix).contains { isSteamClient($0.program) }
    }

    static func isSteamClient(_ program: String) -> Bool { program.hasSuffix("\\steam.exe") }

    /// Whether one of `pids` has a normal window on screen (on the current Space; minimized and
    /// hidden windows don't count). Needs no Screen Recording permission: no titles are read.
    static func hasWindowOnScreen(pids: Set<pid_t>) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            (window[kCGWindowLayer as String] as? Int) == 0
                && (window[kCGWindowOwnerPID as String] as? Int).map { pids.contains(pid_t($0)) } == true
        }
    }

    /// The numbers of the bottle's normal windows on screen (as `hasWindowOnScreen` counts them),
    /// of the processes `include` picks: a number not there before is a window that opened, or one
    /// shown again.
    public static func windowsOnScreen(prefix: URL, of include: (Entry) -> Bool = { _ in true }) -> Set<Int> {
        let pids = Set(list(prefix: prefix).filter(include).map(\.pid))
        guard !pids.isEmpty else { return [] }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(windows.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? Int, pids.contains(pid_t(owner)) else { return nil }
            return window[kCGWindowNumber as String] as? Int
        })
    }

    /// Programs started from a Steam game's folder (`steamapps\common\<installDir>\…`), on any drive.
    static func isFromSteamGame(_ program: String, installDir: String) -> Bool {
        program.contains("\\steamapps\\common\\\(installDir.lowercased())\\")
    }

    /// Another process's arguments and environment (same user only), via KERN_PROCARGS2.
    static func processArguments(of pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(buffer[..<size])
    }

    /// KERN_PROCARGS2 layout: argc, the executable path, NUL padding, then exactly argc NUL-terminated
    /// arguments (empty ones included), then environment strings up to an empty one. Counting the
    /// arguments, rather than splitting on NULs, keeps an empty argument from shifting the
    /// environment, and a program's arguments from passing as its environment.
    ///
    /// Wine rewrites its arguments in place (argv[0] becomes the Windows path) and zeroes the rest
    /// of the space they took, so NULs can sit between the last argument and the environment.
    static func parseProcessArguments(_ bytes: ArraySlice<UInt8>) -> (arguments: [String], environment: [String: String])? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0 else { return nil }
        var index = bytes.startIndex + MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard index < bytes.endIndex, let end = bytes[index...].firstIndex(of: 0) else { return nil }
            defer { index = end + 1 }
            return String(decoding: bytes[index..<end], as: UTF8.self)
        }
        guard nextString() != nil else { return nil }  // the executable path
        while index < bytes.endIndex, bytes[index] == 0 { index += 1 }  // padding
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { return nil }
            arguments.append(argument)
        }
        while index < bytes.endIndex, bytes[index] == 0 { index += 1 }  // what Wine zeroed
        var environment: [String: String] = [:]
        while let text = nextString(), !text.isEmpty {
            if let equals = text.firstIndex(of: "=") {
                environment[String(text[..<equals])] = String(text[text.index(after: equals)...])
            }
        }
        return (arguments, environment)
    }
}
