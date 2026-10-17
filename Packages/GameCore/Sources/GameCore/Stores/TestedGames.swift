import Foundation

/// A Steam game with settings that ran well: tested on the developer's Mac (no `source`), or
/// shared by a player from Corkscrew and accepted. A maintainer's "tested" label on the Game
/// report runs `scripts/tested-settings.py`, which adds the entry to `Steam.testedJSON` in a pull request.
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
    /// The tested games, in the library's order. Edited by hand or by `scripts/tested-settings.py`,
    /// which keeps this layout: one JSON array in a raw string. `SteamTests` checks that it reads.
    static let testedJSON = #"""
    [
      {
        "appID": "1174180",
        "name": "Red Dead Redemption 2",
        "listed": true,
        "profile": {"backendOverride": "d3dmetal", "metalFX": true},
        "notes": "DX12 through D3DMetal (GPTK 3.0) with MetalFX, Retina off. Its in-game settings start from RockstarLauncher.rdr2TestedSettings."
      },
      {
        "appID": "3132990",
        "name": "Black Myth: Wukong Benchmark Tool",
        "listed": true,
        "profile": {"backendOverride": "d3dmetal", "metalFX": true, "retinaMode": true},
        "notes": "DX12 through D3DMetal (GPTK 3.0) with MetalFX (pick DLSS in the game), Retina on. In game: Super Resolution ~34, Medium with GI/Reflections/Shadows Low, Frame Generation off (it crashes on DX12)."
      },
      {
        "appID": "417860",
        "name": "Emily is Away",
        "listed": true,
        "profile": {"backendOverride": "dxvk"},
        "notes": "32-bit, DX11 through DXVK."
      }
    ]
    """#

    public static let tested: [TestedGame] = (try? JSONDecoder().decode([TestedGame].self, from: Data(testedJSON.utf8))) ?? []

    /// Settings that ran well, by Steam app id; the detected backend covers everything else.
    public static let testedProfiles: [String: GameProfile] =
        Dictionary(tested.map { ($0.appID, $0.profile) }, uniquingKeysWith: { first, _ in first })

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

    /// A new Game report for a Steam game that ran well, filled in. Its "Corkscrew settings" field
    /// is `settingsReport(of:)`, which a maintainer's "tested" label adds to the tested list.
    public static func shareURL(of game: Game, repository: URL, playsWell: Bool, performance: String, issues: String,
                                version: String, mac: String) -> URL? {
        guard let settings = settingsReport(of: game) else { return nil }
        let result = playsWell ? "Plays well" : "Plays, with issues"
        var components = URLComponents(url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            ("template", "game_report.yml"), ("title", "\(game.name): \(result.lowercased())"), ("game", game.name), ("store", "Steam"),
            ("result", result), ("backend", game.profile.backendOverride?.formName ?? "Automatic"),
            ("settings", performance.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("issues", issues.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("corkscrew", settings), ("version", version), ("mac", mac),
        ].map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url
    }
}
