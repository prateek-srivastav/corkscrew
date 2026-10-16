import Foundation

/// Disc images (`.iso`) put in a bottle's drive like a DVD: macOS mounts the image read-only inside
/// the bottle's prefix (isolated bottles can't see `/Volumes`), and a drive letter (D:, E:, …)
/// points at it.
public enum DiscImage {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case attachFailed(image: String, message: String)
        case noFreeDriveLetter

        public var description: String {
            switch self {
            case .attachFailed(let image, let message): "macOS couldn't open the disc image \(image) (\(message))"
            case .noFreeDriveLetter: "the bottle has no free drive letter for the disc"
            }
        }
    }

    /// A disc in the bottle's drive.
    public struct Mounted: Sendable, Equatable {
        public var image: URL
        public var mountPoint: URL
        /// The drive letter Windows programs see it as, like `d:`.
        public var drive: String

        /// `D:\`
        public var windowsRoot: String { drive.uppercased() + "\\" }
    }

    static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    /// `<prefix>/corkscrew-discs`: inside the prefix, which isolated bottles can read.
    public static func folder(prefix: URL) -> URL {
        prefix.appending(path: "corkscrew-discs", directoryHint: .isDirectory)
    }

    /// Mounts each image on the next free drive letter, from D:. On an error the ones already
    /// mounted are ejected again.
    public static func attach(_ images: [URL], prefix: URL) throws -> [Mounted] {
        var mounted: [Mounted] = []
        do {
            for image in images {
                guard let drive = freeDriveLetter(prefix: prefix) else { throw Error.noFreeDriveLetter }
                let mountPoint = folder(prefix: prefix).appending(path: String(drive.dropLast()), directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
                let result = run(["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path, image.path])
                guard result.status == 0 else {
                    try? FileManager.default.removeItem(at: mountPoint)
                    throw Error.attachFailed(image: image.lastPathComponent, message: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let link = prefix.appending(path: "dosdevices/\(drive)")
                try? FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: mountPoint)
                mounted.append(Mounted(image: image, mountPoint: mountPoint, drive: drive))
            }
        } catch {
            detach(mounted, prefix: prefix)
            throw error
        }
        return mounted
    }

    /// Ejects the discs and takes their drive letters away.
    public static func detach(_ mounted: [Mounted], prefix: URL) {
        for disc in mounted {
            let link = prefix.appending(path: "dosdevices/\(disc.drive)")
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
               URL(fileURLWithPath: destination).standardizedFileURL == disc.mountPoint.standardizedFileURL {
                try? FileManager.default.removeItem(at: link)
            }
            eject(disc.mountPoint)
        }
        removeFolderIfEmpty(prefix: prefix)
    }

    /// Ejects every disc left in the bottle, e.g. by an install the app didn't get to finish.
    public static func detachAll(prefix: URL) {
        let fm = FileManager.default
        let discs = folder(prefix: prefix)
        guard fm.fileExists(atPath: discs.path) else { return }
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        for entry in (try? fm.contentsOfDirectory(atPath: dosdevices.path)) ?? [] {
            let link = dosdevices.appending(path: entry)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  URL(fileURLWithPath: destination).standardizedFileURL.path.hasPrefix(discs.standardizedFileURL.path + "/")
            else { continue }
            try? fm.removeItem(at: link)
        }
        for mountPoint in (try? fm.contentsOfDirectory(at: discs, includingPropertiesForKeys: nil)) ?? [] { eject(mountPoint) }
        removeFolderIfEmpty(prefix: prefix)
    }

    /// The first of d: … y: the bottle doesn't use (Wine's own entries like `d::` are devices).
    static func freeDriveLetter(prefix: URL) -> String? {
        let dosdevices = prefix.appending(path: "dosdevices", directoryHint: .isDirectory)
        let used = Set(((try? FileManager.default.contentsOfDirectory(atPath: dosdevices.path)) ?? []).map { $0.lowercased() })
        return "defghijklmnopqrstuvwxy".map { "\($0):" }.first { !used.contains($0) }
    }

    private static func eject(_ mountPoint: URL) {
        if isMountPoint(mountPoint), run(["detach", mountPoint.path]).status != 0 {
            _ = run(["detach", "-force", mountPoint.path])
        }
        // rmdir removes only an empty folder: never the files of a disc that wouldn't eject.
        if !isMountPoint(mountPoint) { rmdir(mountPoint.path) }
    }

    private static func removeFolderIfEmpty(prefix: URL) {
        let discs = folder(prefix: prefix)
        if (try? FileManager.default.contentsOfDirectory(atPath: discs.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: discs)
        }
    }

    /// Whether a volume is mounted on `url` (it's on another device than its parent folder).
    static func isMountPoint(_ url: URL) -> Bool {
        var own = stat(), parent = stat()
        guard stat(url.path, &own) == 0, stat(url.deletingLastPathComponent().path, &parent) == 0 else { return false }
        return own.st_dev != parent.st_dev
    }

    private static func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = hdiutil
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "hdiutil didn't start") }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
