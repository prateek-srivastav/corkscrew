import Foundation

/// Finds what to run in an unpacked download (its setup, or the game itself when there's no
/// setup), and afterwards what the setup installed.
public enum SetupFinder {
    /// A program in the download.
    public struct Candidate: Sendable, Equatable, Identifiable, Hashable {
        public var url: URL
        /// Installs the game (`setup.exe`, an `.msi`, autorun's program); otherwise it's the game itself.
        public var isSetup: Bool
        public var id: URL { url }
    }

    /// Where a download is unpacked in the bottle: `C:\ProgramData\Corkscrew\Setup\<id>`, on the
    /// bottle's own drive so isolated bottles can run it.
    public static func setupFolder(prefix: URL, id: UUID) -> URL {
        setupRoot(prefix: prefix).appending(path: id.uuidString.prefix(8).lowercased(), directoryHint: .isDirectory)
    }

    static func setupRoot(prefix: URL) -> URL {
        prefix.appending(path: "drive_c/ProgramData/Corkscrew/Setup", directoryHint: .isDirectory)
    }

    /// Removes setup files an install left behind (the app quit during it).
    public static func removeLeftovers(prefix: URL) {
        try? FileManager.default.removeItem(at: setupRoot(prefix: prefix))
    }

    /// Disc images in the download, by name.
    public static func discImages(in folder: URL) -> [URL] {
        files(in: folder).filter(Archive.isDiscImage).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The download's programs, most likely first: its setup (named by `autorun.inf`, or called
    /// setup or install), then the programs that look like the game. Runtime installers (DirectX,
    /// Visual C++, .NET) and uninstallers are left out: a setup runs those itself.
    public static func candidates(in folders: [URL]) -> [Candidate] {
        var ranked: [(candidate: Candidate, rank: [Int])] = []
        for folder in folders {
            let autorun = autorunProgram(in: folder)
            for file in files(in: folder) where ["exe", "msi"].contains(file.pathExtension.lowercased()) {
                let relative = relativeComponents(of: file, in: folder)
                guard !isRuntimeInstaller(relative) else { continue }
                let name = file.deletingPathExtension().lastPathComponent.lowercased()
                let isAutorun = autorun == file
                let setupName = ["setup", "install", "installer"].contains(name)
                let isSetup = isAutorun || setupName || file.pathExtension.lowercased() == "msi"
                    || name.contains("setup") || name.contains("install")
                // Setups first: autorun's, then the plain names, then the rest; shallow ones before deep ones.
                let rank = isSetup ? [0, isAutorun ? 0 : setupName ? 1 : 2, relative.count] : [1] + programRank(file, relative: relative)
                ranked.append((Candidate(url: file, isSetup: isSetup), rank))
            }
        }
        return ranked.sorted { $0.rank.lexicographicallyPrecedes($1.rank) }.map(\.candidate)
    }

    /// The bottle's programs and shortcuts (relative paths, lowercased) before a setup runs, with
    /// when each last changed, to tell afterwards what it added or wrote again (a game installed a
    /// second time). Windows' own folders and the setup files aren't listed.
    public static func snapshot(prefix: URL) -> [String: Date] {
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        var found: [String: Date] = [:]
        for file in programsAndShortcuts(in: driveC) {
            found[relativeComponents(of: file, in: driveC).joined(separator: "/").lowercased()] = changed(file)
        }
        return found
    }

    /// What a setup installed, most likely first: the programs of new desktop and Start menu
    /// shortcuts, then the new programs that look most like the game.
    public static func installedPrograms(prefix: URL, before: [String: Date]) -> [URL] {
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        let added = programsAndShortcuts(in: driveC).filter { file in
            guard let previous = before[relativeComponents(of: file, in: driveC).joined(separator: "/").lowercased()] else { return true }
            return changed(file).map { $0 > previous } ?? false
        }
        // Desktop shortcuts before Start menu ones; a shortcut to the uninstaller doesn't count.
        let shortcuts = added.filter { $0.pathExtension.lowercased() == "lnk" }
            .sorted { ($0.path.lowercased().contains("/desktop/") ? 0 : 1, $0.path) < ($1.path.lowercased().contains("/desktop/") ? 0 : 1, $1.path) }
        var found: [URL] = []
        for shortcut in shortcuts {
            guard let target = ShellLink.target(contentsOf: shortcut).flatMap({ ShellLink.macPath(of: $0, prefix: prefix) }),
                  target.pathExtension.lowercased() == "exe", FileManager.default.fileExists(atPath: target.path),
                  !isHelper(relativeComponents(of: target, in: driveC))
            else { continue }
            found.append(target)
        }
        let programs = added.filter { $0.pathExtension.lowercased() == "exe" }
            .map { (file: $0, relative: relativeComponents(of: $0, in: driveC)) }
            .filter { !isRuntimeInstaller($0.relative) }
            .sorted { programRank($0.file, relative: $0.relative).lexicographicallyPrecedes(programRank($1.file, relative: $1.relative)) }
            .map(\.file)
        var seen = Set<String>()
        return (found + programs).filter { seen.insert($0.standardizedFileURL.path.lowercased()).inserted }
    }

    private static func programsAndShortcuts(in driveC: URL) -> [URL] {
        files(in: driveC, skipping: isSkipped).filter { ["exe", "lnk"].contains($0.pathExtension.lowercased()) }
    }

    /// When the file was last written or replaced. That's the status change time: a copy keeps
    /// the source's modification date, as Windows' CopyFile does.
    private static func changed(_ file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.attributeModificationDateKey]))?.attributeModificationDate
    }

    /// The other programs in a game's folder and the folders right below it, to start the game
    /// another way (some must start through their launcher): launchers first, then as
    /// `programRank` orders them. Uninstallers, runtime installers and `executable` itself are left
    /// out, and helpers (crash reporters, anti-cheat services) too unless `helpers` is set.
    public static func otherPrograms(near executable: URL, helpers: Bool = true) -> [URL] {
        let root = GameDetector.gameRoot(for: executable)
        let current = executable.standardizedFileURL.path.lowercased()
        // Deeper folders hold the game's data (thousands of files), not programs that start it.
        let shallow = files(in: root) { $0.split(separator: "/").count > 1 }
        var ranked: [(url: URL, rank: [Int])] = []
        for file in shallow where file.pathExtension.lowercased() == "exe" && file.standardizedFileURL.path.lowercased() != current {
            let relative = relativeComponents(of: file, in: root)
            guard !isRuntimeInstaller(relative), helpers || !isHelper(relative) else { continue }
            let isLauncher = file.deletingPathExtension().lastPathComponent.lowercased().contains("launcher")
            let rank = programRank(file, relative: relative)
            ranked.append((file, [rank[0], isLauncher ? 0 : 1] + rank.dropFirst()))
        }
        return ranked.sorted { $0.rank.lexicographicallyPrecedes($1.rank) }.map(\.url)
    }

    /// Ranks a program as the game: names like a helper last, then shallow before deep, big before small.
    static func programRank(_ file: URL, relative: [String]) -> [Int] {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return [isHelper(relative) ? 1 : 0, relative.count, -size]
    }

    /// Folders of runtime installers that setups run themselves.
    static let runtimeFolders: Set<String> = [
        "_commonredist", "commonredist", "redist", "_redist", "redistributables", "redistributable", "directx", "dotnet",
        "vcredist", "prerequisites", "_prerequisites", "physx", "openal", "__installer", "support", "_support",
    ]
    static let runtimePrefixes = [
        "vcredist", "vc_redist", "vc20", "dxsetup", "dxwebsetup", "dotnet", "ndp4", "ndp", "netfx", "oalinst", "physx",
        "ue4prereq", "ueprereq", "uerequisites", "xnafx", "unins", "uninst",
    ]

    static func isRuntimeInstaller(_ relative: [String]) -> Bool {
        let lowered = relative.map { $0.lowercased() }
        guard let name = lowered.last else { return false }
        return lowered.dropLast().contains(where: runtimeFolders.contains) || runtimePrefixes.contains(where: name.hasPrefix)
    }

    /// Programs a game ships next to itself that aren't the game.
    static let helperWords = [
        "unins", "uninst", "setup", "install", "redist", "crash", "report", "helper", "update", "patch", "config",
        "anticheat", "battleye", "be_service", "cefprocess", "subprocess", "webhelper", "dxsetup", "vcredist",
        "vc_redist", "dotnet", "touchup", "cleanup", "dxwebsetup", "quicksfv", "server", "editor", "benchmark", "register",
    ]
    static let helperFolders: Set<String> = ["engine", "thirdparty", "tools", "_commonredist", "redist", "support", "__installer"]

    static func isHelper(_ relative: [String]) -> Bool {
        let lowered = relative.map { $0.lowercased() }
        guard let name = lowered.last.map({ ($0 as NSString).deletingPathExtension }) else { return false }
        return helperWords.contains(where: name.contains) || lowered.dropLast().contains(where: helperFolders.contains)
    }

    /// `drive_c` folders a setup's own result never is in: Windows, the setup files, temporary files.
    static func isSkipped(_ relative: String) -> Bool {
        relative == "windows" || relative == "programdata/corkscrew" || relative.hasSuffix("/appdata/local/temp")
    }

    /// The program `autorun.inf` at the folder's top starts (`open=setup.exe`), if it's there.
    static func autorunProgram(in folder: URL) -> URL? {
        let fm = FileManager.default
        guard let name = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).first(where: { $0.lowercased() == "autorun.inf" }),
              let text = (try? String(contentsOf: folder.appending(path: name), encoding: .utf8))
                ?? (try? String(contentsOf: folder.appending(path: name), encoding: .windowsCP1252))
        else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, ["open", "shellexecute"].contains(parts[0].trimmingCharacters(in: .whitespaces).lowercased()) else { continue }
            // `open=setup.exe /autorun`: the program is the first word.
            let program = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            let path = program.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "\"/"))
            let wanted = path.split(separator: "/").map { $0.lowercased() }
            // The inf's case needn't match the file's; look it up as Windows would.
            return files(in: folder).first { relativeComponents(of: $0, in: folder).map { $0.lowercased() } == wanted }
        }
        return nil
    }

    /// Regular files below `folder`, without hidden ones or the folders `skipping` picks (by
    /// lowercased relative path); links aren't followed.
    static func files(in folder: URL, skipping: (String) -> Bool = { _ in false }) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if skipping(relativeComponents(of: url, in: folder).joined(separator: "/").lowercased()) { enumerator.skipDescendants() }
            } else if values?.isRegularFile == true {
                found.append(url)
            }
        }
        return found
    }

    /// The file's path below `folder`, by component.
    public static func relativeComponents(of file: URL, in folder: URL) -> [String] {
        // Enumerated files start with the folder's own path; resolving links is only the fallback (it's slow).
        let root = folder.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        if path.hasPrefix(root + "/") { return path.dropFirst(root.count + 1).split(separator: "/").map(String.init) }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let components = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard components.starts(with: base) else { return components }
        return Array(components.dropFirst(base.count))
    }
}
