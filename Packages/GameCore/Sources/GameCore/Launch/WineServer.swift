import Foundation

/// Locates a prefix's wineserver folder, mirroring Wine's `init_server_dir`
/// (dlls/ntdll/unix/server.c): `/tmp/.wine-<uid>/server-<dev hex>-<inode hex>` of the prefix.
public enum WineServer {
    public enum LocateError: Error, Equatable {
        case prefixMissing(String)
    }

    /// The prefix must exist; create it before running `wineboot` on a new bottle.
    public static func directory(forPrefix prefix: URL, base: URL) throws -> URL {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { throw LocateError.prefixMissing(prefix.path) }
        // Wine prints `(unsigned long long)dev`, which sign-extends the 32-bit dev_t.
        let dev = String(UInt(bitPattern: Int(info.st_dev)), radix: 16)
        let ino = String(info.st_ino, radix: 16)
        return base.appending(path: "server-\(dev)-\(ino)", directoryHint: .isDirectory)
    }

    /// Makes our patched wineserver connect only to its own loopback listeners (scripts/build-runtime.sh).
    static let privateLoopbackKey = "CORKSCREW_PRIVATE_LOOPBACK"

    /// Whether this wineserver has the private-loopback patch; older runtimes don't, and must not get
    /// loopback. The binary holds the variable's name, which it reads with `getenv`.
    static func hasPrivateLoopback(_ wineserver: URL) -> Bool {
        guard let binary = try? Data(contentsOf: wineserver, options: .alwaysMapped) else { return false }
        return binary.range(of: Data(privateLoopbackKey.utf8)) != nil
    }

    /// Whether the prefix's wineserver is up. It removes its socket as it starts shutting down, before
    /// saving the registry, so use `ProcessRunner.waitForSession` before trusting files in the prefix.
    /// A server that died leaves its socket behind until `removeStaleDirectories` runs.
    public static func isRunning(prefix: URL, base: URL) -> Bool {
        guard let server = try? directory(forPrefix: prefix, base: base) else { return false }
        return FileManager.default.fileExists(atPath: server.appending(path: "socket").path)
    }

    /// Whether a wineserver holds the folder's `lock` (it keeps a write lock on it for its whole life,
    /// see `acquire_lock` in server/request.c). Unlike the socket, a lock can't outlive its server.
    static func isLocked(_ server: URL) -> Bool {
        let fd = open(server.appending(path: "lock").path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(fd, F_GETLK, &lock) == 0 else { return true }  // Unknown: leave it alone.
        return lock.l_type != Int16(F_UNLCK)
    }

    /// Ends the prefix's programs whose wineserver is gone. Wine doesn't: `wineserver -k` only reaches
    /// a live server's programs, and they ignore SIGTERM without one. Seen 2026-10-14: a
    /// `winedevice.exe` that ran for days at 2% CPU. A program counts only when it's there twice,
    /// `confirm` apart, with no server both times: a starting program runs briefly before its server.
    @discardableResult
    public static func stopOrphans(prefix: URL, base: URL, confirm: Duration = .seconds(2)) async -> [pid_t] {
        func orphans() -> Set<pid_t> {
            if let server = try? directory(forPrefix: prefix, base: base), isLocked(server) { return [] }
            return Set(BottleProcesses.list(prefix: prefix, maxAge: .zero).map(\.pid))
        }
        let first = orphans()
        guard !first.isEmpty else { return [] }
        try? await Task.sleep(for: confirm)
        let found = first.intersection(orphans()).sorted()
        for pid in found { kill(pid, SIGKILL) }
        return found
    }

    /// Removes server folders no server holds, older than `age` (a starting server makes its folder
    /// before it takes the lock). A server that dies (a crash, a forced quit, the Mac shutting down)
    /// leaves its folder with a socket and its mapped files (about 1.3 MB). Returns the folders removed.
    @discardableResult
    public static func removeStaleDirectories(base: URL, age: TimeInterval = 60) -> [URL] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let removed = folders.filter { folder in
            guard folder.lastPathComponent.hasPrefix("server-"),
                  let modified = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  -modified.timeIntervalSinceNow > age, !isLocked(folder) else { return false }
            return (try? fm.removeItem(at: folder)) != nil
        }
        return removed
    }
}
