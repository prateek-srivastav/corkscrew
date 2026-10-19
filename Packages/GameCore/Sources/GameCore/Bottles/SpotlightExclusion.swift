import Foundation

/// Keeps Spotlight out of the app's data. Bottles, runtimes and components are hundreds of thousands
/// of files (Steam's games among them), which Spotlight would index during installs and play.
/// Spotlight skips a folder whose name ends in `.noindex`, and on macOS 26 and 27 nothing else: a
/// `.metadata_never_index` file or the hidden flag don't count. So these folders have that name
/// (`AppPaths`), and renaming an indexed one takes its files out of the index.
public enum SpotlightExclusion {
    /// The folders that had no `.noindex` before.
    static let folders = ["Runtimes", "Components", "Bottles", "GameModeBundles"]

    /// Gives data from before the `.noindex` names, and points the library's games at the moved
    /// bottles. Nothing moves while a Wine program runs from the data (Wine opens its files by their
    /// full path, so a running Steam would lose them): `AppPaths` keeps the old names until a start
    /// when none runs. Call it before anything reads the folders. Returns the renamed folders.
    @discardableResult
    public static func moveFolders(paths: AppPaths, temporary: URL? = LoaderBundles.temporaryDirectory) throws -> [URL] {
        let fm = FileManager.default
        let old = folders.map { paths.supportRoot.appending(path: $0, directoryHint: .isDirectory) }.filter { fm.fileExists(atPath: $0.path) }
        guard !old.isEmpty, !runsWine(from: paths) else { return [] }
        var moved: [URL] = []
        for folder in old {
            let new = paths.supportRoot.appending(path: "\(folder.lastPathComponent).noindex", directoryHint: .isDirectory)
            // Both only when an older version ran again; its data stays where it is.
            guard !fm.fileExists(atPath: new.path) else { continue }
            if folder.lastPathComponent == "GameModeBundles" {
                // Their links name the runtime's old folder; launches make them again.
                LoaderBundles.unregisterAll(in: nil, prebuilt: folder)
                try fm.removeItem(at: folder)
                continue
            }
            try fm.moveItem(at: folder, to: new)
            if folder.lastPathComponent == "Runtimes", let temporary { removeWineTemp(linkingInto: folder, in: temporary) }
            if folder.lastPathComponent == "Bottles" {
                do {
                    try relocateLibrary(paths: paths, from: folder, to: new)
                } catch {
                    try? fm.moveItem(at: new, to: folder)
                    throw error
                }
            }
            moved.append(new)
        }
        return moved
    }

    /// A Wine program with its prefix in the app's data runs: the app leaves Steam running when it quits.
    static func runsWine(from paths: AppPaths) -> Bool {
        let root = paths.supportRoot.standardizedFileURL.path + "/"
        return BottleProcesses.snapshot(maxAge: .zero).keys.contains { $0.hasPrefix(root) }
    }

    /// Wine's folders in the user temporary folder (`winetemp-…`, with the bundles of `LoaderBundles`)
    /// link to the runtime's ntdll.so by its full path. Wine finds a folder again by the loader's
    /// inode, size and time, which a rename keeps, so it would load ntdll.so from the old path and
    /// fail. Wine makes them again.
    static func removeWineTemp(linkingInto runtimes: URL, in temporary: URL) {
        let fm = FileManager.default
        let prefix = runtimes.path + "/"
        for folder in (try? fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        where folder.lastPathComponent.hasPrefix("winetemp-") {
            guard let target = try? fm.destinationOfSymbolicLink(atPath: folder.appending(path: "ntdll.so").path),
                  target.hasPrefix(prefix) else { continue }
            LoaderBundles.unregisterAll(in: nil, prebuilt: folder)
            try? fm.removeItem(at: folder)
        }
    }

    /// Points the library's games (and their icons) in `old` at the same files in `new`.
    static func relocateLibrary(paths: AppPaths, from old: URL, to new: URL) throws {
        guard FileManager.default.fileExists(atPath: paths.library.path) else { return }
        let store = LibraryStore(paths: paths)
        var library = try store.load()
        let from = old.path + "/"
        let to = new.path + "/"
        func moved(_ url: URL) -> URL {
            let path = url.path
            return path.hasPrefix(from) ? URL(filePath: to + path.dropFirst(from.count), directoryHint: .notDirectory) : url
        }
        for index in library.games.indices {
            library.games[index].executable = moved(library.games[index].executable)
            library.games[index].iconSource = library.games[index].iconSource.map(moved)
        }
        try store.save(library)
    }
}
