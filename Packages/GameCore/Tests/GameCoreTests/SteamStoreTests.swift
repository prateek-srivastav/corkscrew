import Foundation
import Testing
@testable import GameCore

struct SteamStoreTests {
    /// The cache keeps its newest files within the limit.
    @Test func trimsTheOldestFilesFirst() throws {
        try withTempDir { cache in
            let fm = FileManager.default
            let now = Date.now
            var files: [URL] = []
            for (index, folder) in ["details", "art/10", "images", "art/20"].enumerated() {
                let file = cache.appending(path: "\(folder)/file\(index)")
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 1, count: 64 << 10).write(to: file)
                try fm.setAttributes([.modificationDate: now.addingTimeInterval(Double(index - 10) * 3600)], ofItemAtPath: file.path)
                files.append(file)
            }
            let size = try #require(try files[0].resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize)
            #expect(SteamStore.trim(cache: cache, limit: 2 * size) == 2 * size)
            #expect(files.map { fm.fileExists(atPath: $0.path) } == [false, false, true, true])
            #expect(SteamStore.trim(cache: cache, limit: 2 * size) == 0)
        }
    }

    @Test func readsAGamesStoreDetails() throws {
        let reply = """
        {"1174180":{"success":true,"data":{"type":"game","name":"Red Dead Redemption 2",
          "short_description":"Arthur Morgan &amp; the gang&#39;s <b>last</b> ride.",
          "developers":["Rockstar Games"],"publishers":["Rockstar Games"],
          "release_date":{"coming_soon":false,"date":"Dec 5, 2019"},
          "genres":[{"id":"1","description":"Action"},{"id":"25","description":"Adventure"}],
          "screenshots":[{"id":0,"path_thumbnail":"https://x/t.jpg","path_full":"https://x/1.jpg"}],
          "header_image":"https://x/header.jpg","background_raw":"https://x/bg.jpg","website":""}}}
        """
        let details = try #require(SteamStore.parseDetails(Data(reply.utf8), appID: "1174180"))
        #expect(details.name == "Red Dead Redemption 2")
        #expect(details.summary == "Arthur Morgan & the gang's last ride.")
        #expect(details.developers == ["Rockstar Games"])
        #expect(details.releaseDate == "Dec 5, 2019")
        #expect(details.genres == ["Action", "Adventure"])
        #expect(details.screenshots == [URL(string: "https://x/1.jpg")!])
        #expect(details.backgroundImage == URL(string: "https://x/bg.jpg"))
        #expect(details.website == nil, "an empty address")
        #expect(SteamStore.parseDetails(Data(#"{"5":{"success":false}}"#.utf8), appID: "5") == nil)
    }

    @Test func matchesAProgramByName() {
        let items = SteamStore.parseSearch(Data("""
        {"total":3,"items":[{"type":"app","name":"Hades II","id":1145350},{"type":"app","name":"Hades","id":1145360},
          {"type":"app","name":"Red Dead Redemption® 2","id":1174180}]}
        """.utf8))
        #expect(items.count == 3)
        #expect(SteamStore.bestMatch(items, for: "hades") == "1145360", "the same name before a longer one")
        #expect(SteamStore.bestMatch(items, for: "Red Dead Redemption 2") == "1174180")
        #expect(SteamStore.bestMatch(items, for: "Red Dead") == nil, "too short a part of the name")
        #expect(SteamStore.bestMatch(items, for: "Setup") == nil)
        #expect(SteamStore.candidateNames(["RDR2", "Binaries", "rdr2", "Red Dead Redemption 2", "x"]) == ["RDR2", "Red Dead Redemption 2"])
    }

    @Test func findsAnAppIDWrittenNextToTheGame() throws {
        try withTempDir { root in
            let game = root.appending(path: "Some Game")
            let binaries = game.appending(path: "Binaries/Win64")
            try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
            let program = binaries.appending(path: "Game.exe")
            #expect(SteamStore.localAppID(near: program) == nil)

            try "[Main]\nAppId=480\nRealAppId=1174180\n".write(to: game.appending(path: "OnlineFix.ini"), atomically: true, encoding: .utf8)
            #expect(SteamStore.localAppID(near: program) == "1174180", "two folders up, the real id over Spacewar's")

            try "730\n".write(to: binaries.appending(path: "steam_appid.txt"), atomically: true, encoding: .utf8)
            #expect(SteamStore.localAppID(near: program) == "730", "nearest first")
        }
        #expect(SteamStore.iniAppID("AppId = 480") == nil, "Spacewar says nothing about the game")
        #expect(SteamStore.appID(in: "12ab") == nil)
    }

    @Test func namesTheProgramsFolders() {
        let program = URL(fileURLWithPath: "/b/drive_c/Games/Red Dead Redemption 2/Binaries/RDR2.exe")
        #expect(SteamStore.folderNames(of: program) == ["Red Dead Redemption 2"], "Binaries and Games say nothing")
    }
}
