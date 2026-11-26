import Foundation

/// Keeps a standard bottle's Windows folders (Documents, Downloads, Music, Pictures, Videos) inside
/// it, so everything Corkscrew's games write stays in Corkscrew's folder.
///
/// Wine links them to the Mac's own folders: games then save into `~/Documents` among the user's
/// files, and macOS asks Corkscrew for access to Documents. A new bottle gets folders of its own
/// (`BottleStore.create`). A bottle made before keeps its links until the user chooses; the items
/// they tick are copied in (`keepInside`), and the originals stay where they are.
///
/// Wine links an empty folder again when it updates a prefix (it can't replace one with files in
/// it), so `unlinkAgain` runs before every launch, as `PrefixHardening` does for isolated bottles.
public enum BottleFolders {
    /// A Windows folder that links to a Mac folder.
    public struct Link: Equatable, Sendable {
        /// `drive_c/users/crossover/Documents`, in the prefix.
        public let path: String
        /// `~/Documents`.
        public let macFolder: URL
        public var name: String { (path as NSString).lastPathComponent }
        /// Whether `scan` looks in the Mac folder for the bottle's files (`readFolders`).
        public var isRead: Bool { BottleFolders.readFolders.contains(name) }
    }

    /// The folders whose Mac folder is looked in for the bottle's files. Windows programs keep their
    /// saves and settings in Documents; into Downloads, Music, Pictures and Videos they put what they
    /// make for the user (downloads, screenshots, clips), which can stay in the Mac's. macOS asks the
    /// user to let Corkscrew into each of these folders (Music as "Apple Music"), so the fewer the better.
    public static let readFolders: Set<String> = ["Documents", "My Documents"]

    /// An item of a linked Mac folder that changed since the bottle was made, so a program in the
    /// bottle may have written it.
    public struct Item: Equatable, Sendable, Identifiable {
        public let url: URL
        public let link: Link
        /// Nearly every change to it since the bottle was made (`suggestedShare`) happened while the
        /// bottle ran: a program in the bottle wrote it, not the user.
        public let isSuggested: Bool
        public var id: URL { url }
    }

    /// The Windows folders that link out of the prefix.
    public static func links(prefix: URL) -> [Link] {
        let fm = FileManager.default
        let users = prefix.appending(path: "drive_c/users", directoryHint: .isDirectory)
        return ((try? fm.contentsOfDirectory(atPath: users.path)) ?? []).sorted().flatMap { user in
            let profile = users.appending(path: user, directoryHint: .isDirectory)
            return ((try? fm.contentsOfDirectory(atPath: profile.path)) ?? []).sorted().compactMap { folder -> Link? in
                guard PrefixHardening.shellFolders.contains(folder),
                      let destination = try? fm.destinationOfSymbolicLink(atPath: profile.appending(path: folder).path) else { return nil }
                return Link(path: "drive_c/users/\(user)/\(folder)",
                            macFolder: URL(fileURLWithPath: destination, relativeTo: profile).standardizedFileURL)
            }
        }
    }

    /// How long after a launch's log ends a change still counts as the bottle's: a game can write its
    /// settings as it quits.
    static let sessionSlack: TimeInterval = 120
    /// The share of an item's changes made while the bottle ran for it to be suggested. Not all of
    /// them: a launcher in the bottle can write after the launch's log ends (Rockstar's, its cache).
    static let suggestedShare = 0.9
    /// Items with more files than this aren't looked through, nor suggested.
    static let fileLimit = 5_000

    /// What `scan` found in the linked Mac folders.
    public struct Scan: Equatable, Sendable {
        public var items: [Item] = []
        /// Folders that couldn't be read, most likely because macOS wasn't allowed to let Corkscrew in.
        /// What's in them is unknown, so nothing may be copied while there are any: the bottle would
        /// lose its way to their files.
        public var unreadable: [Link] = []
    }

    /// The items of the linked Mac folders that changed after `createdAt`. `sessions`: when the
    /// bottle ran (`sessions(logFolders:)`), to suggest the items only its programs changed.
    ///
    /// Only the `readFolders`. Reads the Mac's Documents, which macOS may ask the user to allow, so
    /// only on their word.
    public static func scan(prefix: URL, since createdAt: Date, sessions: [ClosedRange<Date>]) -> Scan {
        let fm = FileManager.default
        var scan = Scan()
        for link in links(prefix: prefix) where link.isRead {
            guard let contents = try? fm.contentsOfDirectory(at: link.macFolder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                             options: .skipsHiddenFiles) else {
                // A folder that's gone holds nothing to lose.
                if fm.fileExists(atPath: link.macFolder.path) { scan.unreadable.append(link) }
                continue
            }
            scan.items += contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .compactMap { url -> Item? in
                    guard let changes = changes(in: url, since: createdAt) else {
                        // Too big to look through: the user decides, if it changed at all since.
                        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                        return modified.map { $0 > createdAt } ?? true ? Item(url: url, link: link, isSuggested: false) : nil
                    }
                    guard !changes.isEmpty else { return nil }
                    let whileRunning = changes.count { date in
                        sessions.contains { $0.lowerBound <= date && date <= $0.upperBound.addingTimeInterval(sessionSlack) }
                    }
                    let suggested = Double(whileRunning) >= Double(changes.count) * suggestedShare
                    return Item(url: url, link: link, isSuggested: suggested)
                }
        }
        return scan
    }

    /// When `url` and what's in it changed after `date`; nil when it holds more than `fileLimit`.
    /// Hidden files are left out: Finder writes `.DS_Store` when the user only looks.
    static func changes(in url: URL, since date: Date) -> [Date]? {
        var dates: [Date] = []
        var urls = [url]
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                                           options: .skipsHiddenFiles) {
            for case let child as URL in enumerator {
                urls.append(child)
                if urls.count > fileLimit { return nil }
            }
        }
        for url in urls {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified > date {
                dates.append(modified)
            }
        }
        return dates
    }

    /// When programs ran, from their launch logs (`launch-*.log`): from the log's creation to its
    /// last write.
    public static func sessions(logFolders: [URL]) -> [ClosedRange<Date>] {
        let fm = FileManager.default
        return logFolders.flatMap { folder in
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("launch-") && $0.pathExtension == "log" }
                .compactMap { log -> ClosedRange<Date>? in
                    guard let values = try? log.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]),
                          let start = values.creationDate, let end = values.contentModificationDate else { return nil }
                    return start...max(start, end)
                }
        }
    }

    /// Replaces each link with a folder of its own holding copies of `items` (APFS clones, so they
    /// take no space until one side changes). The originals stay in the Mac's folders, and so does
    /// everything in the folders `scan` doesn't look in.
    ///
    /// All or nothing: everything is copied into a folder beside each link first, and the links are
    /// replaced only when every copy is made; a link that can't be replaced puts back the ones
    /// replaced before it. Returns what `Bottle.FolderPlacement.inside` keeps.
    /// Run while nothing runs in the bottle.
    public static func keepInside(prefix: URL, copying items: [Item]) throws -> [String: String] {
        let shellLinks = links(prefix: prefix)
        let staged = try stageCopies(of: items, for: shellLinks, prefix: prefix)
        try replaceLinks(with: staged, prefix: prefix)
        return macFolders(of: shellLinks)
    }

    /// What `Bottle.FolderPlacement.inside` keeps of `links`: each one's Mac folder, by its path in
    /// the prefix.
    static func macFolders(of links: [Link]) -> [String: String] {
        Dictionary(links.map { ($0.path, $0.macFolder.path) }, uniquingKeysWith: { first, _ in first })
    }

    /// A link and the folder beside it that holds the copies meant to replace it.
    private typealias Staged = (link: Link, folder: URL)

    /// Copies `items` into a folder beside each of `links`. When one can't be copied, nothing stays
    /// staged.
    private static func stageCopies(of items: [Item], for links: [Link], prefix: URL) throws -> [Staged] {
        let fm = FileManager.default
        var staged: [Staged] = []
        do {
            for link in links {
                // A Mac folder macOS doesn't let Corkscrew read may hold the bottle's files: keep its link.
                if link.isRead, fm.fileExists(atPath: link.macFolder.path) { _ = try fm.contentsOfDirectory(atPath: link.macFolder.path) }
                let target = prefix.appending(path: link.path)
                let folder = target.deletingLastPathComponent().appending(path: ".\(link.name).copying", directoryHint: .isDirectory)
                try? fm.removeItem(at: folder)
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                staged.append((link, folder))
                for item in items where item.link == link {
                    try fm.copyItem(at: item.url, to: folder.appending(path: item.url.lastPathComponent))
                }
            }
        } catch {
            for (_, folder) in staged { try? fm.removeItem(at: folder) }
            throw error
        }
        return staged
    }

    /// Replaces each link with its staged folder. When one can't be replaced, those already replaced
    /// link to the Mac again: they held only copies, and the originals stayed in the Mac's folders.
    private static func replaceLinks(with staged: [Staged], prefix: URL) throws {
        let fm = FileManager.default
        var replaced: [Link] = []
        do {
            for (link, folder) in staged {
                let target = prefix.appending(path: link.path)
                // The link only: what it points to stays.
                try fm.removeItem(at: target)
                do {
                    try fm.moveItem(at: folder, to: target)
                } catch {
                    try? fm.createSymbolicLink(at: target, withDestinationURL: link.macFolder)
                    throw error
                }
                replaced.append(link)
            }
        } catch {
            for link in replaced {
                let target = prefix.appending(path: link.path)
                try? fm.removeItem(at: target)
                try? fm.createSymbolicLink(at: target, withDestinationURL: link.macFolder)
            }
            for (_, folder) in staged { try? fm.removeItem(at: folder) }
            throw error
        }
    }

    /// Replaces links Wine made again with empty folders. Only for a bottle whose folders are inside:
    /// one still linked would lose its way to the files in the Mac's folders.
    @discardableResult
    public static func unlinkAgain(prefix: URL) throws -> [String] {
        try PrefixHardening.unlinkShellFolders(prefix: prefix).map(\.path)
    }

    /// Links the folders back to the Mac's (`macFolders`, from `keepInside`): what's in each is merged
    /// into the Mac folder (`merge`). The bottle's folder is removed only when everything in it is
    /// copied. `trash`: for tests.
    public static func linkToMac(prefix: URL, macFolders: [String: String],
                                 trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let fm = FileManager.default
        for (path, macFolder) in macFolders.sorted(by: { $0.key < $1.key }) {
            let folder = prefix.appending(path: path, directoryHint: .isDirectory)
            let mac = URL(fileURLWithPath: macFolder, isDirectory: true)
            guard (try? fm.destinationOfSymbolicLink(atPath: folder.path)) == nil else { continue }
            if fm.fileExists(atPath: folder.path) {
                let items = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                // Only a folder with something to copy reaches into the Mac's, which macOS may ask about.
                if !items.isEmpty { try fm.createDirectory(at: mac, withIntermediateDirectories: true) }
                for item in items { try merge(item, into: mac.appending(path: item.lastPathComponent), trash: trash) }
                try fm.removeItem(at: folder)
            }
            try fm.createSymbolicLink(at: folder, withDestinationURL: mac)
        }
    }

    /// Copies `item` to `destination`, folder into folder: a Mac folder of the same name (`My Games`)
    /// can hold other games' saves too, so only the files both have are decided. Of those, the newer
    /// copy stays at `destination` and the older one goes to the Trash.
    static func merge(_ item: URL, into destination: URL, trash: (URL) throws -> Void) throws {
        let fm = FileManager.default
        var itemIsFolder: ObjCBool = false, destinationIsFolder: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &destinationIsFolder) else {
            return try fm.copyItem(at: item, to: destination)
        }
        if fm.fileExists(atPath: item.path, isDirectory: &itemIsFolder), itemIsFolder.boolValue, destinationIsFolder.boolValue {
            for child in try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                try merge(child, into: destination.appending(path: child.lastPathComponent), trash: trash)
            }
            return
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        // The Mac's is newer: it stays, and the bottle's older copy goes to the Trash, not away.
        if modified(destination) > modified(item) { return try trash(item) }
        try trash(destination)
        try fm.copyItem(at: item, to: destination)
    }
}
