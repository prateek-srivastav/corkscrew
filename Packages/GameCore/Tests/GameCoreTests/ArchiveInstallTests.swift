import Foundation
import Testing
@testable import GameCore

struct ArchiveTests {
    private func touch(_ folder: URL, _ names: [String]) throws {
        for name in names { try folder.appending(path: name).write(name) }
    }

    @Test func findsEveryPartOfASplitArchiveFromAnyPart() throws {
        try withTempDir { root in
            try touch(root, ["Game.part1.rar", "Game.part2.rar", "Game.part3.rar", "Other.part1.rar"])
            let expected = ["Game.part1.rar", "Game.part2.rar", "Game.part3.rar"]
            #expect(try Archive.parts(of: root.appending(path: "Game.part2.rar")).map(\.lastPathComponent) == expected)

            try touch(root, ["Old.rar", "Old.r00", "Old.r01"])
            #expect(try Archive.parts(of: root.appending(path: "Old.r01")).map(\.lastPathComponent) == ["Old.rar", "Old.r00", "Old.r01"])

            try touch(root, ["Pack.7z.001", "Pack.7z.002"])
            #expect(try Archive.parts(of: root.appending(path: "Pack.7z.002")).map(\.lastPathComponent) == ["Pack.7z.001", "Pack.7z.002"])

            try touch(root, ["Single.zip"])
            #expect(try Archive.parts(of: root.appending(path: "Single.zip")).map(\.lastPathComponent) == ["Single.zip"])
        }
    }

    @Test func namesTheMissingPart() throws {
        try withTempDir { root in
            try touch(root, ["Game.part01.rar", "Game.part03.rar"])
            #expect(throws: Archive.Error.missingPart("Game.part02.rar")) { try Archive.parts(of: root.appending(path: "Game.part03.rar")) }
            try touch(root, ["Old.r00"])
            #expect(throws: Archive.Error.missingPart("Old.rar")) { try Archive.parts(of: root.appending(path: "Old.r00")) }
        }
    }

    @Test func knowsArchivesAndTheirParts() {
        for name in ["a.zip", "a.RAR", "a.part2.rar", "a.r07", "a.7z", "a.7z.003", "a.iso", "a.tar.gz"] {
            #expect(Archive.isArchive(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
        for name in ["a.exe", "a.msi", "a.bin", "a.txt"] {
            #expect(!Archive.isArchive(URL(fileURLWithPath: "/x/\(name)")), "\(name)")
        }
    }

    /// bsdtar (macOS's own) makes the archives.
    private func pack(_ format: String, _ archive: URL, from folder: URL, _ items: [String], absolute: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-c", absolute ? "-P" : "", "--format", format, "-f", archive.path, "-C", folder.path].filter { !$0.isEmpty } + items
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test(arguments: ["zip", "7zip", "pax"])
    func unpacksArchivesWithTheirFolders(format: String) throws {
        try withTempDir { root in
            let source = root.appending(path: "source")
            try source.appending(path: "Game Repack/setup.exe").write("MZ setup")
            try source.appending(path: "Game Repack/Données/fichier-é.bin").write(Data(repeating: 7, count: 300_000))
            let archive = root.appending(path: "game.archive")
            try pack(format, archive, from: source, ["Game Repack"])

            let target = root.appending(path: "target")
            var reports: [Double] = []
            try Archive.extract([archive], to: target) { reports.append($0) }

            #expect(try String(contentsOf: target.appending(path: "Game Repack/setup.exe"), encoding: .utf8) == "MZ setup")
            #expect(try Data(contentsOf: target.appending(path: "Game Repack/Données/fichier-é.bin")).count == 300_000)
            #expect(reports.last == 1)
        }
    }

    @Test func unpacksAFileCutInPieces() throws {
        try withTempDir { root in
            let source = root.appending(path: "source")
            try source.appending(path: "big.dat").write(Data((0..<200_000).map { UInt8($0 % 251) }))
            let whole = root.appending(path: "whole.7z")
            try pack("7zip", whole, from: source, ["big.dat"])
            let data = try Data(contentsOf: whole)
            let half = data.count / 2
            try data.prefix(half).write(to: root.appending(path: "pack.7z.001"))
            try data.dropFirst(half).write(to: root.appending(path: "pack.7z.002"))

            let parts = try Archive.parts(of: root.appending(path: "pack.7z.001"))
            try Archive.extract(parts, to: root.appending(path: "target"))
            #expect(try Data(contentsOf: root.appending(path: "target/big.dat")) == Data(contentsOf: source.appending(path: "big.dat")))
        }
    }

    /// A RAR5 volume set that stores `file` uncompressed, split evenly. No RAR tool is on macOS, so
    /// the volumes are written by hand: signature, main header, file header with its slice, end.
    private func rar5Volumes(of file: [UInt8], named name: String, count: Int) -> [Data] {
        func vint(_ value: Int) -> [UInt8] {
            var value = value, bytes: [UInt8] = []
            repeat {
                bytes.append(UInt8(value & 0x7F) | (value > 0x7F ? 0x80 : 0))
                value >>= 7
            } while value > 0
            return bytes
        }
        func block(type: Int, flags: Int, _ fields: [UInt8]) -> [UInt8] {
            let header = vint(fields.count + vint(type).count + vint(flags).count) + vint(type) + vint(flags) + fields
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in header {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            return withUnsafeBytes(of: (~crc).littleEndian, Array.init) + header
        }
        let slice = (file.count + count - 1) / count
        return (0..<count).map { number in
            let data = Array(file[(number * slice)..<min((number + 1) * slice, file.count)])
            let isLast = number == count - 1
            // Archive flags: a volume (0x1), with its number after the first one (0x2).
            let main = block(type: 1, flags: 0, number == 0 ? [0x1] : [0x3] + vint(number))
            // Header flags: a data area (0x2), continued from the previous volume (0x8) or in the next (0x10).
            // Fields: data size, file flags, unpacked size, Windows attributes (archive), stored, Windows, name.
            let flags = 0x2 | (number > 0 ? 0x8 : 0) | (isLast ? 0 : 0x10)
            let fileHeader = block(type: 2, flags: flags, vint(data.count) + vint(0) + vint(file.count) + vint(0x20)
                                   + vint(0) + vint(0) + vint(name.utf8.count) + Array(name.utf8))
            // End of archive flags: more volumes follow (0x1).
            let end = block(type: 5, flags: 0, vint(isLast ? 0 : 0x1))
            return Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00] + main + fileHeader + data + end)
        }
    }

    /// Without its last part, a RAR5 archive just ends: libarchive reports no error, and the file
    /// would be padded with zeros.
    @Test func refusesARAR5ArchiveWithoutItsLastPart() throws {
        try withTempDir { root in
            let file = (0..<300_000).map { UInt8($0 % 251) }
            for (index, volume) in rar5Volumes(of: file, named: "setup-1.bin", count: 3).enumerated() {
                try root.appending(path: "Program.part\(index + 1).rar").write(volume)
            }
            let parts = try Archive.parts(of: root.appending(path: "Program.part2.rar"))
            try Archive.extract(parts, to: root.appending(path: "whole"))
            #expect(try Data(contentsOf: root.appending(path: "whole/setup-1.bin")) == Data(file))

            try FileManager.default.removeItem(at: parts[2])
            #expect(throws: Archive.Error.unreadable("setup-1.bin stops early")) {
                try Archive.extract(Archive.parts(of: parts[0]), to: root.appending(path: "short"))
            }
        }
    }

    @Test func skipsEntriesThatLeaveTheFolder() throws {
        try withTempDir { root in
            let source = root.appending(path: "a/b/source")
            try source.appending(path: "ok.txt").write("ok")
            try root.appending(path: "a/b/escape.txt").write("outside")
            let archive = root.appending(path: "evil.tar")
            try pack("pax", archive, from: source, ["ok.txt", "../escape.txt"], absolute: true)

            let target = root.appending(path: "a/b/source/target")
            try Archive.extract([archive], to: target)
            #expect(FileManager.default.fileExists(atPath: target.appending(path: "ok.txt").path))
            #expect(!FileManager.default.fileExists(atPath: source.appending(path: "escape.txt").path))
        }
        #expect(Archive.safePath("../x") == nil)
        #expect(Archive.safePath("/etc/passwd") == nil)
        #expect(Archive.safePath(#"Game\Data\x.bin"#) == "Game/Data/x.bin")
        #expect(Archive.safePath("./a/./b") == "a/b")
    }

    @Test func unpacksADiscImage() throws {
        try withTempDir { root in
            let source = root.appending(path: "disc")
            try source.appending(path: "SETUP.EXE").write("MZ")
            try source.appending(path: "DATA/DATA1.CAB").write("cab")
            let image = root.appending(path: "Game.iso")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["makehybrid", "-iso", "-joliet", "-quiet", "-o", image.path, source.path]
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)

            try Archive.extract([image], to: root.appending(path: "target"))
            #expect(try String(contentsOf: root.appending(path: "target/SETUP.EXE"), encoding: .utf8) == "MZ")
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "target/DATA/DATA1.CAB").path))
        }
    }

    @Test func refusesSomethingThatIsNoArchive() throws {
        try withTempDir { root in
            let file = root.appending(path: "broken.rar")
            try file.write("this is not a rar file at all")
            #expect(throws: Archive.Error.self) { try Archive.extract([file], to: root.appending(path: "target")) }
        }
    }
}

struct SetupFinderTests {
    @Test func putsTheSetupFirstAndLeavesRuntimeInstallersOut() throws {
        try withTempDir { root in
            for name in ["Game/setup.exe", "Game/_Redist/vcredist_x64.exe", "Game/DirectX/DXSETUP.exe", "Game/Tools/patcher.exe",
                         "Game/unins000.exe", "Game/setup-2.bin"] {
                try root.appending(path: name).write("MZ")
            }
            let candidates = SetupFinder.candidates(in: [root])
            #expect(candidates.map { $0.url.lastPathComponent } == ["setup.exe", "patcher.exe"])
            #expect(candidates.map(\.isSetup) == [true, false])
        }
    }

    @Test func followsAutorun() throws {
        try withTempDir { root in
            try root.appending(path: "Install.exe").write("MZ")
            try root.appending(path: "Bin/Launch.exe").write("MZ")
            try root.appending(path: "AUTORUN.INF").write("[autorun]\r\nopen=bin\\launch.exe /auto\r\nicon=game.ico\r\n")
            let candidates = SetupFinder.candidates(in: [root])
            #expect(candidates.first?.url.lastPathComponent == "Launch.exe")
            #expect(candidates.first?.isSetup == true)
        }
    }

    @Test func aGameWithoutSetupOffersItsProgram() throws {
        try withTempDir { root in
            try root.appending(path: "Game/Game.exe").write(Data(repeating: 1, count: 5000))
            try root.appending(path: "Game/UnityCrashHandler64.exe").write(Data(repeating: 1, count: 9000))
            let candidates = SetupFinder.candidates(in: [root])
            #expect(candidates.map { $0.url.lastPathComponent } == ["Game.exe", "UnityCrashHandler64.exe"])
            #expect(candidates.allSatisfy { !$0.isSetup })
        }
    }

    @Test func findsWhatASetupInstalled() throws {
        try withTempDir { root in
            let prefix = root.appending(path: "prefix")
            let driveC = prefix.appending(path: "drive_c")
            try prefix.appending(path: "dosdevices").makeDirectory()
            try FileManager.default.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/c:").path, withDestinationPath: "../drive_c")
            try driveC.appending(path: "Program Files/Old/old.exe").write("MZ")
            try driveC.appending(path: "windows/system32/new.exe").write("MZ")
            let before = SetupFinder.snapshot(prefix: prefix)

            try driveC.appending(path: "Games/Space Game/unins000.exe").write("MZ")
            try driveC.appending(path: "Games/Space Game/Engine/Binaries/CrashReportClient.exe").write(Data(repeating: 1, count: 9000))
            try driveC.appending(path: "Games/Space Game/Bin/Space.exe").write("MZ")
            try driveC.appending(path: "Games/Space Game/Launcher.exe").write("MZ")
            try driveC.appending(path: "ProgramData/Corkscrew/Setup/1234/setup.exe").write("MZ")
            // The setup's desktop shortcut points at the real game, deeper than the launcher.
            try driveC.appending(path: "users/crossover/Desktop/Space Game.lnk").write(ShellLinkTests.link(to: #"C:\Games\Space Game\Bin\Space.exe"#))

            let installed = SetupFinder.installedPrograms(prefix: prefix, before: before)
            #expect(installed.map(\.lastPathComponent) == ["Space.exe", "Launcher.exe", "CrashReportClient.exe"])
        }
    }

    @Test func findsAGameInstalledAgain() throws {
        try withTempDir { root in
            let prefix = root.appending(path: "prefix")
            let driveC = prefix.appending(path: "drive_c")
            try driveC.appending(path: "Games/Space Game/Space.exe").write("MZ")
            try driveC.appending(path: "Games/Other/Other.exe").write("MZ")
            let before = SetupFinder.snapshot(prefix: prefix)

            // The setup copies the same game over the old one; a copy keeps the old modification date.
            let game = driveC.appending(path: "Games/Space Game/Space.exe")
            try game.write("MZ")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: game.path)
            #expect(SetupFinder.installedPrograms(prefix: prefix, before: before).map(\.lastPathComponent) == ["Space.exe"])
        }
    }

    @Test func offersTheOtherProgramsInAGamesFolder() throws {
        try withTempDir { root in
            let game = root.appending(path: "FIFA 23")
            for name in ["FIFA23.exe", "Launcher.exe", "EAAntiCheat.GameServiceLauncher.exe", "FakeEAACLauncher/EAAntiCheat.GameServiceLauncher.exe",
                         "Uninstall/unins000.exe", "Data/Win32/tool.exe", "Data/readme.txt"] {
                try game.appending(path: name).write("MZ")
            }
            let executable = game.appending(path: "FIFA23.exe")
            let others = SetupFinder.otherPrograms(near: executable)
            #expect(others.map { SetupFinder.relativeComponents(of: $0, in: game).joined(separator: "/") }
                == ["Launcher.exe", "EAAntiCheat.GameServiceLauncher.exe", "FakeEAACLauncher/EAAntiCheat.GameServiceLauncher.exe"])
            #expect(SetupFinder.otherPrograms(near: executable, helpers: false).map(\.lastPathComponent) == ["Launcher.exe"])
            #expect(SetupFinder.otherPrograms(near: game.appending(path: "Launcher.exe"), helpers: false).map(\.lastPathComponent) == ["FIFA23.exe"])
        }
    }

    @Test func setupFoldersLiveOnTheBottlesDrive() {
        let prefix = URL(fileURLWithPath: "/b/prefix")
        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        #expect(SetupFinder.setupFolder(prefix: prefix, id: id).path == "/b/prefix/drive_c/ProgramData/Corkscrew/Setup/abcdef12")
    }
}

struct ShellLinkTests {
    /// A shortcut with only LinkInfo's local base path, as Windows and Wine write for local files.
    static func link(to path: String, unicode: Bool = false) -> Data {
        var bytes = Bytes()
        bytes.zeros(ShellLink.headerSize)
        bytes.put32(UInt32(ShellLink.headerSize), at: 0)
        bytes.put32(0x2, at: 0x14)                               // HasLinkInfo
        let headerSize = unicode ? 0x24 : 0x1C
        let ansi = Array(path.utf8) + [0]
        let wide: [UInt8] = path.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + [0, 0]
        var info = Bytes()
        info.zeros(headerSize)
        info.put32(UInt32(headerSize), at: 4)
        info.put32(0x1, at: 8)                                   // VolumeIDAndLocalBasePath
        info.put32(UInt32(headerSize), at: 16)                   // LocalBasePathOffset
        info.append(ansi)
        info.put32(UInt32(info.count), at: 24)                   // CommonPathSuffixOffset: an empty string
        info.append([0])
        if unicode {
            info.put32(UInt32(info.count), at: 28)
            info.append(wide)
            info.put32(UInt32(info.count), at: 32)
            info.append([0, 0])
        }
        info.put32(UInt32(info.count), at: 0)
        bytes.append(info.bytes)
        return Data(bytes.bytes)
    }

    @Test func readsTheTargetsPath() {
        #expect(ShellLink.target(of: Self.link(to: #"C:\Games\Space\Space.exe"#)) == #"C:\Games\Space\Space.exe"#)
        #expect(ShellLink.target(of: Self.link(to: #"C:\Spiele\Größe\Spiel.exe"#, unicode: true)) == #"C:\Spiele\Größe\Spiel.exe"#)
        #expect(ShellLink.target(of: Data("not a shortcut".utf8)) == nil)
    }

    @Test func mapsWindowsPathsThroughTheDriveLetters() throws {
        try withTempDir { root in
            let prefix = root.appending(path: "prefix")
            try prefix.appending(path: "drive_c").makeDirectory()
            try prefix.appending(path: "dosdevices").makeDirectory()
            try FileManager.default.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/c:").path, withDestinationPath: "../drive_c")
            let mac = ShellLink.macPath(of: #"C:\Games\Space.exe"#, prefix: prefix)
            #expect(mac?.path == prefix.appending(path: "drive_c/Games/Space.exe").resolvingSymlinksInPath().path)
            #expect(ShellLink.macPath(of: "Space.exe", prefix: prefix) == nil)
        }
    }
}

struct DiscImageTests {
    @Test func picksTheFirstFreeDriveLetter() throws {
        try withTempDir { prefix in
            let dosdevices = try prefix.appending(path: "dosdevices").makeDirectory()
            for entry in ["c:", "d:", "d::", "z:"] {
                try FileManager.default.createSymbolicLink(atPath: dosdevices.appending(path: entry).path, withDestinationPath: "/tmp")
            }
            #expect(DiscImage.freeDriveLetter(prefix: prefix) == "e:")
        }
    }

    @Test func mountsADiscOnADriveAndEjectsIt() async throws {
        try await withTempDir { root in
            let source = root.appending(path: "disc")
            try source.appending(path: "SETUP.EXE").write("MZ")
            let image = root.appending(path: "Game.iso")
            let make = Process()
            make.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            make.arguments = ["makehybrid", "-iso", "-joliet", "-quiet", "-o", image.path, source.path]
            try make.run()
            await exited(make)
            let prefix = root.appending(path: "prefix")
            try prefix.appending(path: "dosdevices").makeDirectory()

            let mounted = try await offThePool { try DiscImage.attach([image], prefix: prefix) }
            #expect(mounted.map(\.drive) == ["d:"])
            #expect(FileManager.default.fileExists(atPath: prefix.appending(path: "dosdevices/d:/SETUP.EXE").path))

            try await offThePool { DiscImage.detach(mounted, prefix: prefix) }
            #expect(!FileManager.default.fileExists(atPath: prefix.appending(path: "dosdevices/d:").path))
            #expect(!FileManager.default.fileExists(atPath: DiscImage.folder(prefix: prefix).path))
        }
    }
}
