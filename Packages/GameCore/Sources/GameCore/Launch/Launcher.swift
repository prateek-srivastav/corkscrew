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
        /// Set when this launch starts Steam itself: the Windows path of `tools/visible-windows` in
        /// the bottle, which `run` uses to quit Steam once its window is closed.
        public var steamWindowCounter: String?
        /// Set when this launch starts `steam.exe` with the web helper wrapper: `run` keeps it in
        /// front of Steam's helper while Steam runs (Steam installs updates at startup).
        public var steamWebHelperWrapper: URL? = nil
    }

    /// A game started with `steam.exe -applaunch <id>`. Steam, and launchers like Rockstar's, keep
    /// running after the game quits, so the launch ends with the game's own programs (those in its
    /// Steam folder), and closes what it started.
    public struct SteamGameLaunch: Sendable, Equatable {
        /// The game's folder under `steamapps/common`.
        public var installDir: String
        /// When Steam wasn't running before, it's closed again once the game quits.
        public var steamWasRunning: Bool
        /// The game starts the Rockstar Games Launcher, which is closed once the game quits.
        public var usesRockstarLauncher: Bool
    }

    /// How long a Steam game may take to show up (Steam starting, launchers signing in), and how
    /// long its programs must be gone before it counts as quit (games restart themselves).
    static let gameStartTimeout: Duration = .seconds(600)
    static let gameQuitGrace: Duration = .seconds(10)
    static let pollInterval: Duration = .seconds(2)
    /// How long Steam may run with no window before it counts as closed, and how often to look.
    static let steamClosedGrace: Duration = .seconds(30)
    static let steamWindowPoll: Duration = .seconds(10)

    /// `steamWebHelperWrapper`: the built `tools/steamwebhelper-wrapper`; when given, launching Steam
    /// first puts it back in front of Steam's web helper (Steam updates remove it).
    /// `visibleWindowsHelper`: the built `tools/visible-windows`; when given, a launch that starts
    /// Steam quits it once its window is closed.
    /// `depthEqualShim`: the built `tools/depth-equal-fix`; when given, games that need it
    /// (`DepthEqualFix`) run DXMT or D3DMetal through it.
    public static func prepare(
        gameID: UUID, executable: URL, profile: GameProfile, bottle: Bottle, engine: Engine, paths: AppPaths,
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment, startedAt: Date = .now,
        steamWebHelperWrapper: URL? = nil, visibleWindowsHelper: URL? = nil, depthEqualShim: URL? = nil
    ) async throws -> Prepared {
        let inspection = isInstallerPackage(executable) ? nil : try GameDetector.inspect(executable: executable)
        let store = BottleStore(paths: paths, hostEnvironment: hostEnvironment)
        let context = WineContext(engine: engine, bottle: bottle, location: store.location(of: bottle),
                                  paths: paths, hostEnvironment: hostEnvironment)
        try store.ensureWineServerBase()
        if bottle.kind == .isolated {
            try PrefixHardening.apply(prefix: context.location.prefix)
            // For Game Mode; the game still starts without it.
            _ = try? LoaderBundles.prepare(for: executable, engine: engine, in: LoaderBundles.prebuiltFolder(for: engine, paths: paths))
        }
        var notes: [String] = []
        // Before anything below starts Wine in the bottle.
        let steamGame = steamGameLaunch(executable: executable, arguments: profile.arguments, prefix: context.location.prefix)
        let bottleWasRunning = WineServer.isRunning(prefix: context.location.prefix, base: paths.wineServerDirectory)
        if let steamGame, !steamGame.steamWasRunning {
            notes.append("Steam starts for this game and closes again when the game quits.")
        }
        if Steam.isClient(executable), let wrapper = steamWebHelperWrapper,
           try Steam.installWebHelperWrapper(steamRoot: executable.deletingLastPathComponent(), wrapper: wrapper) {
            notes.append("Put the web helper wrapper back in front of Steam's (a Steam update had replaced it).")
        }
        switch try await store.prepareForLaunch(bottle, engine: engine) {
        case .upToDate: break
        case .updated: notes.append("The runtime's modules changed; updated the bottle (wineboot --update).")
        case .updateDeferred: notes.append("The runtime's modules changed, but the bottle is running; it updates on the next launch.")
        }
        // Before RockstarLauncher.apply, which writes RDR2's tested settings on its first launch.
        let rdr2HadSettings = FileManager.default.fileExists(atPath: RockstarLauncher.rdr2Settings(prefix: context.location.prefix).path)
        // After the update, which puts Wine's builtin DLLs back in system32.
        if RockstarLauncher.isNeeded(prefix: context.location.prefix) {
            notes += try await RockstarLauncher.apply(in: context, log: paths.logs(for: gameID).appending(path: "rockstar.log"))
        }

        var profile = profile
        var steamWindowCounter: String?
        if Steam.isClient(executable) {
            let root = executable.deletingLastPathComponent()
            // Steam's close button only hides its window; on a Mac nothing shows Steam still runs.
            // Not while Steam bootstraps: it closes its window to restart.
            if let helper = visibleWindowsHelper, steamGame == nil, !profile.arguments.contains("-applaunch"),
               !bottleWasRunning, Steam.isBootstrapped(steamRoot: root) {
                steamWindowCounter = try installVisibleWindowsHelper(helper, prefix: context.location.prefix)
                notes.append("Closing Steam's window quits Steam (on Windows it would keep running in the tray).")
            }
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
        // The desktop the game sees, with the Retina setting the bottle runs with.
        let prefix = context.location.prefix
        if RockstarLauncher.hasRDR2(prefix: prefix),
           let desktop = RetinaMode.desktopSize(enabled: RetinaMode.isEnabled(prefix: prefix)),
           try RockstarLauncher.fitWindow(prefix: prefix, desktop: desktop, anyScreenType: !rdr2HadSettings) {
            notes.append("Sized Red Dead Redemption 2's window to the \(desktop.width)×\(desktop.height) desktop.")
        }
        // After Retina mode, which reads whether the bottle runs: this starts a short Wine session.
        await CrashDialog.turnOff(in: context, log: logs.appending(path: "crash-dialog.log"))
        return Prepared(plan: plan, context: context, log: logs.appending(path: LaunchLogs.fileName(startedAt: startedAt)),
                        inspection: inspection, notes: notes, steamGame: steamGame, steamWindowCounter: steamWindowCounter,
                        steamWebHelperWrapper: Steam.isClient(executable) ? steamWebHelperWrapper : nil)
    }

    /// Copies the helper onto the bottle's own drive, where isolated bottles can run it too, and
    /// returns its Windows path.
    static func installVisibleWindowsHelper(_ helper: URL, prefix: URL) throws -> String {
        let fm = FileManager.default
        let folder = prefix.appending(path: "drive_c/ProgramData/Corkscrew", directoryHint: .isDirectory)
        let target = folder.appending(path: "visible-windows.exe")
        if !fm.contentsEqual(atPath: helper.path, andPath: target.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: helper, to: target)
        }
        return #"C:\ProgramData\Corkscrew\visible-windows.exe"#
    }

    static func steamGameLaunch(executable: URL, arguments: [String], prefix: URL) -> SteamGameLaunch? {
        guard Steam.isClient(executable), let flag = arguments.firstIndex(of: "-applaunch"),
              arguments.indices.contains(flag + 1) else { return nil }
        let appID = arguments[flag + 1]
        guard let app = Steam.installedApps(steamRoot: executable.deletingLastPathComponent(), prefix: prefix)
            .first(where: { $0.appID == appID }) else { return nil }
        return SteamGameLaunch(
            installDir: app.installFolder.lastPathComponent,
            steamWasRunning: BottleProcesses.isSteamRunning(prefix: prefix),
            usesRockstarLauncher: FileManager.default.fileExists(
                atPath: app.installFolder.appending(path: "Redistributables/Rockstar-Games-Launcher.exe").path)
        )
    }

    /// Runs a prepared launch to completion; cancelling stops the bottle's whole session. A Steam
    /// game's launch lasts until the game quits, then closes what it started.
    public static func run(_ prepared: Prepared) async throws -> RunResult {
        let wineserver = prepared.context.engine.wineserver
        if let wrapper = prepared.steamWebHelperWrapper,
           let steam = prepared.plan.arguments.first(where: { $0.lowercased().hasSuffix("steam.exe") }) {
            guardWebHelperWrapper(wrapper, steamRoot: URL(fileURLWithPath: steam).deletingLastPathComponent(),
                                  prefix: prepared.context.location.prefix)
        }
        guard let game = prepared.steamGame else {
            guard let counter = prepared.steamWindowCounter else {
                return try await ProcessRunner.run(prepared.plan, log: prepared.log, wineserver: wineserver)
            }
            async let steam = ProcessRunner.run(prepared.plan, log: prepared.log, wineserver: wineserver)
            if try await waitForSteamToBeClosed(look: { try await lookAtSteam(prepared, counter: counter) }) {
                try await closeSteam(prepared)
            }
            return try await steam
        }
        async let steam = ProcessRunner.run(prepared.plan, log: prepared.log, wineserver: wineserver)
        let prefix = prepared.context.location.prefix
        let started = try await waitForQuit {
            BottleProcesses.list(prefix: prefix).contains { BottleProcesses.isFromSteamGame($0.program, installDir: game.installDir) }
        }
        if started {
            if !game.steamWasRunning {
                try await closeSteam(prepared)
            } else if game.usesRockstarLauncher {
                try await closeRockstarLauncher(prepared)
            }
        }
        return try await steam
    }

    /// Waits for the game's programs to appear and then be gone for `grace`. False when they never
    /// appeared within `timeout` (a launcher error, say): then the launch stays open.
    static func waitForQuit(
        timeout: Duration = gameStartTimeout, grace: Duration = gameQuitGrace, poll: Duration = pollInterval,
        isRunning: () -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var lastSeen: ContinuousClock.Instant?
        while true {
            try await Task.sleep(for: poll)
            if isRunning() {
                lastSeen = clock.now
            } else if let seen = lastSeen {
                if clock.now - seen >= grace { return true }
            } else if clock.now >= deadline {
                return false
            }
        }
    }

    /// What a look at a running Steam finds.
    enum SteamLook: Equatable {
        case notRunning
        /// A window shows, or a game from Steam's library runs.
        case open
        case noWindow
    }

    /// Waits until Steam, after being open, has had no window for `grace` (minimized ones count as
    /// open). False when Steam quits by itself.
    static func waitForSteamToBeClosed(
        grace: Duration = steamClosedGrace, poll: Duration = steamWindowPoll, look: () async throws -> SteamLook
    ) async throws -> Bool {
        let clock = ContinuousClock()
        var lastOpen: ContinuousClock.Instant?
        var missing = 0
        while true {
            try await Task.sleep(for: poll)
            switch try await look() {
            case .notRunning:
                // Twice in a row: Steam restarting itself shows up as one miss.
                missing += 1
                if missing >= 2 { return false }
            case .open:
                missing = 0
                lastOpen = clock.now
            case .noWindow:
                missing = 0
                if let open = lastOpen, clock.now - open >= grace { return true }
            }
        }
    }

    static func lookAtSteam(_ prepared: Prepared, counter: String) async throws -> SteamLook {
        let processes = BottleProcesses.list(prefix: prepared.context.location.prefix)
        guard processes.contains(where: { BottleProcesses.isSteamClient($0.program) }) else { return .notRunning }
        if processes.contains(where: { $0.program.contains("\\steamapps\\common\\") }) { return .open }
        return try await hasWindows(processes, prepared: prepared, counter: counter) ? .open : .noWindow
    }

    /// Whether the bottle shows a window. macOS answers for windows on screen; a minimized window
    /// and one Steam hid look alike there (off screen), so Windows answers for those.
    static func hasWindows(_ processes: [BottleProcesses.Entry], prepared: Prepared, counter: String) async throws -> Bool {
        if BottleProcesses.hasWindowOnScreen(pids: Set(processes.map(\.pid))) { return true }
        let plan = try LaunchPlanner.plan(wineArguments: [counter], in: prepared.context)
        let result = try await ProcessRunner.run(plan, log: prepared.log.deletingLastPathComponent().appending(path: "steam-windows.log"),
                                                 wineserver: prepared.context.engine.wineserver)
        // A failed count (exit codes other than the number of windows can't be told apart from
        // it) must never close Steam: only an exit with 0 windows does.
        return result.crashed || result.status != 0
    }

    /// Asks Steam to quit (so it saves its state), then stops the rest of the bottle: the Rockstar
    /// Games Launcher and its helpers, which would keep running.
    static func closeSteam(_ prepared: Prepared) async throws {
        let steam = prepared.plan.arguments.first { $0.lowercased().hasSuffix("steam.exe") } ?? "steam.exe"
        try await closeSteam(steam, context: prepared.context,
                             log: prepared.log.deletingLastPathComponent().appending(path: "steam-shutdown.log"))
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
        let plan = try LaunchPlanner.plan(wineArguments: [steam, "-shutdown"], in: context)
        _ = try await ProcessRunner.run(plan, log: log, wineserver: context.engine.wineserver)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while clock.now < deadline, BottleProcesses.isSteamRunning(prefix: context.location.prefix) {
            try await Task.sleep(for: pollInterval)
        }
        ProcessRunner.stopSession(environment: plan.environment, wineserver: context.engine.wineserver)
    }

    /// Closes the Rockstar Games Launcher while Steam keeps running. `taskkill /f` ends it without
    /// signing out; a normal quit signs out on Rockstar's side, which breaks auto sign-in.
    static func closeRockstarLauncher(_ prepared: Prepared) async throws {
        let plan = try LaunchPlanner.plan(
            wineArguments: ["taskkill", "/f", "/im", "Launcher.exe", "/im", "SocialClubHelper.exe"], in: prepared.context)
        _ = try await ProcessRunner.run(plan, log: prepared.log.deletingLastPathComponent().appending(path: "rockstar-close.log"),
                                        wineserver: prepared.context.engine.wineserver)
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
