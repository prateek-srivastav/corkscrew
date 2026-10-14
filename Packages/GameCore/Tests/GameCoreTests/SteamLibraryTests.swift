import Foundation
import Testing
@testable import GameCore

struct SteamLibraryTests {
    @Test func accountIsTheMostRecentUser() throws {
        try withTempDir { steam in
            try steam.appending(path: "config/loginusers.vdf").write("""
            "users"
            {
            \t"76561190000000001"
            \t{
            \t\t"AccountName"\t\t"old"
            \t\t"PersonaName"\t\t"Old Name"
            \t\t"RememberPassword"\t\t"1"
            \t\t"MostRecent"\t\t"0"
            \t}
            \t"76561190000000002"
            \t{
            \t\t"AccountName"\t\t"player"
            \t\t"PersonaName"\t\t"Player \\"One\\""
            \t\t"RememberPassword"\t\t"1"
            \t\t"AllowAutoLogin"\t\t"1"
            \t\t"mostrecent"\t\t"1"
            \t}
            }
            """)
            let account = try #require(Steam.account(steamRoot: steam))
            #expect(account.steamID == "76561190000000002")
            #expect(account.accountName == "player")
            #expect(account.personaName == "Player \"One\"")
            #expect(account.remembersSignIn)
        }
    }

    @Test func noAccountAfterSigningOut() throws {
        try withTempDir { steam in
            #expect(Steam.account(steamRoot: steam) == nil)
            try steam.appending(path: "config/loginusers.vdf").write("\"users\"\n{\n}\n")
            #expect(Steam.account(steamRoot: steam) == nil)
        }
    }

    @Test func signInNotRememberedWithoutAutoLogin() throws {
        try withTempDir { steam in
            try steam.appending(path: "config/loginusers.vdf").write("""
            "users" { "1" { "AccountName" "a" "RememberPassword" "1" "AllowAutoLogin" "0" } }
            """)
            #expect(Steam.account(steamRoot: steam)?.remembersSignIn == false)
        }
    }

    @Test(arguments: [27, 28, 29])
    func libraryGamesAreCachedAppsThatAreGames(version: Int) throws {
        try withTempDir { steam in
            let cache = steam.appending(path: "appcache/librarycache")
            for id in ["10", "20", "30"] { try cache.appending(path: "\(id)/library_600x900.jpg").write("jpg") }
            // Older Steam: flat files named after the app.
            try cache.appending(path: "50_library_hero.jpg").write("jpg")
            try steam.appending(path: "appcache/appinfo.vdf").write(AppInfoBuilder(version: version, apps: [
                (10, "Game", "Zeta"),
                (20, "Tool", "Dedicated Server"),
                (30, "game", "Alpha"),
                (40, "Game", "Not In Library"),
                (50, "Game", "Beta"),
            ]).build())
            #expect(Steam.libraryGames(steamRoot: steam) == [
                .init(appID: "30", name: "Alpha"), .init(appID: "50", name: "Beta"), .init(appID: "10", name: "Zeta"),
            ])
        }
    }

    @Test func noLibraryWithoutAppInfo() throws {
        try withTempDir { steam in
            try steam.appending(path: "appcache/librarycache/10/logo.png").write("png")
            #expect(Steam.libraryGames(steamRoot: steam).isEmpty)
            try steam.appending(path: "appcache/appinfo.vdf").write(Data([1, 2, 3]))
            #expect(Steam.libraryGames(steamRoot: steam).isEmpty)
        }
    }

    @Test func entryStartsTheGameThroughSteamWithItsTestedSettings() {
        let steam = URL(fileURLWithPath: "/prefix/drive_c/Program Files (x86)/Steam")
        let bottle = UUID()
        let tested = Steam.entry(appID: "1174180", name: "Red Dead Redemption 2", bottleID: bottle, steamRoot: steam)
        #expect(tested.executable == steam.appending(path: "steam.exe"))
        #expect(tested.profile.backendOverride == .d3dmetal)
        #expect(tested.profile.arguments == Steam.clientArguments + [Steam.silentArgument, "-applaunch", "1174180"])
        #expect(tested.store == StoreItem(store: Steam.store, appID: "1174180"))
        let other = Steam.entry(appID: "10", name: "Other", bottleID: bottle, steamRoot: steam, profile: GameProfile(backendOverride: .dxmt))
        #expect(other.profile.backendOverride == .dxmt)
    }
}

/// Writes `appcache/appinfo.vdf` in format 27, 28 or 29, each app with `appinfo/common/{type,name}`.
private struct AppInfoBuilder {
    let version: Int
    let apps: [(id: UInt32, type: String, name: String)]

    func build() -> Data {
        var strings: [String] = []
        func key(_ name: String) -> [UInt8] {
            guard version == 29 else { return Array(name.utf8) + [0] }
            if !strings.contains(name) { strings.append(name) }
            return le32(UInt32(strings.firstIndex(of: name)!))
        }
        var body: [UInt8] = []
        for app in apps {
            var kv: [UInt8] = []
            kv += [0] + key("appinfo")
            kv += [2] + key("appid") + le32(app.id)
            kv += [0] + key("common")
            kv += [1] + key("name") + Array(app.name.utf8) + [0]
            kv += [1] + key("type") + Array(app.type.utf8) + [0]
            kv += [7] + key("gameid") + le64(UInt64(app.id))
            kv += [8, 8, 8]
            let header = [UInt8](repeating: 0, count: 4 + 4 + 8 + 20 + 4 + (version >= 28 ? 20 : 0))
            body += le32(app.id) + le32(UInt32(header.count + kv.count)) + header + kv
        }
        body += le32(0)
        // The magic ends in the version as hex digits: 0x07564427 for 27.
        var file = le32(UInt32(0x0756_4400 + version / 10 * 16 + version % 10)) + le32(1)
        if version == 29 {
            let tableOffset = file.count + 8 + body.count
            file += le64(UInt64(tableOffset)) + body + le32(UInt32(strings.count))
            for string in strings { file += Array(string.utf8) + [0] }
        } else {
            file += body
        }
        return Data(file)
    }

    private func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    private func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
}
