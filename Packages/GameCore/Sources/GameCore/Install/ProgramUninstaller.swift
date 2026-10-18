import Foundation

/// Uninstalls a program from its bottle: deletes its install folder for good and takes it off the
/// bottle's Windows uninstall list, without running the program's own uninstaller.
public enum ProgramUninstaller {
    /// What Uninstall takes out of the bottle.
    public struct Removal: Sendable, Equatable {
        /// The install folder, or the program alone when it sits in a shared folder (Downloads, `C:\Games`).
        public var target: URL
        /// The program's entries in the uninstall list, as `reg` names them (`HKLM\Software\…\Uninstall\<id>`).
        public var registryKeys: [String]

        /// Whether `file` goes with it: it's the target or inside it.
        public func deletes(_ file: URL) -> Bool {
            let target = SandboxProfile.canonicalPath(target).lowercased()
            let path = SandboxProfile.canonicalPath(file).lowercased()
            return path == target || path.hasPrefix(target + "/")
        }
    }

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case outsideBottle
        case partOfWindows
        case registry(key: String, outcome: String)

        public var description: String {
            switch self {
            case .outsideBottle: "the program isn't on its bottle's C: drive; remove it from the library and delete it in Finder"
            case .partOfWindows: "the program is part of Windows in its bottle"
            case .registry(let key, let outcome): "its folder is deleted, but \(key) stayed in the bottle's uninstall list (reg \(outcome))"
            }
        }
    }

    /// The uninstall lists in a bottle: the hive `reg` names, the file Wine saves it in, and the key.
    static let lists = [
        (hive: "HKLM", file: "system.reg", key: #"Software\Microsoft\Windows\CurrentVersion\Uninstall"#),
        (hive: "HKLM", file: "system.reg", key: #"Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"#),
        (hive: "HKCU", file: "user.reg", key: #"Software\Microsoft\Windows\CurrentVersion\Uninstall"#),
    ]

    /// Folders (under `drive_c`, lowercased, `*` for any name) other programs or the user share:
    /// Uninstall never deletes them, only something inside them.
    static let sharedFolders = [
        "", "games", "program files", "program files (x86)", "program files/common files", "program files (x86)/common files",
        "programdata", "users", "users/*", "users/*/*", "users/*/appdata/*", "users/*/appdata/local/programs",
        "users/*/documents/my games", "users/*/saved games",
    ]

    /// What to delete for `executable`: the folder its uninstall list entry names (the deepest one that
    /// holds it), else its own folder (`GameDetector.gameRoot`), else, in a shared folder, the program alone.
    public static func removal(of executable: URL, prefix: URL) throws -> Removal {
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        guard let relative = components(of: executable, in: driveC) else { throw Error.outsideBottle }
        guard relative.first != "windows" else { throw Error.partOfWindows }

        let entries = uninstallEntries(prefix: prefix).filter { entry in
            components(of: entry.folder, in: driveC).map { !isShared($0) && relative.starts(with: $0) } ?? false
        }
        if let deepest = entries.max(by: { $0.folder.pathComponents.count < $1.folder.pathComponents.count }) {
            let keys = entries.filter { $0.folder.pathComponents.count == deepest.folder.pathComponents.count }.map(\.key)
            return Removal(target: deepest.folder, registryKeys: keys)
        }
        let root = GameDetector.gameRoot(for: executable)
        if let folder = components(of: root, in: driveC), !isShared(folder) {
            return Removal(target: root, registryKeys: [])
        }
        return Removal(target: executable, registryKeys: [])
    }

    /// Bytes the target takes on disk.
    public static func size(of target: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        func size(_ url: URL) -> Int64 {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.isRegularFile == true ? Int64(values?.totalFileAllocatedSize ?? 0) : 0
        }
        guard let files = FileManager.default.enumerator(at: target, includingPropertiesForKeys: keys) else { return size(target) }
        return files.reduce(size(target)) { $0 + size($1 as! URL) }
    }

    /// Deletes the target for good, then takes its entries off the uninstall list with `wine reg`
    /// (the running wineserver keeps the registry, so its files can't be edited directly). Without a
    /// runtime (`context` nil) the entries stay.
    public static func remove(_ removal: Removal, in context: WineContext?, log: URL) async throws {
        if FileManager.default.fileExists(atPath: removal.target.path) {
            try FileManager.default.removeItem(at: removal.target)
        }
        guard let context else { return }
        for key in removal.registryKeys {
            let plan = try LaunchPlanner.plan(wineArguments: ["reg", "delete", key, "/f"], in: context)
            let result = try await ProcessRunner.run(plan, log: log, wineserver: context.engine.wineserver)
            guard result.status == 0, !result.crashed else { throw Error.registry(key: key, outcome: result.outcome) }
        }
    }

    /// Every uninstall list entry with the folder it names: `InstallLocation`, Inno Setup's app path,
    /// or the folder of its uninstaller (`"C:\Games\X\unins000.exe" /SILENT`).
    static func uninstallEntries(prefix: URL) -> [(key: String, folder: URL)] {
        var texts: [String: String] = [:]
        return lists.flatMap { list -> [(key: String, folder: URL)] in
            if texts[list.file] == nil {
                texts[list.file] = (try? String(contentsOf: prefix.appending(path: list.file), encoding: .utf8)) ?? ""
            }
            return WineRegistry.subkeys(of: list.key, text: texts[list.file]!).compactMap { name, values in
                let path = [values["installlocation"], values["inno setup: app path"], values["uninstallstring"].flatMap(uninstallerFolder)]
                    .compactMap { $0 }.first { !$0.isEmpty }
                guard let path, let folder = ShellLink.macPath(of: path, prefix: prefix) else { return nil }
                return ("\(list.hive)\\\(list.key)\\\(name)", folder)
            }
        }
    }

    /// `"C:\Games\X\unins000.exe" /SILENT` → `C:\Games\X`; nil for commands without a path (`MsiExec.exe /X{…}`).
    static func uninstallerFolder(_ command: String) -> String? {
        let program = command.hasPrefix("\"")
            ? command.dropFirst().prefix { $0 != "\"" }
            : command.range(of: ".exe", options: .caseInsensitive).map { command[..<$0.upperBound] } ?? command[...]
        guard let separator = program.lastIndex(of: "\\") else { return nil }
        return String(program[..<separator])
    }

    /// The path's components under `driveC`, lowercased; nil when it isn't inside it.
    static func components(of url: URL, in driveC: URL) -> [String]? {
        let path = SandboxProfile.canonicalPath(url).lowercased()
        let root = SandboxProfile.canonicalPath(driveC).lowercased()
        if path == root { return [] }
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
    }

    static func isShared(_ folder: [String]) -> Bool {
        folder.first == "windows" || sharedFolders.contains { pattern in
            let parts = pattern.split(separator: "/").map(String.init)
            return parts.count == folder.count && zip(parts, folder).allSatisfy { $0 == "*" || $0 == $1 }
        }
    }
}
