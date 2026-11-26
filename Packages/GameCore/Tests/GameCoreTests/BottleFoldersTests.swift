import Foundation
import Testing
@testable import GameCore

struct BottleFoldersTests {
    /// A prefix whose Documents and Videos link to a Mac home in `root`, as Wine makes them.
    private func linkedPrefix(in root: URL) throws -> (prefix: URL, mac: URL) {
        let fm = FileManager.default
        let prefix = root.appending(path: "prefix", directoryHint: .isDirectory)
        let mac = root.appending(path: "mac-home", directoryHint: .isDirectory)
        let user = try prefix.appending(path: "drive_c/users/crossover").makeDirectory()
        for (folder, macFolder) in [("Documents", "Documents"), ("Videos", "Movies")] {
            try mac.appending(path: macFolder).makeDirectory()
            try fm.createSymbolicLink(atPath: user.appending(path: folder).path, withDestinationPath: mac.appending(path: macFolder).path)
        }
        try user.appending(path: "AppData").makeDirectory()
        return (prefix, mac)
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func suggestsWhatOnlyTheBottleChanged() throws {
        try withTempDir { root in
            let (prefix, mac) = try linkedPrefix(in: root)
            let created = Date(timeIntervalSince1970: 1_000_000)
            let played = created.addingTimeInterval(3600)...created.addingTimeInterval(7200)
            let documents = mac.appending(path: "Documents")

            // The game's saves, written while the bottle ran (one as it quit).
            let saves = documents.appending(path: "Rockstar Games")
            try saves.appending(path: "Profiles/save1").write("save")
            try setModified(saves.appending(path: "Profiles/save1"), played.upperBound.addingTimeInterval(30))
            try setModified(saves.appending(path: "Profiles"), played.lowerBound.addingTimeInterval(60))
            try setModified(saves, played.lowerBound.addingTimeInterval(60))
            // Nine more while it ran, and its launcher's cache once after.
            for index in 1...9 {
                let file = saves.appending(path: "Profiles/save\(index + 1)")
                try file.write("save")
                try setModified(file, played.lowerBound.addingTimeInterval(Double(index)))
            }
            try saves.appending(path: "Launcher/cache").write("cache")
            try setModified(saves.appending(path: "Launcher/cache"), played.upperBound.addingTimeInterval(3600))
            try setModified(saves.appending(path: "Launcher"), played.lowerBound)
            try setModified(saves.appending(path: "Profiles"), played.lowerBound.addingTimeInterval(60))
            try setModified(saves, played.lowerBound.addingTimeInterval(60))
            // The user's, changed after the bottle was made but while it didn't run.
            try documents.appending(path: "Notes/todo.txt").write("mine")
            try setModified(documents.appending(path: "Notes/todo.txt"), created.addingTimeInterval(20_000))
            try setModified(documents.appending(path: "Notes"), played.lowerBound)
            // Older than the bottle: no program in it wrote this.
            try documents.appending(path: "Taxes.pdf").write("old")
            try setModified(documents.appending(path: "Taxes.pdf"), created.addingTimeInterval(-60))
            try documents.appending(path: ".DS_Store").write("finder")
            // A clip the game made while it ran: Movies isn't looked in, it stays on the Mac.
            try mac.appending(path: "Movies/clip.mp4").write("clip")
            try setModified(mac.appending(path: "Movies/clip.mp4"), played.lowerBound)

            let items = BottleFolders.scan(prefix: prefix, since: created, sessions: [played]).items
            #expect(items.map(\.url.lastPathComponent) == ["Notes", "Rockstar Games"])
            #expect(items.map(\.isSuggested) == [false, true])
            #expect(items.allSatisfy { $0.link.path == "drive_c/users/crossover/Documents" })
        }
    }

    @Test func saysWhichFoldersItCouldntRead() throws {
        try withTempDir { root in
            let fm = FileManager.default
            let (prefix, mac) = try linkedPrefix(in: root)
            let documents = mac.appending(path: "Documents")
            try documents.appending(path: "Rockstar Games/settings.xml").write("ultra")
            // Like a folder macOS doesn't let Corkscrew into.
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: documents.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: documents.path) }
            try fm.removeItem(at: mac.appending(path: "Movies"))

            let scan = BottleFolders.scan(prefix: prefix, since: .distantPast, sessions: [])
            #expect(scan.items.isEmpty)
            #expect(scan.unreadable.map(\.name) == ["Documents"], "a missing folder has nothing to lose")
        }
    }

    @Test func copiesTheTickedItemsInAndLeavesTheMacsAlone() throws {
        try withTempDir { root in
            let fm = FileManager.default
            let (prefix, mac) = try linkedPrefix(in: root)
            try mac.appending(path: "Documents/Rockstar Games/settings.xml").write("ultra")
            try mac.appending(path: "Documents/Notes/todo.txt").write("mine")
            try mac.appending(path: "Movies/clip.mp4").write("clip")
            let items = BottleFolders.scan(prefix: prefix, since: .distantPast, sessions: []).items
            let ticked = items.filter { $0.url.lastPathComponent == "Rockstar Games" }

            let macFolders = try BottleFolders.keepInside(prefix: prefix, copying: ticked)
            #expect(macFolders == [
                "drive_c/users/crossover/Documents": mac.appending(path: "Documents").path,
                "drive_c/users/crossover/Videos": mac.appending(path: "Movies").path,
            ])
            let documents = prefix.appending(path: "drive_c/users/crossover/Documents")
            #expect((try? fm.destinationOfSymbolicLink(atPath: documents.path)) == nil)
            #expect(try fm.contentsOfDirectory(atPath: documents.path) == ["Rockstar Games"])
            #expect(try String(contentsOf: documents.appending(path: "Rockstar Games/settings.xml"), encoding: .utf8) == "ultra")
            #expect(try fm.contentsOfDirectory(atPath: prefix.appending(path: "drive_c/users/crossover/Videos").path).isEmpty)
            #expect(fm.fileExists(atPath: mac.appending(path: "Movies/clip.mp4").path))
            #expect(try fm.contentsOfDirectory(atPath: mac.appending(path: "Documents").path).sorted() == ["Notes", "Rockstar Games"],
                    "the originals stay")
            #expect(BottleFolders.links(prefix: prefix).isEmpty)
            #expect(fm.fileExists(atPath: prefix.appending(path: "drive_c/users/crossover/AppData").path))
        }
    }

    @Test func keepsTheLinksWhenACopyFails() throws {
        try withTempDir { root in
            let fm = FileManager.default
            let (prefix, mac) = try linkedPrefix(in: root)
            try mac.appending(path: "Documents/Rockstar Games/settings.xml").write("ultra")
            let items = BottleFolders.scan(prefix: prefix, since: .distantPast, sessions: []).items
            // Gone before it's copied, like a file iCloud can't download.
            try fm.removeItem(at: mac.appending(path: "Documents/Rockstar Games"))

            #expect(throws: (any Error).self) { try BottleFolders.keepInside(prefix: prefix, copying: items) }
            #expect(BottleFolders.links(prefix: prefix).map(\.name) == ["Documents", "Videos"])
            let user = prefix.appending(path: "drive_c/users/crossover")
            #expect(try fm.contentsOfDirectory(atPath: user.path).sorted() == ["AppData", "Documents", "Videos"], "no copying folders left")
        }
    }

    @Test func unlinksWhatWineLinksAgainAndLinksBack() throws {
        try withTempDir { root in
            let fm = FileManager.default
            let (prefix, mac) = try linkedPrefix(in: root)
            try mac.appending(path: "Documents/Rockstar Games/settings.xml").write("old")
            let items = BottleFolders.scan(prefix: prefix, since: .distantPast, sessions: []).items
            let macFolders = try BottleFolders.keepInside(prefix: prefix, copying: items)
            let documents = prefix.appending(path: "drive_c/users/crossover/Documents")
            try documents.appending(path: "Rockstar Games/settings.xml").write("new")

            // A Wine update links the empty Videos again.
            let videos = prefix.appending(path: "drive_c/users/crossover/Videos")
            try fm.removeItem(at: videos)
            try fm.createSymbolicLink(atPath: videos.path, withDestinationPath: mac.appending(path: "Movies").path)
            #expect(try BottleFolders.unlinkAgain(prefix: prefix) == ["drive_c/users/crossover/Videos"])
            #expect(try BottleFolders.unlinkAgain(prefix: prefix).isEmpty)

            // Back to the Mac's folders: the bottle's newer copy wins.
            var trashed: [String] = []
            try BottleFolders.linkToMac(prefix: prefix, macFolders: macFolders) { url in
                trashed.append(url.lastPathComponent)
                try fm.removeItem(at: url)
            }
            #expect(trashed == ["settings.xml"], "the Mac's older copy, not its whole folder")
            #expect(BottleFolders.links(prefix: prefix).map(\.name) == ["Documents", "Videos"])
            #expect(try String(contentsOf: mac.appending(path: "Documents/Rockstar Games/settings.xml"), encoding: .utf8) == "new")
        }
    }

    /// A Mac folder of the same name holds other games' saves too: they stay, and of a file both
    /// have, the newer one does.
    @Test func linkingBackMergesFolders() throws {
        try withTempDir { root in
            let fm = FileManager.default
            let bottle = try root.appending(path: "bottle/My Games").makeDirectory()
            let mac = try root.appending(path: "mac/My Games").makeDirectory()
            try mac.appending(path: "Other Game/save.dat").write("other")
            try bottle.appending(path: "Game/old.dat").write("bottle")
            try mac.appending(path: "Game/old.dat").write("mac, newer")
            try bottle.appending(path: "Game/new.dat").write("bottle, newer")
            try mac.appending(path: "Game/new.dat").write("mac")
            let past = Date(timeIntervalSince1970: 1_000_000)
            try fm.setAttributes([.modificationDate: past], ofItemAtPath: bottle.appending(path: "Game/old.dat").path)
            try fm.setAttributes([.modificationDate: past], ofItemAtPath: mac.appending(path: "Game/new.dat").path)

            var trashed: [String] = []
            try BottleFolders.merge(bottle, into: mac) { url in
                trashed.append((url.path.contains("/bottle/") ? "bottle/" : "mac/") + url.lastPathComponent)
                try fm.removeItem(at: url)
            }
            #expect(Set(trashed) == ["bottle/old.dat", "mac/new.dat"])
            #expect(try String(contentsOf: mac.appending(path: "Other Game/save.dat"), encoding: .utf8) == "other")
            #expect(try String(contentsOf: mac.appending(path: "Game/old.dat"), encoding: .utf8) == "mac, newer")
            #expect(try String(contentsOf: mac.appending(path: "Game/new.dat"), encoding: .utf8) == "bottle, newer")
        }
    }

    @Test func readsWhenTheBottleRanFromItsLaunchLogs() throws {
        try withTempDir { root in
            let logs = root.appending(path: "logs")
            let start = Date(timeIntervalSince1970: 2_000_000)
            for (name, date) in [("launch-1.log", start), ("rockstar.log", start)] {
                try logs.appending(path: name).write("log")
                try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date.addingTimeInterval(600)],
                                                      ofItemAtPath: logs.appending(path: name).path)
            }
            #expect(BottleFolders.sessions(logFolders: [logs, root.appending(path: "missing")]) == [start...start.addingTimeInterval(600)])
        }
    }

    @Test func newStandardBottlesRecordTheLinksTheyCut() throws {
        let bottle = Bottle(name: "Steam", engineID: "wine", createdAt: Date(timeIntervalSince1970: 1_000_000), folders: .inside(macFolders: ["drive_c/users/crossover/Documents": "/Users/me/Documents"]))
        let decoded = try JSONDecoder.bottles.decode(Bottle.self, from: JSONEncoder.bottles.encode(bottle))
        #expect(decoded == bottle)
        // bottle.json from before has no folders.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder.bottles.encode(bottle)) as! [String: Any]
        old["folders"] = nil
        #expect(try JSONDecoder.bottles.decode(Bottle.self, from: JSONSerialization.data(withJSONObject: old)).folders == nil)
    }
}
