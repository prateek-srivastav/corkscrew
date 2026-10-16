import Foundation
import Testing
@testable import GameCore

struct GodOfWarSettingsTests {
    /// Before the first launch: the tested settings, with Windows line endings like the game's own file.
    @Test func writesTheTestedSettingsBeforeTheFirstLaunch() throws {
        try withTempDir { game in
            #expect(try GodOfWarSettings.apply(installFolder: game))
            let data = try Data(contentsOf: GodOfWarSettings.settingsFile(installFolder: game))
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.hasPrefix("[Settings]\r\nMonitor=0\r\n"))
            #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
            for line in ["HDR=Off ", "FilmGrain=0 ", "Preset=Ultra ", "DisplayMode=Borderless "] {
                #expect(text.contains("\r\n\(line)"), "\(line)")
            }
            #expect(!text.contains("VideoDevice"), "the game names the adapter itself")
        }
    }

    /// A player's own settings are never replaced.
    @Test func keepsThePlayersSettings() throws {
        try withTempDir { game in
            let file = GodOfWarSettings.settingsFile(installFolder: game)
            try file.write("[Settings]\r\nHDR=On\r\n")
            #expect(try !GodOfWarSettings.apply(installFolder: game))
            #expect(try String(contentsOf: file, encoding: .utf8) == "[Settings]\r\nHDR=On\r\n")
        }
    }

    @Test func recognisesTheGameByItsExecutable() {
        #expect(GodOfWarSettings.isGame(URL(fileURLWithPath: "/Games/God of War/GoW.exe")))
        #expect(!GodOfWarSettings.isGame(URL(fileURLWithPath: "/Games/God of War Ragnarok/GoWR.exe")))
    }
}
