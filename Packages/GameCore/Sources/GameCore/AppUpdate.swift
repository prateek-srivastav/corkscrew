import Darwin
import Foundation

/// A newer Corkscrew, as the latest release's `update.json` describes it. `scripts/make-dmg.sh`
/// writes that file and the Release workflow attaches it, so `releases/latest/download/update.json`
/// always names the newest published version. Releases before it have none.
///
/// An update downloads only the app (`Corkscrew-<version>-app.zip`, without the engine pack the DMG
/// carries). When the new version pins a newer engine pack, the new app downloads that at its first
/// launch, as any build without the pack inside does.
public struct AppUpdate: Sendable, Equatable {
    public enum UpdateError: Error, Equatable, CustomStringConvertible {
        case httpStatus(Int)
        case checksumMismatch
        /// The app's folder can't be written to (or macOS runs the app from a read-only copy).
        case notWritable(String)
        /// The archive doesn't hold this app at the expected version.
        case wrongApp(String)
        case toolFailed(String)

        public var description: String {
            switch self {
            case .httpStatus(let status): "the update check failed (HTTP \(status))"
            case .checksumMismatch: "the download doesn't match its SHA-256, so it wasn't installed"
            case .notWritable(let folder):
                "Corkscrew can't replace itself in \(folder). Install the new version with the install command on Corkscrew's website."
            case .wrongApp(let reason): "the download isn't the expected app (\(reason))"
            case .toolFailed(let output): output
            }
        }
    }

    /// A file in the release. A release gives its full URL in `name`; a name without a host is next
    /// to `update.json` (for a test from a local folder).
    public struct Archive: Sendable, Equatable, Decodable {
        public var name: String
        public var sha256: String
        public var size: Int64
    }

    /// The newest published version, from GitHub's redirect to the latest release (engine packs are
    /// pre-releases, which it skips).
    public static let latestURL = URL(string: "https://github.com/Prateek-Srivastav/corkscrew/releases/latest/download/update.json")!

    public var version: String
    /// The app alone, zipped.
    public var app: Archive
    /// The engine pack the new version pins.
    public var enginePack: EnginePack
    /// Where `update.json` was read from, after redirects. A relative `app.name` resolves against it,
    /// which doesn't work for a release: GitHub sends `update.json` to a signed CDN URL.
    public var source: URL

    /// Reads `update.json` at `url`. Nil when the release has none (HTTP 404).
    public static func check(_ url: URL = latestURL) async throws -> AppUpdate? {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            guard (200..<300).contains(http.statusCode) else { throw UpdateError.httpStatus(http.statusCode) }
        }
        return try decode(data, source: response.url ?? url)
    }

    static func decode(_ data: Data, source: URL) throws -> AppUpdate {
        struct Pack: Decodable { var version: String, url: URL, sha256: String, size: Int64 }
        struct File: Decodable { var version: String, app: Archive, enginePack: Pack }
        let file = try JSONDecoder().decode(File.self, from: data)
        let pack = EnginePack(version: file.enginePack.version, url: file.enginePack.url,
                              sha256: file.enginePack.sha256, size: file.enginePack.size)
        return AppUpdate(version: file.version, app: file.app, enginePack: pack, source: source)
    }

    /// Whether this is a later version than `installed` (a CFBundleShortVersionString).
    public func isNewer(than installed: String) -> Bool { EnginePack.isOlder(installed, than: version) }

    /// What updating downloads: the app, plus the engine pack when the new app will replace the
    /// installed runtime with it at its first launch.
    public func downloadSize(paths: AppPaths) -> Int64 {
        app.size + (enginePack.upgradesInstalledRuntime(in: paths) ? enginePack.size : 0)
    }

    /// Downloads the app into `downloads`, checks it, and unpacks it next to `installed` (on the
    /// same volume, so `install` can swap the two). Returns the new app, not yet in place.
    /// `progress` gets the download's fraction done (0…1).
    public func stage(nextTo installed: URL, bundleIdentifier: String, downloads: URL,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let folder = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable(folder.path) }
        guard let url = URL(string: app.name, relativeTo: source)?.absoluteURL else { throw UpdateError.wrongApp("no file \(app.name)") }
        let zip = downloads.appending(path: url.lastPathComponent)
        try await Downloader.download(url, to: zip, progress: progress)
        defer { try? FileManager.default.removeItem(at: zip) }
        guard try RuntimeStore.sha256(of: zip) == app.sha256.lowercased() else { throw UpdateError.checksumMismatch }

        let staging = Self.stagingFolder(nextTo: installed)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
            let apps = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "app" }
            guard apps.count == 1, let new = apps.first else { throw UpdateError.wrongApp("no app in \(app.name)") }
            let info = NSDictionary(contentsOf: new.appending(path: "Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == bundleIdentifier else { throw UpdateError.wrongApp("another bundle identifier") }
            guard info?["CFBundleShortVersionString"] as? String == version else { throw UpdateError.wrongApp("not version \(version)") }
            RuntimeStore.removeQuarantine(in: new)
            try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path])
            return new
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Puts the staged app where `installed` is, in one step (the two swap places), then deletes the
    /// old one and the staging folder. A running app can be replaced: macOS keeps its open files.
    public static func install(_ staged: URL, replacing installed: URL) throws {
        guard renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try? FileManager.default.removeItem(at: stagingFolder(nextTo: installed))
    }

    /// Where `stage` unpacks: a hidden folder next to the app. Delete it to drop a staged update.
    public static func stagingFolder(nextTo installed: URL) -> URL {
        installed.deletingLastPathComponent().appending(path: ".Corkscrew-update", directoryHint: .isDirectory)
    }

    /// Runs a tool without holding a thread while it works; its output is the error when it fails.
    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output: String = try await withCheckedThrowingContinuation { done in
            process.terminationHandler = { _ in
                done.resume(returning: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
        guard process.terminationStatus == 0 else {
            throw UpdateError.toolFailed("\((tool as NSString).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
