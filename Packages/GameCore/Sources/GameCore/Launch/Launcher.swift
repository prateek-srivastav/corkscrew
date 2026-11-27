import Foundation
import Synchronization

/// Everything between "Play" and the program starting, shared by the app and `gamecore-cli`:
/// inspect the program, harden and update the bottle, set up the Rockstar launcher when a game needs
/// it, apply Retina mode, plan the command.
public enum Launcher {
    public struct Prepared: Sendable {
        public var plan: LaunchPlan
        public var context: WineContext
        /// This launch's log (`<logs>/<game>/launch-<time>.log`).
        public var log: URL
        /// What the detector found; nil for installer packages (`.msi`).
        public var inspection: GameInspection?
        /// Worth telling the user: the bottle was updated, the desktop size Retina mode gives, …
        public var notes: [String]
        /// Set for a game started through Steam: `run` follows the game rather than `steam.exe`.
        public var steamGame: SteamGameLaunch?
        /// The `steam.exe` this launch runs, as its plan has it; nil for other programs.
        var steamExecutable: String? { plan.arguments.first { $0.lowercased().hasSuffix("steam.exe") } }
        /// Set when this launch starts `steam.exe` with the web helper wrapper: `run` keeps it in
        /// front of Steam's helper while Steam runs (Steam installs updates at startup).
        public var steamWebHelperWrapper: URL? = nil
        /// For a program that isn't Steam: its folder under `drive_c`, lowercased, with backslashes
        /// (`\program files\game\`). A launcher can start the game and quit: `run` then follows
        /// the programs from this folder.
        public var gameFolder: String? = nil
    }

    /// Where a Steam game's launch is, from Steam's own log of the game's programs (`SteamGameLog`),
    /// for the user to see.
    public enum LaunchPhase: Sendable, Equatable {
        /// Steam starts, or gets the game ready: it hasn't started a program for the game yet.
        case steam
        /// Steam started this program for the game (its name), and no window of the game's shows yet.
        case starting(String)
        /// A window of the game's programs has shown.
        case playing
        /// This program (its name) won't get the game started, and only a new launch helps: the
        /// Rockstar Games Launcher after losing its background service (`RockstarLauncher.hasLostService`).
        case stuck(String)
        /// Steam has ended the game, and these programs started with it still run (their names).
        case closing([String])
        /// The game has ended, and Steam, which started for it, quits as its own Exit does.
        case quittingSteam
    }

    public struct LaunchProgress: Sendable, Equatable {
        public var phase: LaunchPhase
        /// The program whose window is the one to bring forward: the frontmost of the game's, else
        /// (before Steam starts the game) one Steam opened. Nil while none shows.
        public var front: pid_t?
    }

    /// A game started with `steam.exe -applaunch <id>`. Its launch follows what Steam says of the
    /// game's programs (`SteamGameLog`), then what those leave running.
    public struct SteamGameLaunch: Sendable, Equatable {
        public var appID: String
        public var steamRoot: URL
        /// Steam wasn't running before this launch: once the game has ended, it quits again
        /// (`quitsSteam`). A Steam the player opened stays.
        public var startsSteam: Bool
    }

    static let pollInterval: Duration = .seconds(2)

    /// `steamWebHelperWrapper`: the built `tools/steamwebhelper-wrapper`; when given, launching Steam
    /// first puts it back in front of Steam's web helper (Steam updates remove it).
    /// `depthEqualShim`: the built `tools/depth-equal-fix`; when given, games that need it
    /// (`DepthEqualFix`) run DXMT or D3DMetal through it.
    public static func prepare(
        gameID: UUID, executable: URL, profile: GameProfile, bottle: Bottle, engine: Engine, paths: AppPaths,
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment, startedAt: Date = .now,
        steamWebHelperWrapper: URL? = nil, depthEqualShim: URL? = nil
    ) async throws -> Prepared {
        let inspection = isInstallerPackage(executable) ? nil : try GameDetector.inspect(executable: executable)
        let store = BottleStore(paths: paths, hostEnvironment: hostEnvironment)
        let context = WineContext(engine: engine, bottle: bottle, location: store.location(of: bottle),
                                  paths: paths, hostEnvironment: hostEnvironment)
        try store.ensureWineServerBase()
        try store.keepFoldersApart(bottle)
        if bottle.kind == .isolated {
            // For Game Mode; the game still starts without it.
            _ = try? LoaderBundles.prepare(for: executable, engine: engine, in: LoaderBundles.prebuiltFolder(for: engine, paths: paths))
        }
        var notes: [String] = []
        // Before anything below starts Wine in the bottle.
        let steamGame = steamGameLaunch(executable: executable, arguments: profile.arguments, prefix: context.location.prefix)
        if Steam.isClient(executable), let wrapper = steamWebHelperWrapper,
           try Steam.installWebHelperWrapper(steamRoot: executable.deletingLastPathComponent(), wrapper: wrapper) {
            notes.append("Put the web helper wrapper back in front of Steam's (a Steam update had replaced it).")
        }
        if Steam.isClient(executable), steamWebHelperWrapper != nil {
            // So the Dock shows "Steam"; Steam still starts without it.
            _ = try? LoaderBundles.prepareSteamWebHelper(engine: engine, isolated: bottle.kind == .isolated, paths: paths)
        }
        switch try await store.prepareForLaunch(bottle, engine: engine) {
        case .upToDate: break
        case .updated: notes.append("The runtime's modules changed; updated the bottle (wineboot --update).")
        case .updateDeferred: notes.append("The runtime's modules changed, but the bottle is running; it updates on the next launch.")
        }
        // After the update, which puts Wine's builtin DLLs back in system32.
        if RockstarLauncher.isNeeded(prefix: context.location.prefix) {
            notes += try await RockstarLauncher.apply(in: context, log: paths.logs(for: gameID).appending(path: "rockstar.log"))
        }

        var profile = profile
        if Steam.isClient(executable) {
            let root = executable.deletingLastPathComponent()
            // Every launch of Steam, not only this game's: games also start from Steam's own window.
            for app in Steam.installedApps(steamRoot: root, prefix: context.location.prefix) {
                if app.appID == WukongSettings.appID, try WukongSettings.apply(installFolder: app.installFolder) {
                    notes.append("Turned off Frame Generation for \(app.name); with it on, the game crashes or stays black on D3DMetal.")
                }
                if app.appID == GodOfWarSettings.appID, try GodOfWarSettings.apply(installFolder: app.installFolder) {
                    notes.append(GodOfWarSettings.note)
                }
            }
            if !Steam.isBootstrapped(steamRoot: root) {
                notes.append("Steam downloads the rest of itself first (about 240 MB), then restarts.")
            }
            profile.arguments = Steam.launchArguments(profile.arguments, steamRoot: root)
        }
        let plan = try LaunchPlanner.plan(
            GameLaunch(gameID: gameID, executable: executable, profile: profile,
                       detectedAPIs: inspection?.graphicsAPIs ?? [], machine: inspection?.machine ?? .x86_64,
                       depthEqualFixAvailable: depthEqualShim != nil),
            in: context
        )
        if let folder = ShaderCacheLinks.userCacheFolder {
            // For speed; the game still starts without them.
            try? ShaderCacheLinks.prepare(for: executable, gameID: gameID, isolated: bottle.kind == .isolated, paths: paths, in: folder)
        }
        if GodOfWarSettings.isGame(executable),
           try GodOfWarSettings.apply(installFolder: executable.deletingLastPathComponent()) {
            notes.append(GodOfWarSettings.note)
        }
        if plan.depthEqualFix, let shim = depthEqualShim, let backend = plan.backend,
           let folder = engine.backendDLLPaths[backend]?.first {
            try DepthEqualFix.install(shim: shim, backend: folder, nextTo: executable)
            notes.append("Runs on \(backend.displayName) with a depth-test fix that removes the white specks on characters.")
        } else if try DepthEqualFix.remove(nextTo: executable) {
            notes.append("Took the depth-test fix out of the game folder: it only works with DXMT and D3DMetal.")
        }
        if LaunchPlanner.usesOnlineFix(executable) {
            notes.append("OnlineFix found: the game's own loader DLL is used, and Steam's overlay stays on because OnlineFix needs it.")
        }
        if let missing = plan.unavailableBackend, let used = plan.backend {
            notes.append("\(missing.displayName) isn't installed, so this launch uses \(used.displayName)."
                         + (missing == .d3dmetal ? " To get D3DMetal back, click Set Up Corkscrew, or import a Game Porting Toolkit under Setup → Advanced." : ""))
        }
        let logs = paths.logs(for: gameID)
        let prefix = context.location.prefix
        if Steam.isClient(executable), WineServer.isRunning(prefix: context.location.prefix, base: paths.wineServerDirectory) {
            // A running Steam takes this steam.exe's arguments and starts the game in its own session,
            // which keeps the Retina setting it started with; switching would mean quitting Steam.
            let isEnabled = RetinaMode.isEnabled(prefix: context.location.prefix)
            if isEnabled != profile.retinaMode {
                notes.append("The bottle is already running with Retina mode \(isEnabled ? "on" : "off"), so this launch keeps it. "
                             + "Quit Steam first to use this game's setting.")
            }
        } else {
            try await RetinaMode.apply(profile.retinaMode, in: context, log: logs.appending(path: "retina.log"))
            if let size = RetinaMode.desktopSize(enabled: profile.retinaMode) {
                notes.append("Retina mode \(profile.retinaMode ? "on" : "off"): the game sees a \(size.width)×\(size.height) desktop.")
            }
        }
        // After Retina mode, which reads whether the bottle runs: this starts a short Wine session.
        await CrashDialog.apply(in: context, log: logs.appending(path: "crash-dialog.log"))
        return Prepared(plan: plan, context: context, log: logs.appending(path: LaunchLogs.fileName(startedAt: startedAt)),
                        inspection: inspection, notes: notes, steamGame: steamGame,
                        steamWebHelperWrapper: Steam.isClient(executable) ? steamWebHelperWrapper : nil,
                        gameFolder: Steam.isClient(executable) || steamGame != nil ? nil : gameFolder(of: executable, prefix: prefix))
    }

    /// `executable`'s game folder as `gameFolder` has it; nil outside the bottle's `drive_c`, or
    /// for `drive_c` itself.
    static func gameFolder(of executable: URL, prefix: URL) -> String? {
        driveCFolder(GameDetector.gameRoot(for: executable), prefix: prefix)
    }

    /// `folder` as a program's path in the bottle has it, without the drive: lowercased, with
    /// backslashes (`\program files\game\`). Nil outside `drive_c`, or for `drive_c` itself.
    static func driveCFolder(_ folder: URL, prefix: URL) -> String? {
        let driveC = prefix.appending(path: "drive_c").standardizedFileURL.path + "/"
        let root = folder.standardizedFileURL.path
        guard root.hasPrefix(driveC), root.count > driveC.count else { return nil }
        return "\\" + root.dropFirst(driveC.count).lowercased().replacingOccurrences(of: "/", with: "\\") + "\\"
    }

    static func steamGameLaunch(executable: URL, arguments: [String], prefix: URL) -> SteamGameLaunch? {
        guard Steam.isClient(executable), let flag = arguments.firstIndex(of: "-applaunch"),
              arguments.indices.contains(flag + 1) else { return nil }
        let appID = arguments[flag + 1]
        let root = executable.deletingLastPathComponent()
        guard Steam.installedApps(steamRoot: root, prefix: prefix).contains(where: { $0.appID == appID }) else { return nil }
        return SteamGameLaunch(appID: appID, steamRoot: root, startsSteam: !BottleProcesses.isSteamRunning(prefix: prefix))
    }

    /// Whether Steam quits after `game`'s launch: when the launch started it, Steam ended the game
    /// (not Steam quitting or crashing), and no other Steam game runs (`running`, by app id, from
    /// `Steam.runningApps`).
    static func quitsSteam(after game: SteamGameLaunch, gameEnded: Bool, running: [String: [pid_t]]) -> Bool {
        game.startsSteam && gameEnded && !running.contains { $0.key != game.appID && !$0.value.isEmpty }
    }

    /// Runs a prepared launch to completion; cancelling stops the bottle's whole session. A Steam
    /// game's launch lasts until Steam says the game has ended, and what it started has closed
    /// (`SteamGameFollower`); then a Steam the launch started quits (`quitsSteam`). `progress` hears
    /// where it is while it does.
    public static func run(_ prepared: Prepared, progress: (@Sendable (LaunchProgress) -> Void)? = nil) async throws -> RunResult {
        let wineserver = prepared.context.engine.wineserver
        if let wrapper = prepared.steamWebHelperWrapper,
           let steam = prepared.steamExecutable {
            guardWebHelperWrapper(wrapper, steamRoot: URL(fileURLWithPath: steam).deletingLastPathComponent(),
                                  prefix: prepared.context.location.prefix)
        }
        guard let game = prepared.steamGame else {
            var result = try await ProcessRunner.run(prepared.plan, log: prepared.log, wineserver: wineserver)
            if let folder = prepared.gameFolder { result.followed = try await followGame(in: folder, prepared) }
            return result
        }
        let prefix = prepared.context.location.prefix
        // Taken before Steam starts the game: what Steam writes from now on is this launch's.
        let log = SteamGameLog(steamRoot: game.steamRoot, appID: game.appID)
        let triggers = LaunchTriggers(watching: log.file)
        // A window Steam opens while it gets the game ready asks something (the game runs on
        // another computer, sign in); Steam's windows already open don't.
        let steamWindows = BottleProcesses.windowsOnScreen(prefix: prefix, of: isSteamInterface)
        // Steam's own process runs apart from the launch, which follows the game rather than Steam.
        let steamExit = SteamExit()
        let steam = Task {
            do { steamExit.finish(.success(try await ProcessRunner.run(prepared.plan, log: prepared.log, wineserver: wineserver))) }
            catch { steamExit.finish(.failure(error)) }
            triggers.wake()
        }
        let follower = SteamGameFollower(log: log, prefix: prefix, steamFolder: driveCFolder(game.steamRoot, prefix: prefix),
                                         steamWindows: steamWindows, triggers: triggers, trace: LaunchTrace(besides: prepared.log))
        let followed = await withTaskCancellationHandler {
            var follower = follower
            await follower.follow(steamHasExited: { steamExit.result != nil }, progress: progress)
            return follower
        } onCancel: {
            steam.cancel()
            triggers.stop()
            // With Steam already open, the launch's steam.exe has handed the game over and exited:
            // cancelling it stops nothing, so the bottle's session stops here, as Stop says.
            ProcessRunner.stopSession(environment: prepared.plan.environment, wineserver: wineserver)
        }
        try Task.checkCancellation()
        if quitsSteam(after: game, gameEnded: followed.gameEnded, running: Steam.runningApps(prefix: prefix)),
           let steamExe = prepared.steamExecutable {
            progress?(LaunchProgress(phase: .quittingSteam, front: nil))
            try await shutDownSteam(steamExe, context: prepared.context,
                                    log: prepared.log.deletingLastPathComponent().appending(path: "steam-shutdown.log"))
        }
        var result = try steamExit.result?.get() ?? RunResult(status: 0, log: prepared.log)
        result.followed = followed.programs
        return result
    }

    /// What Steam's process came to, once it has: the launch doesn't wait for it.
    private final class SteamExit: Sendable {
        private let state = Mutex<Result<RunResult, Error>?>(nil)
        var result: Result<RunResult, Error>? { state.withLock { $0 } }
        func finish(_ result: Result<RunResult, Error>) { state.withLock { $0 = result } }
    }

    /// Steam's client, and its interface: behind the wrapper, `steamwebhelper_real.exe` owns the windows.
    static func isSteamInterface(_ process: BottleProcesses.Entry) -> Bool {
        process.isSteamClient || process.isSteamWebHelper || process.program.hasSuffix("\\steamwebhelper_real.exe")
    }

    /// Of `processes`, what started with the game and runs on after Steam ended it: what didn't run
    /// before (`before`), apart from Wine's own programs and Steam's (from `steamFolder`, outside its
    /// games' folders).
    static func leftovers(_ processes: [BottleProcesses.Entry], before: Set<pid_t>, steamFolder: String?) -> [BottleProcesses.Entry] {
        processes.filter { process in
            let program = process.program
            let isSteams = steamFolder.map { program.contains($0) && !program.contains("\\steamapps\\") } ?? false
            return !before.contains(process.pid) && !process.isWineService && !isSteams
        }
    }

    /// A program's name for the user, from its Windows path: its description (as Task Manager
    /// shows it, `PEFile.fileDescription`), else its file's name.
    static func programName(_ path: String, prefix: URL) -> String {
        let parts = path.split(separator: "\\").map(String.init)
        let file = BottleProcesses.fileName(of: path)
        let fallback = file.lowercased().hasSuffix(".exe") ? String(file.dropLast(4)) : file
        guard let drive = parts.first, drive.hasSuffix(":"), parts.count > 1 else { return fallback }
        let url = parts.dropFirst().reduce(prefix.appending(path: "dosdevices/\(drive.lowercased())")) { $0.appending(path: $1) }
        return (try? PEFile.fileDescription(contentsOf: url)) ?? fallback
    }

    /// The launch lasts while programs from the game's folder run, which a launcher may have
    /// started before it quit. Returns their names, lowercased. Stop ends them with the bottle.
    static func followGame(in folder: String, _ prepared: Prepared) async throws -> [String] {
        let prefix = prepared.context.location.prefix
        return try await withTaskCancellationHandler {
            var names: Set<String> = []
            while true {
                let running = BottleProcesses.list(prefix: prefix, maxAge: .zero).map(\.program).filter { $0.contains(folder) }
                if running.isEmpty { return names.sorted() }
                names.formUnion(running.map(BottleProcesses.fileName(of:)))
                try await Task.sleep(for: pollInterval)
            }
        } onCancel: {
            ProcessRunner.stopSession(environment: prepared.plan.environment, wineserver: prepared.context.engine.wineserver)
        }
    }

    /// Quits Steam in the bottle as its own Exit does (it saves its state and signs nothing out),
    /// then stops whatever else runs there.
    public static func quitSteam(in bottle: Bottle, steam: URL, engine: Engine, paths: AppPaths, log: URL,
                                 hostEnvironment: [String: String] = ProcessInfo.processInfo.environment) async throws {
        let context = WineContext(engine: engine, bottle: bottle, location: BottleLocation(bottleID: bottle.id, paths: paths),
                                  paths: paths, hostEnvironment: hostEnvironment)
        try await closeSteam(steam.path, context: context, log: log)
    }

    private static func closeSteam(_ steam: String, context: WineContext, log: URL) async throws {
        let plan = try await shutDownSteam(steam, context: context, log: log)
        ProcessRunner.stopSession(environment: plan.environment, wineserver: context.engine.wineserver)
    }

    /// How long Steam may take to quit after `-shutdown` (it saves its state first).
    static let steamQuitTimeout: Duration = .seconds(30)

    /// Asks Steam to quit as its own Exit does, and waits up to `steamQuitTimeout` for it. Ends
    /// nothing itself: what a game left running stays, and Wine's services end once nothing runs.
    @discardableResult
    private static func shutDownSteam(_ steam: String, context: WineContext, log: URL) async throws -> LaunchPlan {
        let plan = try LaunchPlanner.plan(wineArguments: [steam, "-shutdown"], in: context)
        _ = try await ProcessRunner.run(plan, log: log, wineserver: context.engine.wineserver)
        let clock = ContinuousClock()
        let deadline = clock.now + steamQuitTimeout
        while clock.now < deadline, BottleProcesses.isSteamRunning(prefix: context.location.prefix) {
            try await Task.sleep(for: pollInterval)
        }
        return plan
    }

    static let wrapperPoll: Duration = .seconds(1)
    /// Once Steam has run through the wrapper for `settle`: an update only replaces the helper when
    /// Steam starts, so a slower check is enough until Steam restarts.
    static let wrapperSteadyPoll: Duration = .seconds(5)
    /// Prefixes whose web helper is being guarded: one guard per bottle.
    private static let guardedPrefixes = Mutex<Set<String>>([])

    /// Keeps the web helper wrapper in front of Steam's helper while Steam runs in the bottle (past
    /// this launch: the `steam.exe` started here exits when Steam restarts itself).
    static func guardWebHelperWrapper(_ wrapper: URL, steamRoot: URL, prefix: URL) {
        let key = prefix.standardizedFileURL.path
        guard guardedPrefixes.withLock({ $0.insert(key).inserted }) else { return }
        Task.detached(priority: .utility) {
            defer { _ = guardedPrefixes.withLock { $0.remove(key) } }
            await keepWebHelperWrapper(wrapper, steamRoot: steamRoot, prefix: prefix)
        }
    }

    /// Keeps the web helper wrapper in front of Steam's helper until Steam has been gone from the
    /// bottle for `gone` (a restart leaves a short gap), or Steam never starts within `startup`.
    /// Steam installs an update it downloaded earlier when it starts, which puts its own helper back,
    /// then restarts (about 10 s before its window starts): the wrapper goes back in before that. When
    /// Steam's own helper started anyway (its window is black), it's stopped so Steam starts it again,
    /// through the wrapper. Once Steam has run through the wrapper for `settle`, it checks every
    /// `steadyPoll`, and every `poll` again when Steam's client goes away (a restart).
    static func keepWebHelperWrapper(
        _ wrapper: URL, steamRoot: URL, prefix: URL, poll: Duration = wrapperPoll, steadyPoll: Duration = wrapperSteadyPoll,
        settle: Duration = .seconds(30), startup: Duration = .seconds(60), gone: Duration = .seconds(5)
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        var lastSeen: ContinuousClock.Instant?
        var wrappedSince: ContinuousClock.Instant?
        var restarts = 0
        while !Task.isCancelled {
            let processes = BottleProcesses.list(prefix: prefix, maxAge: poll / 2)
            let steamRuns = processes.contains { BottleProcesses.isSteamClient($0.program) }
            if steamRuns {
                lastSeen = clock.now
            } else if clock.now - (lastSeen ?? started) >= (lastSeen == nil ? startup : gone) {
                return
            }
            var unwrapped: [BottleProcesses.Entry] = []
            if (try? Steam.installWebHelperWrapper(steamRoot: steamRoot, wrapper: wrapper)) != nil, restarts < 3 {
                unwrapped = unwrappedWebHelpers(processes)
                if !unwrapped.isEmpty {
                    restarts += 1
                    for process in unwrapped { kill(process.pid, SIGKILL) }
                }
            }
            if steamRuns, unwrapped.isEmpty, processes.contains(where: { $0.program.hasSuffix("\\steamwebhelper_real.exe") }) {
                wrappedSince = wrappedSince ?? clock.now
            } else {
                wrappedSince = nil
            }
            let steady = wrappedSince.map { clock.now - $0 >= settle } ?? false
            try? await Task.sleep(for: steady ? steadyPoll : poll)
        }
    }

    /// Steam's own web helper, when it runs without the wrapper: all `steamwebhelper.exe` processes,
    /// once one of them is a Chromium child (`--type=…`). Through the wrapper, the children are
    /// `steamwebhelper_real.exe`, and the one `steamwebhelper.exe` is the wrapper.
    static func unwrappedWebHelpers(_ processes: [BottleProcesses.Entry]) -> [BottleProcesses.Entry] {
        let helpers = processes.filter { $0.program.hasSuffix("\\steamwebhelper.exe") }
        return helpers.contains { $0.arguments.contains { $0.hasPrefix("--type=") } } ? helpers : []
    }

    /// Whether anything runs in the bottle (its wineserver is up).
    public static func isRunning(_ bottle: Bottle, paths: AppPaths) -> Bool {
        WineServer.isRunning(prefix: BottleLocation(bottleID: bottle.id, paths: paths).prefix, base: paths.wineServerDirectory)
    }

    /// Stops every program in the bottle (`wineserver -k`).
    public static func stop(_ bottle: Bottle, engine: Engine, paths: AppPaths,
                            hostEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let context = WineContext(engine: engine, bottle: bottle, location: BottleLocation(bottleID: bottle.id, paths: paths),
                                  paths: paths, hostEnvironment: hostEnvironment)
        ProcessRunner.stopSession(environment: try LaunchPlanner.plan(wineArguments: [], in: context).environment,
                                  wineserver: engine.wineserver)
    }

    static func isInstallerPackage(_ url: URL) -> Bool { url.pathExtension.lowercased() == "msi" }
}

/// A game's launch logs: one file per launch, named by start time so they sort.
public enum LaunchLogs {
    static func fileName(startedAt date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "launch-\(formatter.string(from: date)).log"
    }

    /// Newest first.
    public static func list(for gameID: UUID, paths: AppPaths) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.logs(for: gameID), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("launch-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
