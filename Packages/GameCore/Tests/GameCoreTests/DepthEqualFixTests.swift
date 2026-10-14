import Foundation
import Testing
@testable import GameCore

struct DepthEqualFixTests {
    private let shimData = Data("MZ…Corkscrew depth-equal fix…".utf8)

    private struct Fixture {
        let context: WineContext
        let dxmt: URL
        let exe: URL
        let shim: URL
        var folder: URL { exe.deletingLastPathComponent() }
    }

    private func fixture(_ root: URL, d3dmetal: Bool = true) throws -> Fixture {
        let paths = AppPaths(
            supportRoot: root.appending(path: "support", directoryHint: .isDirectory),
            logsRoot: root.appending(path: "logs", directoryHint: .isDirectory),
            cachesRoot: root.appending(path: "caches", directoryHint: .isDirectory),
            userHome: root.appending(path: "home", directoryHint: .isDirectory),
            wineServerDirectory: root.appending(path: "wine-base", directoryHint: .isDirectory)
        )
        let dxmt = paths.components.appending(path: "dxmt-0.80", directoryHint: .isDirectory)
        try dxmt.appending(path: "x86_64-windows/d3d11.dll").write("DXMT d3d11")
        var dllPaths: [GraphicsBackend: [URL]] = [.dxmt: [dxmt]]
        if d3dmetal { dllPaths[.d3dmetal] = [paths.components.appending(path: "d3dmetal-3.0/wine")] }
        let engine = Engine(id: "winecx-test", root: paths.runtimes.appending(path: "winecx-test"),
                            architecture: .x86_64, backendDLLPaths: dllPaths)
        let location = BottleLocation(bottleID: UUID(), paths: paths)
        let bottle = Bottle(name: "Games", kind: .standard, engineID: engine.id)
        let exe = location.prefix.appending(path: "drive_c/Games/God of War/GoW.exe")
        try exe.write(PEBuilder().build())
        let shim = root.appending(path: "depth-equal-fix.dll")
        try shim.write(shimData)
        let context = WineContext(engine: engine, bottle: bottle, location: location, paths: paths, hostEnvironment: [:])
        return Fixture(context: context, dxmt: dxmt, exe: exe, shim: shim)
    }

    private func game(_ f: Fixture, backend: GraphicsBackend? = nil, available: Bool = true, exe: URL? = nil) -> GameLaunch {
        GameLaunch(gameID: UUID(), executable: exe ?? f.exe, profile: GameProfile(backendOverride: backend),
                   detectedAPIs: [.d3d11], depthEqualFixAvailable: available)
    }

    /// Auto sends God of War to DXMT through the shim, and Wine is told to load the shim.
    @Test func godOfWarGetsDXMTWithTheShim() throws {
        try withTempDir { root in
            let f = try fixture(root)
            let plan = try LaunchPlanner.plan(game(f), in: f.context)
            #expect(plan.backend == .dxmt)
            #expect(plan.depthEqualFix)
            #expect(plan.environment["WINEDLLOVERRIDES"]?.split(separator: ";").contains("d3d11=n,b") == true)

            #expect(try LaunchPlanner.plan(game(f, backend: .dxmt), in: f.context).depthEqualFix)
        }
    }

    /// Another backend picked by hand, an app without the shim, a game folder with its own
    /// d3d11.dll, or another game: the usual plan.
    @Test func otherLaunchesKeepTheUsualPlan() throws {
        try withTempDir { root in
            let f = try fixture(root)
            let picked = try LaunchPlanner.plan(game(f, backend: .d3dmetal), in: f.context)
            #expect(picked.backend == .d3dmetal)
            #expect(!picked.depthEqualFix)
            #expect(picked.environment["WINEDLLOVERRIDES"]?.contains("d3d11") == false)

            let noShim = try LaunchPlanner.plan(game(f, available: false), in: f.context)
            #expect(noShim.backend == .d3dmetal)
            #expect(!noShim.depthEqualFix)

            let other = f.folder.appending(path: "Other.exe")
            try other.write(PEBuilder().build())
            #expect(try LaunchPlanner.plan(game(f, exe: other), in: f.context).backend == .d3dmetal)

            try f.folder.appending(path: "d3d11.dll").write("ReShade")
            let modded = try LaunchPlanner.plan(game(f), in: f.context)
            #expect(modded.backend == .d3dmetal)
            #expect(!modded.depthEqualFix)
        }
    }

    /// The shim and DXMT's d3d11.dll go next to the game, are refreshed when they change, and are
    /// taken away for another backend; a d3d11.dll the game ships is never touched.
    @Test func filesFollowTheBackend() throws {
        try withTempDir { root in
            let f = try fixture(root)
            let shim = f.folder.appending(path: "d3d11.dll")
            let dxmt = f.folder.appending(path: "corkscrew_dxmt_d3d11.dll")
            #expect(try DepthEqualFix.install(shim: f.shim, dxmt: f.dxmt, nextTo: f.exe))
            #expect(try Data(contentsOf: shim) == shimData)
            #expect(try String(contentsOf: dxmt, encoding: .utf8) == "DXMT d3d11")
            #expect(DepthEqualFix.canInstall(nextTo: f.exe))
            #expect(try !DepthEqualFix.install(shim: f.shim, dxmt: f.dxmt, nextTo: f.exe), "already up to date")

            try f.dxmt.appending(path: "x86_64-windows/d3d11.dll").write("DXMT d3d11, newer")
            #expect(try DepthEqualFix.install(shim: f.shim, dxmt: f.dxmt, nextTo: f.exe))
            #expect(try String(contentsOf: dxmt, encoding: .utf8) == "DXMT d3d11, newer")

            #expect(try DepthEqualFix.remove(nextTo: f.exe))
            #expect(!FileManager.default.fileExists(atPath: shim.path))
            #expect(!FileManager.default.fileExists(atPath: dxmt.path))
            #expect(try !DepthEqualFix.remove(nextTo: f.exe))

            try shim.write("ReShade")
            try dxmt.write("left over")
            #expect(!DepthEqualFix.canInstall(nextTo: f.exe))
            #expect(try DepthEqualFix.remove(nextTo: f.exe))
            #expect(try String(contentsOf: shim, encoding: .utf8) == "ReShade")
        }
    }
}
