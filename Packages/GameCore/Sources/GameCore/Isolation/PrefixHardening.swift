import Foundation

/// Cuts a Wine prefix's links to the Mac file system, like winetricks' `sandbox` verb.
///
/// Defense in depth only: the macOS sandbox is the real boundary. Run before every isolated
/// launch, because Wine can recreate these links when it updates a prefix.
public enum PrefixHardening {
    /// Folders Wine links to the Mac user's home folder.
    static let shellFolders: Set<String> = [
        "Desktop", "Documents", "Downloads", "Music", "Pictures", "Videos", "Templates",
        "My Documents", "My Music", "My Pictures", "My Videos",
    ]

    /// Returns a description of each change made; empty when the prefix was already hardened.
    @discardableResult
    public static func apply(prefix: URL) throws -> [String] {
        let fm = FileManager.default
        var changes: [String] = []
        let prefixPath = SandboxProfile.canonicalPath(prefix)

        // Drive letters that point outside the prefix (Z: → /, D: → /Volumes/…).
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        for entry in (try? fm.contentsOfDirectory(atPath: dosdevices.path)) ?? [] {
            let link = dosdevices.appending(path: entry)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
            let target = SandboxProfile.canonicalPath(URL(fileURLWithPath: destination, relativeTo: dosdevices))
            guard target != prefixPath, !target.hasPrefix(prefixPath + "/") else { continue }
            try fm.removeItem(at: link)
            changes.append("Removed drive \(entry) → \(destination)")
        }

        // Desktop, Documents, … that Wine linked to the Mac user's folders.
        changes += try unlinkShellFolders(prefix: prefix).map { "Unlinked \($0.path) from \($0.macFolder.path)" }
        return changes
    }

    /// Replaces the folders Wine linked to the Mac user's (Desktop, Documents, …,
    /// `BottleFolders.links`) with empty folders of their own, and returns the links it cut.
    static func unlinkShellFolders(prefix: URL) throws -> [BottleFolders.Link] {
        let fm = FileManager.default
        let links = BottleFolders.links(prefix: prefix)
        for link in links {
            let folder = prefix.appending(path: link.path)
            try fm.removeItem(at: folder)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        return links
    }
}
