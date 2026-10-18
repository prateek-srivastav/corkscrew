import Foundation
import Testing
@testable import GameCore

struct AppUpdateTests {
    static let bundleID = "io.github.prateek-srivastav.Corkscrew"

    /// A signed app bundle like Corkscrew's, at `version`; its executable is a copy of /bin/sleep.
    static func makeApp(at app: URL, version: String, bundleID: String = bundleID) async throws {
        try app.appending(path: "Contents/Info.plist").write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(bundleID)</string>
        <key>CFBundleShortVersionString</key><string>\(version)</string>
        <key>CFBundleExecutable</key><string>Corkscrew</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """)
        let executable = try app.appending(path: "Contents/MacOS").makeDirectory().appending(path: "Corkscrew")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        try await offThePool { try Self.tool("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) }
    }

    /// A release folder as the Release workflow makes it: the app zipped, and update.json naming it.
    /// Returns update.json's URL.
    static func makeRelease(in folder: URL, appVersion: String, manifestVersion: String? = nil,
                            sha256: String? = nil, pack: String = "26.3.0-5") async throws -> URL {
        let app = folder.appending(path: "build/Corkscrew.app")
        try await makeApp(at: app, version: appVersion)
        let zip = folder.appending(path: "Corkscrew-\(appVersion)-app.zip")
        try await offThePool { try Self.tool("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]) }
        let sha256 = try sha256 ?? RuntimeStore.sha256(of: zip)
        let manifest = folder.appending(path: "update.json")
        try manifest.write("""
        {"version": "\(manifestVersion ?? appVersion)",
         "app": {"name": "\(zip.lastPathComponent)", "sha256": "\(sha256)", "size": 1000},
         "enginePack": {"version": "\(pack)", "url": "https://example.invalid/pack.tar.xz", "sha256": "00", "size": 300000}}
        """)
        return manifest
    }

    static func tool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolFailed(path: path) }
    }

    struct ToolFailed: Error { let path: String }

    static func version(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    @Test func readsUpdateJSON() async throws {
        try await withTempDir { root in
            let manifest = root.appending(path: "update.json")
            try manifest.write("""
            {"version": "0.9.0", "app": {"name": "Corkscrew-0.9.0-app.zip", "sha256": "AB", "size": 21000000},
             "enginePack": {"version": "26.3.0-6", "url": "https://example.invalid/pack.tar.xz", "sha256": "cd", "size": 319000000}}
            """)
            let update = try #require(try await AppUpdate.check(manifest))
            #expect(update.version == "0.9.0")
            #expect(update.app == AppUpdate.Archive(name: "Corkscrew-0.9.0-app.zip", sha256: "AB", size: 21000000))
            #expect(update.enginePack == EnginePack(version: "26.3.0-6", url: URL(string: "https://example.invalid/pack.tar.xz")!,
                                                    sha256: "cd", size: 319000000))
            #expect(update.source == manifest)
        }
    }

    @Test func comparesVersionsNumerically() throws {
        let update = try AppUpdate.decode(Data("""
        {"version": "0.10.0", "app": {"name": "a.zip", "sha256": "00", "size": 1},
         "enginePack": {"version": "1-1", "url": "https://example.invalid/p", "sha256": "00", "size": 1}}
        """.utf8), source: URL(string: "https://example.invalid/update.json")!)
        #expect(update.isNewer(than: "0.9.1"))
        #expect(update.isNewer(than: "0.8.1"))
        #expect(!update.isNewer(than: "0.10.0"))
        #expect(!update.isNewer(than: "0.11.0"))
    }

    /// The engine pack counts only when the new app will replace the installed runtime with it.
    @Test func downloadSizeCountsANewerEnginePack() throws {
        try withTempDir { root in
            let paths = RuntimeStoreTests.paths(root)
            func update(pack: String) -> AppUpdate {
                AppUpdate(version: "0.9.0", app: .init(name: "a.zip", sha256: "00", size: 20),
                          enginePack: EnginePack(version: pack, url: URL(string: "https://example.invalid/p")!, sha256: "00", size: 300),
                          source: URL(string: "https://example.invalid/update.json")!)
            }
            // Not set up yet: setup downloads the pack, not the update.
            #expect(update(pack: "26.3.0-6").downloadSize(paths: paths) == 20)

            let runtime = paths.runtimes.appending(path: "winecx-test-x86_64")
            try RuntimeStoreTests.makeRuntime(at: runtime)
            try RuntimeStore.recordPackVersion("26.3.0-5", in: runtime)
            #expect(update(pack: "26.3.0-5").downloadSize(paths: paths) == 20)
            #expect(update(pack: "26.3.0-6").downloadSize(paths: paths) == 320)
        }
    }

    @Test func stagesAndInstallsTheNewApp() async throws {
        try await withTempDir { root in
            let installed = root.appending(path: "Applications/Corkscrew.app")
            try await Self.makeApp(at: installed, version: "0.8.1")
            let manifest = try await Self.makeRelease(in: root.appending(path: "release"), appVersion: "0.9.0")
            let downloads = root.appending(path: "downloads")
            let update = try #require(try await AppUpdate.check(manifest))

            let staged = try await update.stage(nextTo: installed, bundleIdentifier: Self.bundleID, downloads: downloads)
            #expect(Self.version(of: staged) == "0.9.0")
            #expect(Self.version(of: installed) == "0.8.1")
            // The zip is gone once unpacked.
            #expect(try FileManager.default.contentsOfDirectory(atPath: downloads.path).isEmpty)

            try AppUpdate.install(staged, replacing: installed)
            #expect(Self.version(of: installed) == "0.9.0")
            // The old app and the staging folder are gone.
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Applications").path) == ["Corkscrew.app"])
        }
    }

    @Test func refusesADownloadThatDoesNotMatchItsChecksum() async throws {
        try await withTempDir { root in
            let installed = root.appending(path: "Applications/Corkscrew.app")
            try await Self.makeApp(at: installed, version: "0.8.1")
            let manifest = try await Self.makeRelease(in: root.appending(path: "release"), appVersion: "0.9.0",
                                                      sha256: String(repeating: "0", count: 64))
            let update = try #require(try await AppUpdate.check(manifest))
            await #expect(throws: AppUpdate.UpdateError.checksumMismatch) {
                try await update.stage(nextTo: installed, bundleIdentifier: Self.bundleID, downloads: root.appending(path: "downloads"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Applications").path) == ["Corkscrew.app"])
        }
    }

    @Test func refusesAnAppOfAnotherVersion() async throws {
        try await withTempDir { root in
            let installed = root.appending(path: "Applications/Corkscrew.app")
            try await Self.makeApp(at: installed, version: "0.8.1")
            let manifest = try await Self.makeRelease(in: root.appending(path: "release"), appVersion: "0.9.0", manifestVersion: "0.9.1")
            let update = try #require(try await AppUpdate.check(manifest))
            await #expect(throws: AppUpdate.UpdateError.wrongApp("not version 0.9.1")) {
                try await update.stage(nextTo: installed, bundleIdentifier: Self.bundleID, downloads: root.appending(path: "downloads"))
            }
            // Nothing staged is left next to the app.
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "Applications").path) == ["Corkscrew.app"])
            #expect(Self.version(of: installed) == "0.8.1")
        }
    }
}
