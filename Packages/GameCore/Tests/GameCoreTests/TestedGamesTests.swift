import Foundation
import Testing
@testable import GameCore

struct TestedGamesTests {
    /// `scripts/tested-settings.py` edits the JSON; a mistake there would empty the list.
    @Test func testedListReads() throws {
        let data = Data(Steam.testedJSON.utf8)
        #expect(try JSONDecoder().decode([TestedGame].self, from: data) == Steam.tested)
        #expect(Steam.tested.count >= 3)
        #expect(Steam.tested.allSatisfy { !$0.appID.isEmpty && $0.appID.allSatisfy(\.isNumber) })
        #expect(Set(Steam.tested.map(\.appID)).count == Steam.tested.count, "one entry per game")
        #expect(Steam.testedGames.map(\.appID) == ["1174180", "3132990", "417860"])
        #expect(Steam.testedProfiles["1174180"] == GameProfile(backendOverride: .d3dmetal, metalFX: true))
    }

    /// Only what changes how a game runs is shared, with its own arguments and not Steam's.
    @Test func sharesTheSettingsThatMatter() {
        var game = Steam.entry(appID: "999999", name: "Untested Game", bottleID: UUID(), steamRoot: URL(fileURLWithPath: "/steam"))
        game.profile.backendOverride = .dxmt
        game.profile.metalHUD = true
        game.profile.verboseLogging = true
        game.profile.performanceOverlay = true
        game.profile.arguments += ["-novid", "-dx11"]
        game.profile.environment = ["DXMT_LOG_LEVEL": "none"]
        #expect(Steam.sharedProfile(of: game) == GameProfile(backendOverride: .dxmt, arguments: ["-novid", "-dx11"],
                                                             environment: ["DXMT_LOG_LEVEL": "none"]))
    }

    /// A tested game asks again only once its settings are changed; Steam itself never.
    @Test func asksToShareOnlyNewSettings() {
        let steam = URL(fileURLWithPath: "/steam")
        var rdr2 = Steam.entry(appID: "1174180", name: "Red Dead Redemption 2", bottleID: UUID(), steamRoot: steam)
        rdr2.profile.metalHUD = true
        #expect(!Steam.canShareSettings(of: rdr2))
        rdr2.profile.retinaMode = true
        #expect(Steam.canShareSettings(of: rdr2))
        #expect(Steam.canShareSettings(of: Steam.entry(appID: "999999", name: "Untested Game", bottleID: UUID(), steamRoot: steam)))
        let client = Game(name: "Steam", executable: steam.appending(path: "steam.exe"), bottleID: UUID(), profile: Steam.clientProfile,
                          store: StoreItem(store: Steam.store))
        #expect(!Steam.canShareSettings(of: client))
    }

    /// The Game report's settings field reads back as an entry the tested list can take.
    @Test func settingsReportReadsBack() throws {
        var game = Steam.entry(appID: "999999", name: "Untested Game", bottleID: UUID(), steamRoot: URL(fileURLWithPath: "/steam"))
        game.profile.backendOverride = .wined3d
        let report = try #require(Steam.settingsReport(of: game))
        #expect(!report.contains("\n"))
        // The settings scripts/tested-settings.py takes; it turns down reports with others.
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        let profile = try #require(sent["profile"] as? [String: Any])
        #expect(Set(profile.keys) == ["backendOverride", "metalFX", "retinaMode", "advertiseAVX", "steamOverlay"])
        let entry = try JSONDecoder().decode(TestedGame.self, from: Data(report.utf8))
        #expect(entry == TestedGame(appID: "999999", name: "Untested Game", listed: false, profile: GameProfile(backendOverride: .wined3d)))
    }

    /// The Game report form, filled in, with the settings where the workflow reads them.
    @Test func shareLinkFillsTheGameReport() throws {
        var game = Steam.entry(appID: "999999", name: "Untested Game", bottleID: UUID(), steamRoot: URL(fileURLWithPath: "/steam"))
        game.profile.backendOverride = .dxmt
        let url = try #require(Steam.shareURL(of: game, repository: URL(string: "https://github.com/o/r")!, playsWell: true,
                                              performance: " 1440p High, 60 fps\n", issues: "", version: "0.8.0 (11)", mac: "26.1, Mac16,1"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func field(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(url.path == "/o/r/issues/new")
        #expect(field("template") == "game_report.yml")
        #expect(field("result") == "Plays well")
        #expect(field("backend") == "DXMT")
        #expect(field("settings") == "1440p High, 60 fps")
        #expect(field("corkscrew") == Steam.settingsReport(of: game))
        #expect(field("title") == "Untested Game: plays well")
    }
}
