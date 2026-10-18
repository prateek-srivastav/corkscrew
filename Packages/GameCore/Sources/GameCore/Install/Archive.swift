import CArchive
import Darwin
import Foundation

/// Unpacks the archives games come in (zip, rar, 7z, tar, disc images), split ones too, with
/// macOS's own libarchive.
public enum Archive {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// A part of a split archive isn't next to the others.
        case missingPart(String)
        /// libarchive can't decrypt archives (zip's old scheme aside), so these can't be opened.
        case passwordProtected
        /// libarchive's own message: a damaged file, an unknown format, a last part that's missing.
        case unreadable(String)

        public var description: String {
            switch self {
            case .missingPart(let name): "a part of the archive is missing: \(name). Put all its parts in the same folder."
            case .passwordProtected: "the archive has a password, and Corkscrew can't open archives with a password yet"
            case .unreadable(let message): "the archive can't be read (\(message)). It may be damaged, or a part of it may be missing."
            }
        }
    }

    /// What libarchive reads, by file extension. `.iso` is here too: an ISO image unpacks like any archive.
    static let extensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "iso"]

    /// Whether `url` is an archive Corkscrew unpacks, or one part of a split one (`.part2.rar`,
    /// `.r00`, `.7z.001`).
    public static func isArchive(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return extensions.contains(ext) || isNumberedPart(ext) || isOldRARPart(ext)
    }

    /// A disc image: `.iso`.
    public static func isDiscImage(_ url: URL) -> Bool { url.pathExtension.lowercased() == "iso" }

    /// Every part of the archive `url` belongs to, in reading order; `url` may be any part.
    /// One-file archives are just themselves.
    public static func parts(of url: URL) throws -> [URL] {
        let folder = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []

        // game.part1.rar, game.part2.rar, … (also part01, part001)
        if ext == "rar", let match = name.firstMatch(of: /^(.+)\.part(\d+)\.rar$/.ignoresCase()) {
            let base = String(match.1).lowercased()
            let width = match.2.count
            let numbers = Dictionary(siblings.compactMap { sibling -> (Int, String)? in
                guard let part = sibling.firstMatch(of: /^(.+)\.part(\d+)\.rar$/.ignoresCase()),
                      part.1.lowercased() == base, let number = Int(part.2) else { return nil }
                return (number, sibling)
            }, uniquingKeysWith: { first, _ in first })
            return try contiguous(numbers, from: 1, in: folder) { number in
                "\(match.1).part\(padded(number, width)).rar"
            }
        }
        // game.rar, game.r00, game.r01, …
        let stem = url.deletingPathExtension().lastPathComponent
        if ext == "rar" || isOldRARPart(ext) {
            let numbers = Dictionary(siblings.compactMap { sibling -> (Int, String)? in
                let file = URL(fileURLWithPath: sibling)
                let partExt = file.pathExtension.lowercased()
                guard isOldRARPart(partExt), file.deletingPathExtension().lastPathComponent.lowercased() == stem.lowercased(),
                      let number = Int(partExt.dropFirst()) else { return nil }
                return (number, sibling)
            }, uniquingKeysWith: { first, _ in first })
            guard !numbers.isEmpty || isOldRARPart(ext) else { return [url] }
            guard let first = siblings.first(where: { $0.lowercased() == "\(stem.lowercased()).rar" }) else {
                throw Error.missingPart("\(stem).rar")
            }
            return [folder.appending(path: first)] + (try contiguous(numbers, from: 0, in: folder) { "\(stem).r\(padded($0, 2))" })
        }
        // game.7z.001, game.7z.002, … (the file cut in pieces: read one after the other)
        if isNumberedPart(ext) {
            let numbers = Dictionary(siblings.compactMap { sibling -> (Int, String)? in
                let file = URL(fileURLWithPath: sibling)
                guard isNumberedPart(file.pathExtension), file.deletingPathExtension().lastPathComponent.lowercased() == stem.lowercased(),
                      let number = Int(file.pathExtension) else { return nil }
                return (number, sibling)
            }, uniquingKeysWith: { first, _ in first })
            return try contiguous(numbers, from: 1, in: folder) { "\(stem).\(padded($0, 3))" }
        }
        return [url]
    }

    /// The parts numbered `start`, `start + 1`, … up to the highest one there.
    private static func contiguous(_ numbers: [Int: String], from start: Int, in folder: URL,
                                   name: (Int) -> String) throws -> [URL] {
        guard let last = numbers.keys.max() else { throw Error.missingPart(name(start)) }
        return try (start...max(start, last)).map { number in
            guard let file = numbers[number] else { throw Error.missingPart(name(number)) }
            return folder.appending(path: file)
        }
    }

    private static func padded(_ number: Int, _ width: Int) -> String {
        String(repeating: "0", count: max(0, width - String(number).count)) + String(number)
    }

    private static func isNumberedPart(_ ext: String) -> Bool { ext.count == 3 && ext.allSatisfy(\.isNumber) }
    private static func isOldRARPart(_ ext: String) -> Bool {
        ext.count == 3 && ext.lowercased().first == "r" && ext.dropFirst().allSatisfy(\.isNumber)
    }

    /// The archive's size on disk, all parts together.
    public static func size(of parts: [URL]) -> Int64 {
        parts.reduce(0) { total, part in
            total + Int64((try? part.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Unpacks the archive into `folder`, reporting how far it got (0…1, by bytes read). Entries
    /// that would land outside the folder (absolute paths, `..`, through links) are skipped.
    /// Stops with `CancellationError` when the task is cancelled; what's unpacked so far stays.
    public static func extract(_ parts: [URL], to folder: URL, progress: (Double) -> Void = { _ in }) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // File names convert between UTF-8 and the C library's encoding, which is ASCII in an app.
        let utf8 = newlocale(LC_CTYPE_MASK, "UTF-8", nil)
        let previous = uselocale(utf8)
        defer {
            uselocale(previous)
            if let utf8 { freelocale(utf8) }
        }

        guard let reader = archive_read_new(), let writer = archive_write_disk_new() else { throw Error.unreadable("out of memory") }
        defer {
            archive_read_free(reader)
            archive_write_free(writer)
        }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        archive_write_disk_set_options(writer, ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT)

        var names = parts.map { strdup($0.path) }
        defer { names.forEach { free($0) } }
        var list: [UnsafePointer<CChar>?] = names.map { UnsafePointer($0) } + [nil]
        guard archive_read_open_filenames(reader, &list, 1 << 16) == ARCHIVE_OK else { throw error(reader) }

        // The real path: libarchive refuses to write through links, also ones above the folder (/var → /private/var).
        let root = SandboxProfile.canonicalPath(folder)
        let total = max(Double(size(of: parts)), 1)
        while true {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else { throw error(reader) }
            if archive_entry_is_encrypted(entry) != 0 { throw Error.passwordProtected }
            guard let path = safePath(archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)) else { continue }
            archive_entry_set_pathname_utf8(entry, root + "/" + path)
            if let link = archive_entry_hardlink_utf8(entry) {
                guard let linkPath = safePath(link) else { continue }
                archive_entry_set_hardlink_utf8(entry, root + "/" + linkPath)
            }
            guard archive_write_header(writer, entry) >= ARCHIVE_WARN else { throw error(writer) }
            let size = archive_entry_size(entry)
            if size > 0 {
                var buffer: UnsafeRawPointer?
                var count = 0
                var offset: Int64 = 0
                var reached: Int64 = 0
                while true {
                    let read = archive_read_data_block(reader, &buffer, &count, &offset)
                    if read == ARCHIVE_EOF { break }
                    guard read >= ARCHIVE_WARN else { throw error(reader) }
                    guard archive_write_data_block(writer, buffer, count, offset) >= 0 else { throw error(writer) }
                    reached = max(reached, offset + Int64(count))
                    try Task.checkCancellation()
                    progress(min(Double(archive_filter_bytes(reader, -1)) / total, 1))
                }
                // A RAR5 archive without its last part ends mid-file with no error, and the disk writer
                // pads the file with zeros. Only RAR: a sparse tar file or an ISO folder legitimately
                // ends short of its size.
                let format = archive_format(reader) & ARCHIVE_FORMAT_BASE_MASK
                if reached < size, format == ARCHIVE_FORMAT_RAR || format == ARCHIVE_FORMAT_RAR_V5 {
                    throw Error.unreadable("\(path) stops early")
                }
            }
            guard archive_write_finish_entry(writer) >= ARCHIVE_WARN else { throw error(writer) }
        }
        progress(1)
    }

    /// The entry's path inside the folder, or nil when it would leave it. Backslashes are
    /// separators: zip files made on Windows sometimes use them.
    static func safePath(_ raw: UnsafePointer<CChar>?) -> String? {
        guard let raw else { return nil }
        let parts = String(cString: raw).replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        guard !String(cString: raw).hasPrefix("/"), !parts.contains(".."), !parts.isEmpty else { return nil }
        let path = parts.filter { $0 != "." }.joined(separator: "/")
        return path.isEmpty ? nil : path
    }

    private static func error(_ archive: OpaquePointer) -> Error {
        let message = archive_error_string(archive).map { String(cString: $0) } ?? "unknown error"
        let lowered = message.lowercased()
        if lowered.contains("encrypt") || lowered.contains("passphrase") || lowered.contains("password") { return .passwordProtected }
        return .unreadable(message)
    }
}
