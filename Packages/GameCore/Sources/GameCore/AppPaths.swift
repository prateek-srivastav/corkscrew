import Foundation

/// Where the app keeps runtimes, bottles, logs and caches.
public struct AppPaths: Sendable, Equatable {
    /// `~/Library/Application Support/Corkscrew`
    public var supportRoot: URL
    /// `~/Library/Logs/Corkscrew`
    public var logsRoot: URL
    /// `~/Library/Caches/Corkscrew`
    public var cachesRoot: URL
    /// The Mac user's home folder (hidden from isolated bottles).
    public var userHome: URL
    /// Where wineserver puts its socket (`/tmp/.wine-<uid>`).
    public var wineServerDirectory: URL

    public init(supportRoot: URL, logsRoot: URL, cachesRoot: URL, userHome: URL, wineServerDirectory: URL) {
        self.supportRoot = supportRoot
        self.logsRoot = logsRoot
        self.cachesRoot = cachesRoot
        self.userHome = userHome
        self.wineServerDirectory = wineServerDirectory
    }

    public static var standard: AppPaths {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return AppPaths(
            supportRoot: library.appending(path: "Application Support/Corkscrew", directoryHint: .isDirectory),
            logsRoot: library.appending(path: "Logs/Corkscrew", directoryHint: .isDirectory),
            cachesRoot: library.appending(path: "Caches/Corkscrew", directoryHint: .isDirectory),
            userHome: fm.homeDirectoryForCurrentUser,
            wineServerDirectory: URL(fileURLWithPath: "/private/tmp/.wine-\(getuid())", isDirectory: true)
        )
    }

    /// Everything in one folder (`support/`, `logs/`, `caches/`), as the CLI uses `build/dev-data`.
    public static func rooted(at root: URL) -> AppPaths {
        let standard = AppPaths.standard
        return AppPaths(
            supportRoot: root.appending(path: "support", directoryHint: .isDirectory),
            logsRoot: root.appending(path: "logs", directoryHint: .isDirectory),
            cachesRoot: root.appending(path: "caches", directoryHint: .isDirectory),
            userHome: standard.userHome,
            wineServerDirectory: standard.wineServerDirectory
        )
    }

    public var runtimes: URL { unindexed("Runtimes") }
    public var components: URL { unindexed("Components") }
    public var bottles: URL { unindexed("Bottles") }
    /// The app bundles isolated bottles' games run from, for Game Mode (see `LoaderBundles`).
    public var gameModeBundles: URL { unindexed("GameModeBundles") }

    /// `<name>.noindex`, which Spotlight skips (`SpotlightExclusion`). Data from before keeps the
    /// plain name until `SpotlightExclusion.moveFolders` renames it.
    private func unindexed(_ name: String) -> URL {
        let old = supportRoot.appending(path: name, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: old.path) { return old }
        return supportRoot.appending(path: "\(name).noindex", directoryHint: .isDirectory)
    }

    public func shaderCache(for gameID: UUID) -> URL {
        cachesRoot.appending(path: "ShaderCache/\(gameID.uuidString)", directoryHint: .isDirectory)
    }

    /// `library.json`: the games added to the library.
    public var library: URL { supportRoot.appending(path: "library.json") }
    /// Icons extracted from games' executables; rebuilt when missing.
    public var icons: URL { cachesRoot.appending(path: "Icons", directoryHint: .isDirectory) }

    public func logs(for gameID: UUID) -> URL {
        logsRoot.appending(path: gameID.uuidString, directoryHint: .isDirectory)
    }
}
