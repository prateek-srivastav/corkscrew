import Foundation

/// Keeps a bottle's installed games out of Time Machine, so a backup of a 100 GB game doesn't run
/// during play. Saves stay in: `drive_c/users` (Documents, AppData) and Steam's own folder
/// (`userdata`, where Steam keeps saves and cloud copies) are never excluded. A game that keeps
/// its saves in its own install folder loses them from backups; the setting says so.
///
/// The exclusion is the sticky kind (`tmutil addexclusion`): it stays with the folder.
public enum BackupExclusion {
    /// The folders the bottle's games are installed in: each program's folder in Program Files (but
    /// Steam's own), Steam's `steamapps`, and `C:\Games` (where archives are installed).
    public static func gameFolders(prefix: URL) -> [URL] {
        let fm = FileManager.default
        let driveC = prefix.appending(path: "drive_c", directoryHint: .isDirectory)
        var folders: [URL] = []
        for programFiles in ["Program Files", "Program Files (x86)"] {
            let parent = driveC.appending(path: programFiles, directoryHint: .isDirectory)
            // By name: the URLs the folder listing gives may spell the path differently (/private/var).
            let names = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
            for child in names.map({ parent.appending(path: $0, directoryHint: .isDirectory) }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                if child.lastPathComponent.caseInsensitiveCompare("Steam") == .orderedSame {
                    let steamapps = child.appending(path: "steamapps", directoryHint: .isDirectory)
                    if fm.fileExists(atPath: steamapps.path) { folders.append(steamapps) }
                } else {
                    folders.append(child)
                }
            }
        }
        let games = driveC.appending(path: "Games", directoryHint: .isDirectory)
        if fm.fileExists(atPath: games.path) { folders.append(games) }
        return folders.sorted { $0.path < $1.path }
    }

    /// Excludes the bottle's game folders from backups, or includes them again; returns the folders
    /// it changed.
    @discardableResult
    public static func apply(_ excluded: Bool, prefix: URL) -> [URL] {
        gameFolders(prefix: prefix).filter { folder in
            var folder = folder
            guard (try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != excluded else { return false }
            var values = URLResourceValues()
            values.isExcludedFromBackup = excluded
            return (try? folder.setResourceValues(values)) != nil
        }
    }
}
