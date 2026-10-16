import Foundation

/// Steam's public store (no sign-in needed): a game's details and art, and which Steam app a
/// program is. Replies are cached on disk, so a game page shows at once the next time and offline.
public enum SteamStore {
    public struct Details: Codable, Sendable, Equatable {
        public var appID: String
        public var name: String
        public var summary: String
        public var developers: [String]
        public var publishers: [String]
        public var releaseDate: String?
        public var genres: [String]
        public var screenshots: [URL]
        public var headerImage: URL?
        /// The store page's backdrop, without the page's tint: stands in for missing hero art.
        public var backgroundImage: URL?
        public var website: URL?
    }

    /// Library art Steam keeps for every app, at a fixed address.
    public enum Art: String, Sendable, CaseIterable {
        case hero = "library_hero.jpg"
        case cover = "library_600x900.jpg"
        case logo = "logo.png"
        case header = "header.jpg"
    }

    static let artBase = URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/")!
    static let storeBase = URL(string: "https://store.steampowered.com/api/")!
    /// How long cached details count as fresh, and how long a miss (no art, no match) is believed.
    static let detailsLifetime: TimeInterval = 7 * 24 * 3600
    static let missLifetime: TimeInterval = 24 * 3600

    public static func artURL(_ art: Art, appID: String) -> URL {
        artBase.appending(path: "\(appID)/\(art.rawValue)")
    }

    // MARK: Cached lookups

    /// The game's store details: from the cache while fresh, else from the store (falling back to a
    /// stale copy offline).
    public static func details(appID: String, cache: URL) async -> Details? {
        let file = cache.appending(path: "details/\(appID).json")
        let cached = try? JSONDecoder().decode(Details.self, from: Data(contentsOf: file))
        if let cached, age(of: file) < detailsLifetime { return cached }
        var request = URLComponents(url: storeBase.appending(path: "appdetails"), resolvingAgainstBaseURL: false)!
        request.queryItems = [URLQueryItem(name: "appids", value: appID), URLQueryItem(name: "l", value: "english")]
        guard let data = await fetch(request.url!), let details = parseDetails(data, appID: appID) else { return cached }
        write(try? JSONEncoder().encode(details), to: file)
        return details
    }

    /// The art file, from the cache or Steam's CDN. Nil when Steam has none for the app.
    public static func art(_ art: Art, appID: String, cache: URL) async -> Data? {
        let file = cache.appending(path: "art/\(appID)/\(art.rawValue)")
        let miss = file.appendingPathExtension("missing")
        if let data = try? Data(contentsOf: file) { return data }
        if age(of: miss) < missLifetime { return nil }
        guard let data = await fetch(artURL(art, appID: appID)) else {
            write(Data(), to: miss)
            return nil
        }
        write(data, to: file)
        return data
    }

    /// Any image the store named (a screenshot, a backdrop), cached by its address.
    public static func image(at url: URL, cache: URL) async -> Data? {
        let name = url.path.split(separator: "/").suffix(3).joined(separator: "_")
        let file = cache.appending(path: "images/\(name)")
        if let data = try? Data(contentsOf: file) { return data }
        guard let data = await fetch(url) else { return nil }
        write(data, to: file)
        return data
    }

    /// Which Steam app the program is: an app id written next to it (steam_appid.txt, a Steam
    /// emulator's or loader's settings), else a store search for `names` (the game's name, its
    /// folder's) that finds the same name. Remembered per program, misses for a day.
    public static func appID(forProgram program: URL, names: [String], cache: URL) async -> String? {
        if let local = localAppID(near: program) { return local }
        let file = cache.appending(path: "matches.json")
        var matches = (try? JSONDecoder().decode([String: Match].self, from: Data(contentsOf: file))) ?? [:]
        let key = program.standardizedFileURL.path
        if let match = matches[key], match.appID != nil || Date.now.timeIntervalSince(match.date) < missLifetime {
            return match.appID
        }
        var found: String?
        for name in candidateNames(names) {
            var request = URLComponents(url: storeBase.appending(path: "storesearch/"), resolvingAgainstBaseURL: false)!
            request.queryItems = [URLQueryItem(name: "term", value: name), URLQueryItem(name: "l", value: "english"),
                                  URLQueryItem(name: "cc", value: "US")]
            guard let data = await fetch(request.url!) else { return nil }  // offline: try again later
            if let id = bestMatch(parseSearch(data), for: name) {
                found = id
                break
            }
        }
        matches[key] = Match(appID: found, date: .now)
        write(try? JSONEncoder().encode(matches), to: file)
        return found
    }

    struct Match: Codable {
        var appID: String?
        var date: Date
    }

    // MARK: Local app ids

    /// Files that name a Steam app id next to a game: Steam's own steam_appid.txt, and the settings
    /// of Steam emulators and loaders, which repacked games carry.
    static let appIDFiles = ["steam_appid.txt", "steam_settings/steam_appid.txt"]
    static let appIDSettings = ["steam_emu.ini", "steam_api.ini", "onlinefix.ini", "cream_api.ini", "coldclientloader.ini",
                                "steam_settings/configs.app.ini"]

    /// An app id written in the program's folder or the two above it (games keep the program in
    /// `Binaries/Win64` and the like).
    public static func localAppID(near program: URL) -> String? {
        var folder = program.deletingLastPathComponent()
        for _ in 0..<3 {
            for name in appIDFiles {
                if let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8),
                   let id = appID(in: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return id
                }
            }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for settings in appIDSettings {
                let parts = settings.split(separator: "/")
                guard let file = files.first(where: { $0.lowercased() == parts[0] }) else { continue }
                let url = parts.count == 1 ? folder.appending(path: file) : folder.appending(path: "\(file)/\(parts[1])")
                if let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)),
                   let id = iniAppID(text) {
                    return id
                }
            }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// `RealAppId` first: a loader may run the game as another app (Spacewar, 480) online.
    static func iniAppID(_ text: String) -> String? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            values[parts[0].lowercased()] = parts[1]
        }
        for key in ["realappid", "appid", "app_id", "gameid"] {
            if let value = values[key], let id = appID(in: value), id != "480" { return id }
        }
        return nil
    }

    static func appID(in text: String) -> String? {
        let digits = text.prefix { $0.isNumber }
        return !digits.isEmpty && digits.count <= 10 && digits.count == text.count && digits != "0" ? String(digits) : nil
    }

    // MARK: Names

    /// Folder names that say nothing about the game.
    static let genericFolders: Set<String> = [
        "bin", "bin64", "binaries", "win64", "win32", "x64", "x86", "game", "games", "retail", "release", "shipping",
        "program files", "program files (x86)", "downloads", "desktop", "common", "steamapps", "drive_c", "launcher",
    ]

    /// The names to search for, best first, without duplicates or useless ones.
    static func candidateNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { name in
            let key = normalized(name)
            return key.count >= 3 && !genericFolders.contains(name.lowercased()) && seen.insert(key).inserted
        }
    }

    /// The program's folders, nearest first, that may carry the game's name.
    public static func folderNames(of program: URL) -> [String] {
        var names: [String] = []
        var folder = program.deletingLastPathComponent()
        for _ in 0..<3 where folder.pathComponents.count > 1 {
            names.append(folder.lastPathComponent)
            folder = folder.deletingLastPathComponent()
        }
        return names.filter { !genericFolders.contains($0.lowercased()) }
    }

    /// Lowercased letters and digits only: "Red Dead Redemption® 2" → "reddeadredemption2".
    static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
    }

    // MARK: Parsing

    static func parseDetails(_ data: Data, appID: String) -> Details? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[appID] as? [String: Any], entry["success"] as? Bool == true,
              let app = entry["data"] as? [String: Any], let name = app["name"] as? String else { return nil }
        func url(_ key: String) -> URL? { (app[key] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) } }
        let release = app["release_date"] as? [String: Any]
        return Details(
            appID: appID, name: name,
            summary: plainText(app["short_description"] as? String ?? ""),
            developers: app["developers"] as? [String] ?? [],
            publishers: (app["publishers"] as? [String] ?? []).filter { !$0.isEmpty },
            releaseDate: (release?["date"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            genres: (app["genres"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String },
            screenshots: (app["screenshots"] as? [[String: Any]] ?? []).compactMap { ($0["path_full"] as? String).flatMap(URL.init(string:)) },
            headerImage: url("header_image"),
            backgroundImage: url("background_raw") ?? url("background"),
            website: url("website")
        )
    }

    static func parseSearch(_ data: Data) -> [(id: String, name: String)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard item["type"] as? String ?? "app" == "app", let name = item["name"] as? String else { return nil }
            if let id = item["id"] as? Int { return (String(id), name) }
            return (item["id"] as? String).map { ($0, name) }
        }
    }

    /// The result with the same name; failing that, one whose name starts with the searched one or
    /// the other way round, when they're nearly as long ("Hades II" isn't "Hades").
    static func bestMatch(_ items: [(id: String, name: String)], for name: String) -> String? {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return nil }
        if let exact = items.first(where: { normalized($0.name) == wanted }) { return exact.id }
        return items.first { item in
            let found = normalized(item.name)
            let (short, long) = found.count < wanted.count ? (found, wanted) : (wanted, found)
            return short.count >= 6 && long.hasPrefix(short) && Double(short.count) / Double(long.count) >= 0.8
        }?.id
    }

    /// The store's text without HTML tags and with its few entities decoded.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Files and network

    /// The cache's size limit: art and pages for a few hundred games.
    public static let cacheLimit = 200 << 20

    /// Deletes the cache's oldest files (by when they were fetched) until it holds at most `limit`
    /// bytes; returns how many bytes it freed. What's gone is fetched again when a page needs it.
    @discardableResult
    public static func trim(cache: URL, limit: Int = cacheLimit) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: keys) else { return 0 }
        var files: [(url: URL, date: Date, size: Int)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append((url, values.contentModificationDate ?? .distantPast, values.totalFileAllocatedSize ?? 0))
        }
        var total = files.reduce(0) { $0 + $1.size }
        var freed = 0
        for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
            guard (try? FileManager.default.removeItem(at: file.url)) != nil else { continue }
            total -= file.size
            freed += file.size
        }
        return freed
    }

    private static func age(of file: URL) -> TimeInterval {
        guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return .infinity }
        return Date.now.timeIntervalSince(date)
    }

    private static func write(_ data: Data?, to file: URL) {
        guard let data else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The store's own connection, without URLCache: the store keeps its replies on disk itself,
    /// and the shared session kept a second copy of each.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// The body of a 200 reply; nil for anything else (offline, missing art).
    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Corkscrew", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }
}
