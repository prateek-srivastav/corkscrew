import Foundation

/// Reads the program a Windows shortcut (`.lnk`, [MS-SHLLINK]) starts. Setups put one on the
/// desktop or in the Start menu for the game, which is the surest way to find what they installed.
public enum ShellLink {
    static let headerSize = 0x4C

    /// The target's Windows path (`C:\Games\Game\Game.exe`), or nil when the shortcut doesn't
    /// name a local file.
    public static func target(contentsOf url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap(target(of:))
    }

    static func target(of data: Data) -> String? {
        let bytes = [UInt8](data)
        guard u32(bytes, 0) == UInt32(headerSize), let flags = u32(bytes, 0x14) else { return nil }
        let isUnicode = flags & 0x80 != 0
        var offset = headerSize
        // HasLinkTargetIDList: skip the shell's item list.
        if flags & 0x1 != 0 {
            guard let size = u16(bytes, offset) else { return nil }
            offset += 2 + Int(size)
        }
        // HasLinkInfo: the local path, when the target is on a local drive.
        if flags & 0x2 != 0 {
            guard let size = u32(bytes, offset).map(Int.init), offset + size <= bytes.count else { return nil }
            let info = Array(bytes[offset..<offset + size])
            offset += size
            // VolumeIDAndLocalBasePath; the Unicode offsets follow when the header is 0x24 bytes or more.
            if let infoFlags = u32(info, 8), infoFlags & 0x1 != 0 {
                let field = { (at: Int) in Int(u32(info, at) ?? 0) }
                let hasUnicode = field(4) >= 0x24
                let base = hasUnicode && field(28) > 0 ? utf16String(info, field(28)) : ansiString(info, field(16))
                let suffix = hasUnicode && field(32) > 0 ? utf16String(info, field(32)) : ansiString(info, field(24))
                if let base, !base.isEmpty { return join(base, suffix ?? "") }
            }
        }
        // Otherwise the string data: NAME_STRING, then RELATIVE_PATH and WORKING_DIR.
        var strings: [UInt32: String] = [:]
        for flag in [UInt32(0x4), 0x8, 0x10] where flags & flag != 0 {
            guard let count = u16(bytes, offset).map(Int.init) else { return nil }
            let length = isUnicode ? count * 2 : count
            guard offset + 2 + length <= bytes.count else { return nil }
            let raw = Array(bytes[offset + 2..<offset + 2 + length])
            strings[flag] = isUnicode ? String(decoding: stride(from: 0, to: raw.count, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 },
                                               as: UTF16.self)
                : String(bytes: raw, encoding: .windowsCP1252)
            offset += 2 + length
        }
        // A relative path is relative to the shortcut; only an absolute one says where it points.
        if let relative = strings[0x8], relative.dropFirst().hasPrefix(":\\") { return relative }
        if let relative = strings[0x8], let folder = strings[0x10], folder.dropFirst().hasPrefix(":\\") {
            let name = relative.split(separator: "\\").last.map(String.init) ?? relative
            return join(folder, name)
        }
        return nil
    }

    /// The Mac file a Windows path names in the bottle, through its drive letters (`dosdevices`).
    public static func macPath(of windowsPath: String, prefix: URL) -> URL? {
        let parts = windowsPath.split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
        guard let drive = parts.first?.lowercased(), drive.count == 2, drive.hasSuffix(":") else { return nil }
        let root = prefix.appending(path: "dosdevices/\(drive)", directoryHint: .isDirectory).resolvingSymlinksInPath()
        return parts.dropFirst().reduce(root) { $0.appending(path: $1) }
    }

    private static func join(_ base: String, _ suffix: String) -> String {
        guard !suffix.isEmpty else { return base }
        return base.hasSuffix("\\") ? base + suffix : base + "\\" + suffix
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    private static func ansiString(_ bytes: [UInt8], _ offset: Int) -> String? {
        guard offset > 0, offset < bytes.count else { return nil }
        let end = bytes[offset...].firstIndex(of: 0) ?? bytes.count
        return String(bytes: bytes[offset..<end], encoding: .windowsCP1252)
    }

    private static func utf16String(_ bytes: [UInt8], _ offset: Int) -> String? {
        guard offset > 0, offset < bytes.count else { return nil }
        var units: [UInt16] = []
        var index = offset
        while let unit = u16(bytes, index), unit != 0 {
            units.append(unit)
            index += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
