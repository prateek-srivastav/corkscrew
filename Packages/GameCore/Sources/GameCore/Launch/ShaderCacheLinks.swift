import Foundation

/// Shader caches outside an isolated bottle. Metal keeps compiled shaders in
/// `<user cache folder>/<bundle id>/` (an isolated game's loader bundle has an id of its own, see
/// `LoaderBundles.identifier(for:)`), and D3DMetal keeps its cache in
/// `<user cache folder>/d3dm/<exe name>/`. Neither can be moved: D3DMetal gives Metal its own folder,
/// but Metal ignores that once it has run, and the Mac driver runs it first. The sandbox can't write
/// to either, so isolated games compiled every shader again on each launch (FIFA 23: about 5,600, for
/// two and a half minutes). Their launch links both to the game's own cache folder, which the sandbox
/// allows: it checks the path a link leads to. Other launches take our D3DMetal link away, so a game
/// outside the sandbox never shares a cache with one inside it.
enum ShaderCacheLinks {
    /// `<user cache folder>`, whatever `HOME` or `TMPDIR` say.
    static var userCacheFolder: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        // The length includes the terminating NUL.
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard length > 1, length <= buffer.count else { return nil }
        let path = String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The links in `folder` (the user cache folder) for a launch of `executable`: D3DMetal's first,
    /// then Metal's, each with the folder in the game's cache it leads to.
    static func links(for executable: URL, gameID: UUID, paths: AppPaths, in folder: URL) -> [(link: URL, target: URL)] {
        let cache = paths.shaderCache(for: gameID)
        var links = [(link: folder.appending(path: "d3dm/\(executable.lastPathComponent)"), target: cache.appending(path: "d3dm"))]
        if let name = LoaderBundles.bundleName(for: executable.lastPathComponent) {
            links.append((link: folder.appending(path: LoaderBundles.identifier(for: name)), target: cache.appending(path: "metal")))
        }
        return links
    }

    /// Before a launch. Isolated: makes the links, in place of folders or links there (caches other
    /// programs of that name made). Otherwise: removes our D3DMetal link of that name; games outside
    /// the sandbox run from Wine's own bundles, which have another Metal folder.
    static func prepare(for executable: URL, gameID: UUID, isolated: Bool, paths: AppPaths, in folder: URL) throws {
        let fm = FileManager.default
        let links = links(for: executable, gameID: gameID, paths: paths, in: folder)
        guard isolated else {
            let link = links[0].link
            if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path), isInside(destination, paths.cachesRoot) {
                try fm.removeItem(at: link)
            }
            return
        }
        for (link, target) in links {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let destination = try? fm.destinationOfSymbolicLink(atPath: link.path)
            guard destination != target.path else { continue }
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if destination != nil || fm.fileExists(atPath: link.path) { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        }
    }

    /// Removes our links in `folder` (the user cache folder) and its `d3dm` (uninstall); Metal's and
    /// D3DMetal's own folders stay.
    static func removeLinks(in folder: URL, paths: AppPaths) {
        let fm = FileManager.default
        for folder in [folder, folder.appending(path: "d3dm")] {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                let link = folder.appending(path: name)
                if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path), isInside(destination, paths.cachesRoot) {
                    try? fm.removeItem(at: link)
                }
            }
        }
    }

    private static func isInside(_ path: String, _ folder: URL) -> Bool {
        path.hasPrefix(folder.standardizedFileURL.path + "/")
    }
}
