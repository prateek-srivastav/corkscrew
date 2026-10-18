import Foundation
import Testing
@testable import GameCore

struct TestedGamesTests {
    /// `scripts/tested-settings.py` edits the JSON; a mistake there would empty the list.
    @Test func testedListReads() throws {
        // Every entry reads (none is left out as a newer version's), and the app carries this file.
        let file = Self.repo.appending(path: "Packages/GameCore/Sources/GameCore/Stores/tested.json")
        #expect(try JSONDecoder().decode([TestedGame].self, from: Data(contentsOf: file)) == Steam.builtInTested)
        #expect(Steam.tested == Steam.builtInTested)
        #expect(Steam.tested.count >= 3)
        #expect(Steam.tested.allSatisfy { !$0.appID.isEmpty && $0.appID.allSatisfy(\.isNumber) })
        #expect(Set(Steam.tested.map(\.appID)).count == Steam.tested.count, "one entry per game")
        #expect(Steam.testedGames.map(\.appID) == ["1174180", "3132990", "417860"])
        #expect(Steam.testedProfiles["1174180"] == GameProfile(backendOverride: .d3dmetal, metalFX: true))
    }

    /// The app downloads the list from this path on main, so the file must stay there.
    @Test func testedListURLNamesTheFile() throws {
        let path = try #require(Steam.testedListURL.path.components(separatedBy: "/main/").last)
        #expect(FileManager.default.fileExists(atPath: Self.repo.appending(path: path).path))
    }

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized

    /// A newer version's list may have settings this one doesn't know: those entries are left out.
    @Test func downloadedListSkipsEntriesItCannotRead() async throws {
        try await withTempDir { root in
            let list = root.appending(path: "tested.json")
            try list.write("""
            [
              {"appID": "1", "name": "Known", "profile": {"backendOverride": "dxmt"}},
              {"appID": "2", "name": "Newer", "profile": {"backendOverride": "a-backend-from-later"}}
            ]
            """)
            #expect(try await Steam.downloadTestedList(from: list) ==
                    [TestedGame(appID: "1", name: "Known", profile: GameProfile(backendOverride: .dxmt))])
        }
    }

    /// The last download is used offline, by the version that saved it only.
    @Test func savedListIsForTheVersionThatSavedIt() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            let games = [TestedGame(appID: "1", name: "Known", listed: true, profile: GameProfile(backendOverride: .dxmt), notes: "Plays.")]
            #expect(Steam.savedTestedList(paths: paths, version: "0.9.0") == nil)

            try Steam.saveTestedList(games, paths: paths, version: "0.9.0")
            #expect(Steam.savedTestedList(paths: paths, version: "0.9.0") == games)
            #expect(Steam.savedTestedList(paths: paths, version: "0.9.1") == nil)

            // The next download replaces it.
            let newer = games + [TestedGame(appID: "2", name: "Added", profile: GameProfile())]
            try Steam.saveTestedList(newer, paths: paths, version: "0.9.0")
            #expect(Steam.savedTestedList(paths: paths, version: "0.9.0") == newer)

            try Steam.savedTestedListFile(paths: paths).write("not JSON")
            #expect(Steam.savedTestedList(paths: paths, version: "0.9.0") == nil)
        }
    }

    /// The built-in list stays when the download isn't a list with a game in it.
    @Test func downloadedListWithNoGameFails() async throws {
        try await withTempDir { root in
            for text in ["[]", "{}", "<html>Not found</html>", #"[{"name": "No app ID"}]"#] {
                let list = root.appending(path: "tested.json")
                try list.write(text)
                await #expect(throws: (any Error).self, "\(text)") { try await Steam.downloadTestedList(from: list) }
            }
        }
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
    /// The share as the relay's /settings takes it (relay/src/share.ts).
    @Test func shareIsWhatTheRelayTakes() throws {
        var game = Steam.entry(appID: "999999", name: "Untested Game", bottleID: UUID(), steamRoot: URL(fileURLWithPath: "/steam"))
        game.profile.backendOverride = .dxmt
        let share = try #require(Steam.share(of: game, playsWell: true, performance: " 1440p High, 60 fps\n", issues: "", minutes: 47,
                                             version: "0.8.0 (11)", mac: "26.1, Mac16,1",
                                             date: Date(timeIntervalSince1970: 1_792_000_000)))
        let request = try share.request(to: URL(string: "https://relay.example/")!)
        #expect(request.url?.absoluteString == "https://relay.example/settings")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(body.keys) == ["game", "appID", "result", "backend", "performance", "issues", "settings", "minutes", "version", "mac", "date"])
        #expect(body["appID"] as? String == "999999")
        #expect(body["result"] as? String == "Plays well")
        #expect(body["backend"] as? String == "DXMT")
        #expect(body["performance"] as? String == "1440p High, 60 fps")
        #expect(body["settings"] as? String == Steam.settingsReport(of: game))
        #expect(body["minutes"] as? Int == 47)
        #expect(body["date"] as? String == "2026-10-14T17:46:40Z")
    }
}
