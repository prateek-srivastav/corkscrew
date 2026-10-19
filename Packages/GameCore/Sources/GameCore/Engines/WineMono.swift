import Foundation

/// Wine Mono, Wine's .NET runtime, which the runtime carries as a shared install in
/// `share/wine/mono/wine-mono-<version>` (`scripts/build-runtime.sh`).
///
/// Wine finds it there through the Z: drive, and `wineboot` installs its support package from it,
/// so .NET programs run and Wine never asks to download Mono. Isolated bottles have no Z: drive
/// (`PrefixHardening`), so their `C:\windows\mono\mono-2.0`, where Wine looks first, links to it.
public enum WineMono {
    /// The runtime's Wine Mono folder; nil for an older runtime without one.
    public static func folder(in runtime: URL) -> URL? {
        let mono = runtime.appending(path: "share/wine/mono", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: mono.path)) ?? []
        return names.filter { $0.hasPrefix("wine-mono-") }.sorted().last
            .map { mono.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// Links the prefix's `C:\windows\mono\mono-2.0` to the runtime's Wine Mono. A real folder
    /// there (Mono installed from its own installer) stays.
    static func link(prefix: URL, runtime: URL) throws {
        let fm = FileManager.default
        let windows = prefix.appending(path: "drive_c/windows", directoryHint: .isDirectory)
        guard let folder = folder(in: runtime), fm.fileExists(atPath: windows.path) else { return }
        let link = windows.appending(path: "mono/mono-2.0")
        if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            guard destination != folder.path else { return }
            try fm.removeItem(at: link)  // another runtime's
        } else if fm.fileExists(atPath: link.path) {
            return
        }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: folder.path)
    }
}
