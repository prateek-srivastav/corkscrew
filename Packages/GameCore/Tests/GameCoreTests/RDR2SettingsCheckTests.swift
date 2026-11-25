import Foundation
import Testing
@testable import GameCore

struct RDR2SettingsCheckTests {
    /// A settings file with these levels and a few settings that aren't levels.
    private func settings(_ levels: [(String, String)], windowed: String = "0") -> String {
        (["<rage__fwuiSystemSettingsCollection>", "  <graphics>", "    <anisotropicFiltering value=\"3\" />"]
            + levels.map { "    <\($0.0)>kSettingLevel_\($0.1)</\($0.0)>" }
            + ["  </graphics>", "  <video>", "    <windowed value=\"\(windowed)\" />", "  </video>",
               "</rage__fwuiSystemSettingsCollection>"])
            .joined(separator: "\r\n")
    }

    @Test func findsTheLevelsThatWentDown() {
        let kept = settings([("textureQuality", "Ultra"), ("shadowQuality", "High"), ("ssao", "Medium"), ("waterQuality", "Low")])
        let now = settings([("textureQuality", "High"), ("shadowQuality", "Medium"), ("ssao", "High"), ("waterQuality", "Low"),
                            ("newQuality", "Low")], windowed: "2")
        #expect(RockstarLauncher.drops(from: kept, to: now) == [
            .init(name: "textureQuality", kept: "Ultra", now: "High"),
            .init(name: "shadowQuality", kept: "High", now: "Medium"),
        ], "raised, unchanged and new levels and other settings aren't drops")
        #expect(RockstarLauncher.drops(from: kept, to: kept).isEmpty)
        // A level the game added since isn't ordered.
        #expect(RockstarLauncher.drops(from: kept, to: settings([("textureQuality", "Special")])).isEmpty)
    }

    @Test func namesSettingsForTheUser() {
        #expect(RockstarLauncher.SettingDrop(name: "textureQuality", kept: "Ultra", now: "High").text == "Texture quality: Ultra → High")
        #expect(RockstarLauncher.SettingDrop.label("POMQuality") == "POM quality")
        #expect(RockstarLauncher.SettingDrop.label("ssao") == "SSAO")
        #expect(RockstarLauncher.SettingDrop.label("volumetricsRaymarchQuality") == "Volumetrics raymarch quality")
    }

    @Test func comparesWithTheTestedSettingsUntilSomeAreKept() throws {
        try withTempDir { root in
            let prefix = root.appending(path: "prefix")
            let file = RockstarLauncher.rdr2Settings(prefix: prefix)
            #expect(RockstarLauncher.settingDrops(prefix: prefix).isEmpty, "no settings before the first launch")

            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try RockstarLauncher.rdr2TestedSettings.write(to: file, atomically: true, encoding: .utf8)
            #expect(RockstarLauncher.settingDrops(prefix: prefix).isEmpty)

            #expect(try !RockstarLauncher.keepRaisedSettings(prefix: prefix), "nothing raised")

            // The game lowered textures (Ultra in the tested settings).
            let lowered = RockstarLauncher.rdr2TestedSettings.replacingOccurrences(
                of: "<textureQuality>kSettingLevel_Ultra<", with: "<textureQuality>kSettingLevel_High<")
            try lowered.write(to: file, atomically: true, encoding: .utf8)
            #expect(RockstarLauncher.settingDrops(prefix: prefix) == [.init(name: "textureQuality", kept: "Ultra", now: "High")])
            #expect(try !RockstarLauncher.keepRaisedSettings(prefix: prefix), "a drop isn't kept by itself")
            #expect(RockstarLauncher.settingDrops(prefix: prefix).count == 1, "asks until kept or restored")

            // Restore puts back the tested settings while none are kept.
            try RockstarLauncher.restoreKeptSettings(prefix: prefix, desktop: nil)
            #expect(try String(contentsOf: file, encoding: .utf8) == RockstarLauncher.rdr2TestedSettings)
            #expect(try String(contentsOf: file.appendingPathExtension("bak"), encoding: .utf8) == lowered)

            // Keep makes the lower ones the kept ones.
            try lowered.write(to: file, atomically: true, encoding: .utf8)
            try RockstarLauncher.keepSettings(prefix: prefix)
            #expect(RockstarLauncher.settingDrops(prefix: prefix).isEmpty)
        }
    }

    @Test func keepsSettingsThePlayerRaised() throws {
        try withTempDir { root in
            let prefix = root.appending(path: "prefix")
            let file = RockstarLauncher.rdr2Settings(prefix: prefix)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let raised = RockstarLauncher.rdr2TestedSettings.replacingOccurrences(
                of: "<waterQuality>kSettingLevel_Medium<", with: "<waterQuality>kSettingLevel_Ultra<")
            try raised.write(to: file, atomically: true, encoding: .utf8)
            #expect(RockstarLauncher.settingDrops(prefix: prefix).isEmpty)
            #expect(try RockstarLauncher.keepRaisedSettings(prefix: prefix))
            #expect(try !RockstarLauncher.keepRaisedSettings(prefix: prefix), "already kept")
            #expect(try String(contentsOf: RockstarLauncher.keptSettings(prefix: prefix), encoding: .utf8) == raised)

            // Then Safe Mode: lower than the raised ones, and Restore puts the raised ones back.
            try RockstarLauncher.rdr2TestedSettings.write(to: file, atomically: true, encoding: .utf8)
            #expect(RockstarLauncher.settingDrops(prefix: prefix) == [.init(name: "waterQuality", kept: "Ultra", now: "Medium")])
            try RockstarLauncher.restoreKeptSettings(prefix: prefix, desktop: nil)
            #expect(try String(contentsOf: file, encoding: .utf8) == raised)

            // Restoring the tested settings makes them the kept ones again.
            try RockstarLauncher.restoreTestedSettings(prefix: prefix, desktop: nil)
            #expect(!FileManager.default.fileExists(atPath: RockstarLauncher.keptSettings(prefix: prefix).path))
            #expect(RockstarLauncher.settingDrops(prefix: prefix).isEmpty)
        }
    }
}
