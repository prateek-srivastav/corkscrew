import Foundation
import Synchronization

/// A Steam game with settings that ran well: tested on the developer's Mac (no `source`), or
/// shared by a player from Corkscrew and accepted. A maintainer's "tested" label on the Game
/// report runs `scripts/tested-settings.py`, which adds the entry to `tested.json` in a pull request.
public struct TestedGame: Codable, Sendable, Equatable {
    public var appID: String
    public var name: String
    /// Shown in the library before it's installed (`Steam.testedGames`). Shared games aren't,
    /// until someone here plays them: their settings only apply once the game is installed.
    public var listed: Bool
    /// Only the settings that change how the game runs (`Steam.sharedProfile(of:)`). Its
    /// arguments are the game's own; `Steam.entry` puts Steam's in front.
    public var profile: GameProfile
    /// In-game settings, performance, and what doesn't work.
    public var notes: String?
    /// The Game report it came from.
    public var source: String?

    public init(appID: String, name: String, listed: Bool = false, profile: GameProfile, notes: String? = nil, source: String? = nil) {
        self.appID = appID
        self.name = name
        self.listed = listed
        self.profile = profile
        self.notes = notes
        self.source = source
    }

    /// A missing `listed` is false: the Game report's settings don't have it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decode(String.self, forKey: .appID)
        name = try c.decode(String.self, forKey: .name)
        listed = try c.decodeIfPresent(Bool.self, forKey: .listed) ?? false
        profile = try c.decode(GameProfile.self, forKey: .profile)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }
}

extension Steam {
    /// `tested.json` on main, which the app reads when it opens: settings accepted after a release
    /// reach players without a new one. Older versions read it too, so add keys; don't rename or
    /// remove them, and don't move the file.
    public static let testedListURL = URL(string: "https://raw.githubusercontent.com/Prateek-Srivastav/corkscrew/main/Packages/GameCore/Sources/GameCore/Stores/tested.json")!

    /// The list this version carries, `tested.json` (edited by hand or by `scripts/tested-settings.py`).
    static let builtInTested: [TestedGame] = {
        guard let url = Bundle.module.url(forResource: "tested", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? testedList(from: data)) ?? []
    }()

    private static let testedList = Mutex(builtInTested)

    /// The tested games, in the library's order: the built-in list, or the one `useTestedList` set.
    public static var tested: [TestedGame] { testedList.withLock { $0 } }

    /// Uses `games` as the tested list from now on. Returns whether the list changed.
    @discardableResult
    public static func useTestedList(_ games: [TestedGame]) -> Bool {
        testedList.withLock { list in
            defer { list = games }
            return list != games
        }
    }

    /// Reads the tested list at `url`, the one on main by default.
    public static func downloadTestedList(from url: URL = testedListURL) async throws -> [TestedGame] {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return try testedList(from: data)
    }

    /// The list the last download saved in the caches, if this version of the app saved it. Another
    /// version's copy doesn't count: a newer version's own list is at least as new.
    public static func savedTestedList(paths: AppPaths, version: String) -> [TestedGame]? {
        guard let data = try? Data(contentsOf: savedTestedListFile(paths: paths)),
              let saved = try? JSONDecoder().decode(SavedTestedList.self, from: data), saved.version == version else { return nil }
        return saved.games
    }

    /// Saves a downloaded list in the caches, in place of the one saved before.
    public static func saveTestedList(_ games: [TestedGame], paths: AppPaths, version: String) throws {
        try FileManager.default.createDirectory(at: paths.cachesRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(SavedTestedList(version: version, games: games)).write(to: savedTestedListFile(paths: paths), options: .atomic)
    }

    private struct SavedTestedList: Codable {
        var version: String
        var games: [TestedGame]
    }

    static func savedTestedListFile(paths: AppPaths) -> URL { paths.cachesRoot.appending(path: "tested.json") }

    /// Entries this version can't read (a newer version's settings) are left out. Throws when none reads.
    static func testedList(from data: Data) throws -> [TestedGame] {
        struct Entry: Decodable {
            var game: TestedGame?
            init(from decoder: Decoder) { game = try? TestedGame(from: decoder) }
        }
        let games = try JSONDecoder().decode([Entry].self, from: data).compactMap(\.game)
        guard !games.isEmpty else { throw URLError(.cannotDecodeContentData) }
        return games
    }

    /// Settings that ran well, by Steam app id; the detected backend covers everything else.
    public static var testedProfiles: [String: GameProfile] {
        Dictionary(tested.map { ($0.appID, $0.profile) }, uniquingKeysWith: { first, _ in first })
    }

    /// Games tested with Corkscrew, shown in the library before they're installed: their button opens
    /// their store page in Steam, and they start with their tested settings once downloaded.
    public static var testedGames: [(appID: String, name: String)] { tested.filter(\.listed).map { ($0.appID, $0.name) } }

    public static func isTested(appID: String) -> Bool { tested.contains { $0.appID == appID && $0.listed } }

    /// A Steam game's own launch arguments: what follows `-applaunch <id>`.
    public static func gameArguments(of game: Game) -> [String] {
        let arguments = game.profile.arguments
        guard let index = arguments.firstIndex(of: "-applaunch"), index + 1 < arguments.endIndex else { return [] }
        return Array(arguments[(index + 2)...])
    }

    /// The settings a player shares for a game that ran well: the ones that change how it runs
    /// (not the Metal HUD, the performance overlay or Wine's debug output), and the game's own arguments.
    public static func sharedProfile(of game: Game) -> GameProfile { shared(game.profile, arguments: gameArguments(of: game)) }

    private static func shared(_ profile: GameProfile, arguments: [String]) -> GameProfile {
        GameProfile(backendOverride: profile.backendOverride, metalFX: profile.metalFX, retinaMode: profile.retinaMode,
                    advertiseAVX: profile.advertiseAVX, steamOverlay: profile.steamOverlay,
                    arguments: arguments, environment: profile.environment)
    }

    /// A Steam game, not Steam itself, whose settings aren't the tested ones: worth sharing.
    public static func canShareSettings(of game: Game) -> Bool {
        guard game.store?.store == store, let appID = game.store?.appID else { return false }
        return testedProfiles[appID].map { shared($0, arguments: $0.arguments) } != sharedProfile(of: game)
    }

    /// The Game report's "Corkscrew settings" field: one JSON line with only the shared settings,
    /// which is what `scripts/tested-settings.py` takes.
    public static func settingsReport(of game: Game) -> String? {
        guard let appID = game.store?.appID else { return nil }
        let profile = sharedProfile(of: game)
        var settings: [String: Any] = ["metalFX": profile.metalFX, "retinaMode": profile.retinaMode,
                                       "advertiseAVX": profile.advertiseAVX, "steamOverlay": profile.steamOverlay]
        if let backend = profile.backendOverride { settings["backendOverride"] = backend.rawValue }
        if !profile.arguments.isEmpty { settings["arguments"] = profile.arguments }
        if !profile.environment.isEmpty { settings["environment"] = profile.environment }
        let report: [String: Any] = ["appID": appID, "name": game.name, "profile": settings]
        return (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// What the share sheet sends for a Steam game that ran well. Nil for a game that isn't from Steam.
    public static func share(of game: Game, playsWell: Bool, performance: String, issues: String, minutes: Int,
                             version: String, mac: String, date: Date = .now) -> SettingsShare? {
        guard let appID = game.store?.appID, let settings = settingsReport(of: game) else { return nil }
        return SettingsShare(game: game.name, appID: appID, result: playsWell ? "Plays well" : "Plays, with issues",
                             backend: game.profile.backendOverride?.formName ?? "Automatic",
                             performance: performance.trimmingCharacters(in: .whitespacesAndNewlines),
                             issues: issues.trimmingCharacters(in: .whitespacesAndNewlines),
                             settings: settings, minutes: minutes, version: version, mac: mac, date: date)
    }
}

/// Settings a player shares, for the relay's `settings` path (`relay/src/share.ts`). The relay
/// opens a Game report on GitHub with them; its "Corkscrew settings" field is `settings`, which a
/// maintainer's "tested" label adds to the tested list.
public struct SettingsShare: Codable, Equatable, Sendable {
    public var game: String
    public var appID: String
    /// The Game report's result: "Plays well" or "Plays, with issues".
    public var result: String
    /// The Game report's graphics backend: "Automatic" or `GraphicsBackend.formName`.
    public var backend: String
    public var performance: String
    public var issues: String
    /// `Steam.settingsReport(of:)`.
    public var settings: String
    /// How long the game ran, without a crash, before the app asked.
    public var minutes: Int
    public var version: String
    public var mac: String
    public var date: Date

    /// The share as JSON, for the relay at `relay`.
    public func request(to relay: URL) throws -> URLRequest { try ProblemReport.post(self, to: relay.appending(path: "settings")) }

    /// Posts the share. Throws unless the relay kept it.
    public func send(to relay: URL) async throws { _ = try await ProblemReport.send(request(to: relay)) }
}
