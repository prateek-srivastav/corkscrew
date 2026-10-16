import Foundation

/// Removes what Corkscrew put on the Mac: every bottle with the games installed in it, the runtimes
/// and components, the library, logs and caches, and the app's own files in `~/Library`
/// (preferences, saved window state, web caches). Programs outside its folders stay. The app
/// bundle is the caller's: it is running.
public struct Uninstaller: Sendable {
    public var paths: AppPaths
    /// The app's bundle identifier; its files in `~/Library` are named after it.
    public var bundleIdentifier: String
    /// `~/Library`
    public var library: URL
    public var hostEnvironment: [String: String]
    /// Where Wine makes our loader bundles (see `LoaderBundles`); nil leaves them.
    public var loaderBundles: URL? = LoaderBundles.temporaryDirectory

    public init(paths: AppPaths, bundleIdentifier: String,
                library: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0],
                hostEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.bundleIdentifier = bundleIdentifier
        self.library = library
        self.hostEnvironment = hostEnvironment
    }

    /// What `removeFiles` deletes: the data folders, then the app's files in `~/Library`, and the
    /// preferences and saved state of the loader bundles games run from.
    public var items: [URL] {
        let id = bundleIdentifier, loader = LoaderBundles.identifier
        return [paths.supportRoot, paths.logsRoot, paths.cachesRoot]
            + ["Preferences/\(id).plist", "Saved Application State/\(id).savedState", "Caches/\(id)",
               "HTTPStorages/\(id)", "HTTPStorages/\(id).binarycookies", "WebKit/\(id)",
               "Preferences/\(loader).plist", "Saved Application State/\(loader).savedState"]
                .map { library.appending(path: $0) }
    }

    /// Stops every bottle (`wineserver -k`, then kills what is left) and removes its wineserver
    /// folder in `/tmp/.wine-<uid>`; other Wine apps' folders there stay. Call it before
    /// `removeFiles`, while the runtimes are still there.
    public func stopBottles() {
        let fm = FileManager.default
        let runtimes = RuntimeStore(paths: paths)
        for bottle in (try? BottleStore(paths: paths).list()) ?? [] {
            let location = BottleLocation(bottleID: bottle.id, paths: paths)
            if let engine = try? runtimes.engine(id: bottle.engineID),
               let environment = try? LaunchPlanner.plan(wineArguments: [], in: WineContext(
                   engine: engine, bottle: bottle, location: location, paths: paths, hostEnvironment: hostEnvironment)).environment {
                ProcessRunner.stopSession(environment: environment, wineserver: engine.wineserver)
                _ = ProcessRunner.waitForSession(environment: environment, wineserver: engine.wineserver, timeout: .seconds(10))
            }
            for process in BottleProcesses.list(prefix: location.prefix, maxAge: .zero) { kill(process.pid, SIGKILL) }
            if let server = try? WineServer.directory(forPrefix: location.prefix, base: paths.wineServerDirectory) {
                try? fm.removeItem(at: server)
            }
        }
        if let loaderBundles { LoaderBundles.removeAll(in: loaderBundles) }
    }

    /// Takes the app out of LaunchServices (Open With) and deletes it; to the Trash when it can't be
    /// deleted (Finder may ask for a password there). Whether it's gone.
    public func removeApp(at app: URL) -> Bool {
        let unregister = Process()
        unregister.executableURL = LoaderBundles.lsregister
        unregister.arguments = ["-u", app.path]
        unregister.standardOutput = FileHandle.nullDevice
        unregister.standardError = FileHandle.nullDevice
        if (try? unregister.run()) != nil { unregister.waitUntilExit() }
        let fm = FileManager.default
        if (try? fm.removeItem(at: app)) == nil { try? fm.trashItem(at: app, resultingItemURL: nil) }
        return !fm.fileExists(atPath: app.path)
    }

    /// Deletes `items` for good, not to the Trash (bottles take tens of GB). Returns the ones that
    /// are still there.
    @discardableResult
    public func removeFiles() -> [URL] {
        let fm = FileManager.default
        return items.filter { item in
            guard fm.fileExists(atPath: item.path) else { return false }
            try? fm.removeItem(at: item)
            return fm.fileExists(atPath: item.path)
        }
    }
}
