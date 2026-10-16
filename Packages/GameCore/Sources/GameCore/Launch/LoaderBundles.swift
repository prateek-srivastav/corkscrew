import Foundation

/// The app bundles our Wine runtime starts programs from (`<user temp>/winetemp-…/<program>.app`,
/// see scripts/build-runtime.sh), so macOS Game Mode knows them as games. LaunchServices records
/// each one as an installed game when it starts, so they're unregistered once nothing runs. The
/// files stay: deleting them could pull one from under a program that is starting, and the next
/// start registers it again.
public enum LoaderBundles {
    /// The bundles' `CFBundleIdentifier`; bundles from other Wine builds are left alone.
    static let identifier = "io.github.prateek-srivastav.Corkscrew.wineloader"
    static let lsregister = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister")

    /// Where Wine makes them: the per-user temporary folder, whatever `TMPDIR` says.
    public static var temporaryDirectory: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        // The length includes the terminating NUL.
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 1, length <= buffer.count else { return nil }
        let path = String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Our bundles in `temporary`'s `winetemp-*` folders.
    static func find(in temporary: URL) -> [URL] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { $0.lastPathComponent.hasPrefix("winetemp-") }.flatMap { folder in
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { bundle in
                guard bundle.pathExtension == "app",
                      let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { return false }
                return plist["CFBundleIdentifier"] as? String == identifier
            }
        }.sorted { $0.path < $1.path }
    }

    /// Removes our bundles from LaunchServices, and returns them. Call it only when no bottle runs.
    @discardableResult
    public static func unregisterAll(in temporary: URL? = temporaryDirectory) -> [URL] {
        guard let temporary else { return [] }
        let bundles = find(in: temporary)
        guard !bundles.isEmpty else { return [] }
        let process = Process()
        process.executableURL = lsregister
        process.arguments = ["-u"] + bundles.map(\.path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        return bundles
    }

    /// Unregisters our bundles and deletes them, with their `winetemp-*` folder once it's empty.
    /// For uninstalling; call it only when no bottle runs.
    public static func removeAll(in temporary: URL? = temporaryDirectory) {
        let fm = FileManager.default
        for bundle in unregisterAll(in: temporary) {
            try? fm.removeItem(at: bundle)
            let folder = bundle.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
        }
    }
}
