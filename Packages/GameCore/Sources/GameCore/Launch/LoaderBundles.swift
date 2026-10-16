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
        subfolders(of: temporary).filter { $0.lastPathComponent.hasPrefix("winetemp-") }.flatMap(bundles(in:)).sorted { $0.path < $1.path }
    }

    /// Our bundles in a folder of them.
    static func bundles(in folder: URL) -> [URL] {
        subfolders(of: folder).filter { bundle in
            guard bundle.pathExtension == "app",
                  let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return false }
            return plist["CFBundleIdentifier"] as? String == identifier
        }
    }

    private static func subfolders(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// Removes our bundles from LaunchServices, and returns them: Wine's in `temporary`, and the
    /// app's for isolated bottles in `prebuilt` (`AppPaths.gameModeBundles`). Call it only when no
    /// bottle runs.
    @discardableResult
    public static func unregisterAll(in temporary: URL? = temporaryDirectory, prebuilt: URL? = nil) -> [URL] {
        let bundles = (temporary.map(find(in:)) ?? []) + (prebuilt.map { subfolders(of: $0).flatMap(bundles(in:)).sorted { $0.path < $1.path } } ?? [])
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

    // MARK: Isolated bottles

    /// An isolated bottle's sandbox only runs programs in the runtime and in folders the app names,
    /// so Wine can't make a game's bundle in the temporary folder. The app makes it here before the
    /// launch, read-only to the sandbox, and the runtime uses it (`CORKSCREW_LOADER_BUNDLE_DIR`).
    public static func prebuiltFolder(for engine: Engine, paths: AppPaths) -> URL {
        paths.gameModeBundles.appending(path: engine.id, directoryHint: .isDirectory)
    }

    /// The loader Wine re-runs itself as (`wineloader` in ntdll).
    static func loader(of engine: Engine) -> URL { engine.root.appending(path: "lib/wine/x86_64-unix/wine") }

    /// The name Wine gives a program's bundle, as `extract_exe_name` in ntdll's loader.c does: the
    /// file name without the 32 hex digits Wine puts before temporary copies. It keeps the extension
    /// (`GoW.exe.app`); only the bundle's display name drops it.
    static func bundleName(for executable: String) -> String? {
        var name = Substring(executable.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? "")
        let hex = name.prefix { $0.isHexDigit }
        if hex.count == 32, name.dropFirst(32).first == "." { name = name.dropFirst(33) }
        // Kept out of the Info.plist's XML, as the runtime does for its own bundles.
        guard !name.isEmpty, !name.contains(where: { "&<>\"'".contains($0) }) else { return nil }
        return String(name)
    }

    /// The bundle's display name: without the extension, as the runtime's bundles have it.
    static func displayName(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// Makes (or refreshes, after a runtime update) the game's bundle in `folder`: Info.plist with
    /// the games category, the loader hard-linked as its executable, and ntdll.so next to it.
    /// Returns the bundle, or nil when the name can't be one.
    @discardableResult
    public static func prepare(for executable: URL, engine: Engine, in folder: URL) throws -> URL? {
        guard let name = bundleName(for: executable.lastPathComponent) else { return nil }
        let fm = FileManager.default
        let loader = loader(of: engine)
        let bundle = folder.appending(path: "\(name).app", directoryHint: .isDirectory)
        let macOS = bundle.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        let linked = macOS.appending(path: name)
        if let existing = try? fm.attributesOfItem(atPath: linked.path)[.systemFileNumber] as? Int,
           let current = try? fm.attributesOfItem(atPath: loader.path)[.systemFileNumber] as? Int, existing == current {
            return bundle
        }
        try? fm.removeItem(at: bundle)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: macOS.appending(path: "ntdll.so"),
                                  withDestinationURL: loader.deletingLastPathComponent().appending(path: "ntdll.so"))
        let plist: [String: Any] = [
            "CFBundleAllowMixedLocalizations": true,
            "CFBundleDevelopmentRegion": "English",
            "CFBundleExecutable": name,
            "CFBundleIdentifier": identifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": displayName(of: name),
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1.0",
            "NSPrincipalClass": "WineApplication",
            "LSApplicationCategoryType": "public.app-category.games",
            "LSSupportsGameMode": true,
            "LSUIElement": "1",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
        // Last, so a bundle that has it is complete. The runtime uses the bundle only while it is
        // the loader's own file; a runtime on another volume can't be linked (no Game Mode then).
        try fm.linkItem(at: loader, to: linked)
        return bundle
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
