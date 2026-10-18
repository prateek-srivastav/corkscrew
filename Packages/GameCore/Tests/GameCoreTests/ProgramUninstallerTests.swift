import Foundation
import Testing
@testable import GameCore

struct ProgramUninstallerTests {
    static let wow64List = #"HKLM\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"#

    /// A bottle prefix with `C:` linked the way Wine links it, and the given `system.reg` text.
    private func prefix(in root: URL, systemReg: String = "", userReg: String = "") throws -> URL {
        let prefix = root.appending(path: "prefix", directoryHint: .isDirectory)
        try prefix.appending(path: "drive_c").makeDirectory()
        try prefix.appending(path: "dosdevices").makeDirectory()
        try FileManager.default.createSymbolicLink(atPath: prefix.appending(path: "dosdevices/c:").path, withDestinationPath: "../drive_c")
        try prefix.appending(path: "system.reg").write("WINE REGISTRY Version 2\n" + systemReg)
        try prefix.appending(path: "user.reg").write("WINE REGISTRY Version 2\n" + userReg)
        return prefix
    }

    private func program(_ path: String, in prefix: URL) throws -> URL {
        let file = prefix.appending(path: "drive_c/\(path)")
        try file.write("MZ")
        return file
    }

    @Test func readsTheKeysUnderAKey() {
        let text = #"""
        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{E00298AB}_is1] 1792348746
        #time=1dd5f2ff48b23b2
        "DisplayName"="Caf\x00e9 \"Deluxe\""
        "EstimatedSize"=dword:038cf9cd
        "InstallLocation"="C:\\Games\\Caf\x00e9\\"

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{E00298AB}_is1\\Nested] 1792348746
        "InstallLocation"="C:\\Elsewhere"

        [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Other] 1792348746
        """#
        let keys = WineRegistry.subkeys(of: #"Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"#, text: text)
        #expect(keys.keys.sorted() == ["Other", "{E00298AB}_is1"])
        #expect(keys["{E00298AB}_is1"] == ["displayname": "Café \"Deluxe\"", "installlocation": #"C:\Games\Café\"#])
    }

    @Test func findsTheFolderOfAnUninstallCommand() {
        #expect(ProgramUninstaller.uninstallerFolder(#""C:\Games\X\unins000.exe" /SILENT"#) == #"C:\Games\X"#)
        #expect(ProgramUninstaller.uninstallerFolder(#"C:\Program Files\Y\uninst.exe /S"#) == #"C:\Program Files\Y"#)
        #expect(ProgramUninstaller.uninstallerFolder("MsiExec.exe /X{43B0D101}") == nil)
    }

    /// An Inno Setup install: its folder goes, with its entries in both registry hives.
    @Test func deletesTheFolderTheUninstallListNames() throws {
        try withTempDir { root in
            let reg = #"""
            [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{E00298AB}_is1] 1792348746
            "InstallLocation"="C:\\Games\\EA Sports FC 26\\"
            "UninstallString"="\"C:\\Games\\EA Sports FC 26\\unins000.exe\""

            [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Unrelated] 1792348746
            "InstallLocation"="C:\\Games\\Other\\"
            """#
            let user = #"""
            [Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\FC26] 1792348746
            "Inno Setup: App Path"="C:\\Games\\EA Sports FC 26"
            """#
            let prefix = try prefix(in: root, systemReg: reg, userReg: user)
            let game = try program("Games/EA Sports FC 26/Bin/FC26.exe", in: prefix)

            let removal = try ProgramUninstaller.removal(of: game, prefix: prefix)
            #expect(ProgramUninstaller.components(of: removal.target, in: prefix.appending(path: "drive_c")) == ["games", "ea sports fc 26"])
            #expect(Set(removal.registryKeys) == [Self.wow64List + #"\{E00298AB}_is1"#,
                                                  #"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\FC26"#])
        }
    }

    /// Steam's own entry holds every Steam game; a game's entry names only its folder.
    @Test func picksTheDeepestEntryThatHoldsTheProgram() throws {
        try withTempDir { root in
            let reg = #"""
            [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Steam] 1792348746
            "UninstallString"="C:\\Program Files (x86)\\Steam\\uninstall.exe"

            [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Steam App 417860] 1792348746
            "InstallLocation"="C:\\Program Files (x86)\\Steam\\steamapps\\common\\Emily is Away"
            """#
            let prefix = try prefix(in: root, systemReg: reg)
            let game = try program("Program Files (x86)/Steam/steamapps/common/Emily is Away/Emily is Away.exe", in: prefix)
            let removal = try ProgramUninstaller.removal(of: game, prefix: prefix)
            #expect(removal.target.lastPathComponent == "Emily is Away")
            #expect(removal.registryKeys == [Self.wow64List + #"\Steam App 417860"#])

            let steam = try program("Program Files (x86)/Steam/steam.exe", in: prefix)
            #expect(try ProgramUninstaller.removal(of: steam, prefix: prefix).registryKeys == [Self.wow64List + #"\Steam"#])
        }
    }

    /// Without an entry (copied in by hand), the program's own folder goes; an entry naming a shared
    /// folder is ignored.
    @Test func otherwiseDeletesTheProgramsFolder() throws {
        try withTempDir { root in
            let reg = #"""
            [Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Careless] 1792348746
            "InstallLocation"="C:\\Games\\"
            """#
            let prefix = try prefix(in: root, systemReg: reg)
            let game = try program("Games/God of War/GoW.exe", in: prefix)
            #expect(try ProgramUninstaller.removal(of: game, prefix: prefix) == .init(target: game.deletingLastPathComponent(), registryKeys: []))
            let unreal = try program("Games/Wukong/b1/Binaries/Win64/b1-Win64-Shipping.exe", in: prefix)
            #expect(try ProgramUninstaller.removal(of: unreal, prefix: prefix).target.lastPathComponent == "Wukong")
        }
    }

    @Test func deletesOnlyTheProgramInASharedFolder() throws {
        try withTempDir { root in
            let prefix = try prefix(in: root)
            for path in ["users/crossover/Downloads/setup.exe", "Games/tool.exe", "Program Files/app.exe", "portable.exe"] {
                let file = try program(path, in: prefix)
                #expect(try ProgramUninstaller.removal(of: file, prefix: prefix).target == file, "\(path)")
            }
        }
    }

    @Test func refusesProgramsOutsideTheBottleAndWindowsOwn() throws {
        try withTempDir { root in
            let prefix = try prefix(in: root)
            let outside = root.appending(path: "Games/game.exe")
            try outside.write("MZ")
            #expect(throws: ProgramUninstaller.Error.outsideBottle) { try ProgramUninstaller.removal(of: outside, prefix: prefix) }
            let notepad = try program("windows/system32/notepad.exe", in: prefix)
            #expect(throws: ProgramUninstaller.Error.partOfWindows) { try ProgramUninstaller.removal(of: notepad, prefix: prefix) }
        }
    }

    @Test func removeDeletesOnlyTheTarget() async throws {
        try await withTempDir { root in
            let prefix = try prefix(in: root)
            let game = try program("Games/A/a.exe", in: prefix)
            let other = try program("Games/B/b.exe", in: prefix)
            let removal = try ProgramUninstaller.removal(of: game, prefix: prefix)
            #expect(removal.deletes(game) && removal.deletes(removal.target) && !removal.deletes(other))
            #expect(ProgramUninstaller.size(of: removal.target) > 0)
            try await ProgramUninstaller.remove(removal, in: nil, log: root.appending(path: "uninstall.log"))
            #expect(!FileManager.default.fileExists(atPath: game.deletingLastPathComponent().path))
            #expect(FileManager.default.fileExists(atPath: other.path))
        }
    }
}
