import AppKit
import CryptoKit
import Foundation
import GameCore
import Observation

/// The app's state: library, bottles, runtimes and running launches. Everything slow (Wine setup,
/// disk images, clones) runs off the main thread; the model only records what happened.
@Observable
final class AppModel {
    static let shared = AppModel()

    /// One launch of a game (or a "Run once" program) and how it's going.
    struct Session {
        enum Status: Equatable {
            case preparing
            case running
            case exited(Int32)
            case stopped
            case failed(String)
        }

        var game: Game
        var status: Status = .preparing
        var log: URL?
        var notes: [String] = []
        var task: Task<Void, Never>?
        /// Not in the library: started with "Run once".
        var isTransient: Bool

        var isActive: Bool { status == .preparing || status == .running }
    }

    let paths: AppPaths
    private(set) var library = Library() { didSet { listsChanged() } }
    var games: [Game] { library.games }
    private(set) var bottles: [Bottle] = [] { didSet { listsChanged() } }
    private(set) var runtimes: [RuntimeManifest] = []
    private(set) var components: [String] = []
    /// Bottles whose wineserver is up, refreshed every couple of seconds.
    private(set) var runningBottles: Set<UUID> = [] { didSet { listsChanged() } }
    /// Steam games' install states by `Game.storeKey`; nil until the first scan.
    private(set) var storeStates: [String: Steam.InstallState]? { didSet { listsChanged() } }
    private(set) var sessions: [UUID: Session] = [:]

    /// Work a button started that hasn't shown its result yet: the button says so and can't be
    /// pressed again until it has.
    enum Pending: Hashable {
        /// Play or Run: until the game's window shows.
        case launch(Game.ID)
        /// Open Steam, in the launcher bottle: until Steam's window shows.
        case openSteam
        /// Open in Steam (a game's store page): until Steam shows it.
        case steamPage(Game.ID)
        case stop(Game.ID)
        /// Quit Steam, in the launcher bottle.
        case quitSteam
        case stopBottle(Bottle.ID)
        case resetBottle(Bottle.ID)
        case deleteBottle(Bottle.ID)
        case createBottle
        case importBottle
        case addRuntime
        case addComponents
        case importToolkit
        case uninstall
        case update
    }

    private(set) var pending: Set<Pending> = []
    /// Bottles where Steam's client runs, refreshed with `runningBottles`.
    private(set) var steamRunning: Set<Bottle.ID> = []
    /// `Game.storeKey`s of Steam games with a program running: started here or from Steam's window.
    private(set) var runningSteamApps: Set<String> = []
    func isPending(_ action: Pending) -> Bool { pending.contains(action) }

    /// A program for the Add Program sheet: opened from Finder or dropped on the window, or nil
    /// from Add Program, where the sheet asks for the file.
    struct OpenRequest: Identifiable, Equatable {
        let id = UUID()
        let program: URL?
        /// The bottle to offer first: the page Add Program was clicked on, or the program was dropped on.
        let bottleID: Bottle.ID?
    }

    /// Add Program sheets waiting their turn, one at a time.
    var openRequests: [OpenRequest] = []
    /// Games installed from downloads (zip, rar, 7z, disc images), one at a time.
    @ObservationIgnored private(set) lazy var installer = ProgramInstaller(model: self)
    /// What the app is busy with (shown at the bottom of the window), nil when idle.
    private(set) var activity: String?
    /// Everything `perform` is running, oldest first; `activity` shows the newest.
    @ObservationIgnored private var activities: [(id: UUID, title: String)] = []
    var errorMessage: String?

    /// Whether x86_64 programs run; the Wine runtime needs Rosetta.
    private(set) var hasRosetta = true
    /// The engine pack's download or unpack, while one runs.
    private(set) var enginePackProgress: EnginePackProgress?
    /// The one-click setup (`setUp()`), while it runs.
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    private(set) var isSettingUp = false
    /// The step setup works on. Its files appear before it ends (the runtime before the components,
    /// steam.exe before Steam's update, bottle.json before Windows is set up), so it isn't done yet.
    private(set) var setupStep: SetupStep?
    /// The step the last setup stopped at with an error (not when cancelled); cleared when setup starts again.
    private(set) var setupFailure: SetupStep?

    /// The one-click setup's progress over all its steps (0…1): steps that ended, plus how far the
    /// engine pack is inside its step. Nil when setup doesn't run.
    var setupProgress: Double? {
        guard let step = setupStep, let index = SetupStep.allCases.firstIndex(of: step) else { return nil }
        let inside = step == .engine ? enginePackProgress?.overall ?? 0 : 0
        return (Double(index) + inside) / Double(SetupStep.allCases.count)
    }
    /// While a new engine pack replaces the runtime, games must not start.
    @ObservationIgnored private var isInstallingEngine = false

    /// A newer Corkscrew, found at launch; nil when this one is the newest or the check failed.
    private(set) var availableUpdate: AppUpdate?
    /// What updating downloads: the app, plus the engine pack when the new version pins a newer one.
    private(set) var updateSize: Int64 = 0
    /// The update's download (0…1), while it runs.
    private(set) var updateProgress: Double?
    /// "Later": the update bar stays hidden until the next launch.
    var isUpdateDismissed = false

    /// Programs can run: Rosetta, a runtime and the Steam bottle are there.
    var isSetUp: Bool { hasRosetta && !runtimes.isEmpty && launcherBottle != nil }
    /// Everything setup makes is there: also Steam and the two sandboxes.
    var isReady: Bool { isSetUp && hasSteam && hasDefaultBottles }
    var hasDefaultBottles: Bool { Bottle.Role.allCases.allSatisfy { bottle(role: $0) != nil } }

    /// The ready-made bottle with that role, if it's there.
    func bottle(role: Bottle.Role) -> Bottle? { bottles.first { $0.role == role } }
    /// The Steam bottle: Steam and the games in its library, nothing else.
    var launcherBottle: Bottle? { bottle(role: .steam) }
    /// Whether the Steam bottle has Steam (other bottles may have their own).
    var hasSteam: Bool { launcherBottle.map(hasSteam(in:)) ?? false }

    /// The account signed in to Steam in the Steam bottle and the games in its library, as Steam's
    /// files have them; nil until the first scan, or without Steam.
    nonisolated struct SteamLibrary: Equatable, Sendable {
        var account: Steam.Account?
        /// Every game in the library, installed or not, as entries that start it through Steam.
        var games: [Game]
    }
    private(set) var steamLibrary: SteamLibrary? { didSet { listsChanged() } }

    /// Steam has an account that's signed in now: Steam runs, or signs in by itself when it starts.
    var steamAccount: Steam.Account? {
        guard let account = steamLibrary?.account, let launcher = launcherBottle else { return nil }
        return account.remembersSignIn || runningBottles.contains(launcher.id) ? account : nil
    }

    /// The Steam page's games: the account's library, with the library entries (and their settings)
    /// for games that have one, and installed games Steam hasn't listed yet. Not other entries, such
    /// as tested games the account doesn't own.
    var steamGames: [Game] { lists.steam }

    /// The Library page: the signed-in account's Steam games and every program in another bottle,
    /// without the launchers themselves.
    var allGames: [Game] { lists.all }

    /// Bumped when something the game lists come from changes; the lists are sorted again on the
    /// next read after that, not on every read (each view body reads them).
    private var listsVersion = 0
    @ObservationIgnored private var listCache: (version: Int, steam: [Game], all: [Game])?

    private func listsChanged() { listsVersion &+= 1 }

    private var lists: (steam: [Game], all: [Game]) {
        if let listCache, listCache.version == listsVersion { return (listCache.steam, listCache.all) }
        let steam = makeSteamGames()
        let others = games.filter { $0.bottleID != launcherBottle?.id }
        let all = ((steamAccount == nil ? [] : steam) + others)
            .filter { !($0.store != nil && $0.store?.appID == nil) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        listCache = (listsVersion, steam, all)
        return (steam, all)
    }

    private func makeSteamGames() -> [Game] {
        guard let launcher = launcherBottle else { return [] }
        let owned = steamLibrary?.games ?? []
        let ownedIDs = Set(owned.compactMap(\.store?.appID))
        let entries = games.filter { game in
            guard game.bottleID == launcher.id, game.store?.store == Steam.store, let appID = game.store?.appID else { return false }
            return ownedIDs.contains(appID) || installState(of: game) != .notInstalled
        }
        let listed = Set(entries.compactMap(\.storeKey))
        return (entries + owned.filter { !listed.contains($0.storeKey ?? "") })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Steam itself, in the Steam bottle.
    var steamClient: Game? {
        guard let launcher = launcherBottle else { return nil }
        return games.first { $0.bottleID == launcher.id && $0.store == StoreItem(store: Steam.store) }
    }
    /// Bottles Steam is being installed into.
    private(set) var steamInstalls: Set<UUID> = []

    init(paths: AppPaths = AppModel.configuredPaths) {
        self.paths = paths
        // Before the library reads it.
        updateTestedList()
        reload()
        if runningBottles.isEmpty { unregisterLoaderBundles() }
        removeInstallLeftovers()
        sweepWineLeftovers(in: bottles.filter { !runningBottles.contains($0.id) }, removeServerFolders: true)
        Task { await setUpAutomatically() }
        Task { [weak self] in
            var tick = 0
            while let self {
                self.refreshRunningBottles()
                await self.refreshRunningPrograms()
                self.updateWhilePlaying()
                // While Steam may be installing or uninstalling games, look at its manifests now and then
                // (not while a game runs: Steam doesn't download then, and the game needs the Mac).
                tick += 1
                if tick % 15 == 0, !self.runningBottles.isEmpty, !self.isGameRunning { self.syncStores() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Back from Steam (or Finder): pick up games installed or uninstalled meanwhile.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncStores()
                self?.updateBackupExclusions()
            }
        }
        updateBackupExclusions()
        trimCaches()
        countFirstLaunch()
        offerAppCrashReport()
        checkForUpdate()
    }

    /// `~/Library/…/Corkscrew`, or one folder for everything when the `DataRoot` default is set
    /// (`defaults write io.github.prateek-srivastav.Corkscrew DataRoot <folder>`, or `-DataRoot <folder>` at launch),
    /// e.g. the CLI's `build/dev-data`.
    static var configuredPaths: AppPaths {
        guard let root = UserDefaults.standard.string(forKey: "DataRoot"), !root.isEmpty else { return .standard }
        return .rooted(at: URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true))
    }

    /// What a reload reads again: everything, or (after adding a runtime, components or Rosetta)
    /// only the setup, without the library, the bottles and a store sync.
    enum Reload { case all, setup }

    /// Reads the app's state from disk again. A value that is the same isn't set again, so views
    /// that show it aren't drawn again.
    func reload(_ scope: Reload = .all) {
        if scope == .all {
            do {
                let library = try LibraryStore(paths: paths).load()
                if library != self.library { self.library = library }
                let bottles = try BottleStore(paths: paths).list()
                if bottles != self.bottles { self.bottles = bottles }
                try adoptRoleBottles()
            } catch {
                errorMessage = Self.describe(error)
            }
        }
        let hasRosetta = Rosetta.isInstalled
        if hasRosetta != self.hasRosetta { self.hasRosetta = hasRosetta }
        let runtimes = RuntimeStore(paths: paths).list()
        if runtimes != self.runtimes { self.runtimes = runtimes }
        let components = ComponentCatalog.staged(in: paths.components)
        if components != self.components { self.components = components }
        guard scope == .all else { return }
        refreshRunningBottles()
        syncStores()
    }

    // MARK: Automatic setup

    /// First run without clicks: in a development checkout the app finds the runtime and components
    /// the scripts built (`<repo>/build/runtime`, `build/components`) and adds them as APFS clones,
    /// then creates the ready-made bottles that are missing.
    private func setUpAutomatically() async {
        let paths = self.paths
        if let build = Self.developmentBuildFolder() {
            let installed = Set(runtimes.map(\.id))
            let runtimeFolders = ((try? FileManager.default.contentsOfDirectory(at: build.appending(path: "runtime"), includingPropertiesForKeys: nil)) ?? [])
                .filter { (try? RuntimeStore.manifest(in: $0)).map { !installed.contains($0.id) } ?? false }
            let components = build.appending(path: "components", directoryHint: .isDirectory)
            let newComponents = ComponentCatalog.staged(in: components).filter { !self.components.contains($0) }
            if !runtimeFolders.isEmpty || !newComponents.isEmpty {
                await perform("Adding the Wine runtime and graphics components from \(build.path)…", reloading: .setup) {
                    for folder in runtimeFolders { try RuntimeStore(paths: paths).install(directory: folder) }
                    try ComponentCatalog.importComponents(from: components, into: paths.components)
                }
            }
        }
        if !runtimes.isEmpty, hasRosetta { await createDefaultBottles() }
        upgradeEngineIfNeeded()
    }

    /// Replaces a runtime from an older engine pack with `EnginePack.current`, e.g. a fixed build of
    /// the same Wine. Runs at launch, in the background; with a bottle running it waits for a later launch.
    private func upgradeEngineIfNeeded() {
        guard setupTask == nil, Self.enginePack.upgradesInstalledRuntime(in: paths), runningBottles.isEmpty else { return }
        isSettingUp = true
        setupTask = Task {
            defer {
                setupTask = nil
                isSettingUp = false
                setupStep = nil
            }
            await installEnginePack()
        }
    }

    /// Creates the ready-made bottles that aren't there yet, one at a time (each takes a minute), and
    /// returns whether all of `roles` are there now. Calls made meanwhile wait their turn.
    @ObservationIgnored private var defaultBottlesTask: Task<Bool, Never>?

    @discardableResult
    private func createDefaultBottles(_ roles: [Bottle.Role] = Bottle.Role.allCases) async -> Bool {
        let previous = defaultBottlesTask
        let task = Task {
            _ = await previous?.value
            for role in roles where bottle(role: role) == nil {
                if (try? adoptRoleBottles()) != nil, bottle(role: role) != nil { continue }
                guard await createBottleNow(name: role.defaultName, kind: role.kind, allowNetwork: role.isolation.allowNetwork, role: role) != nil
                else { return false }
            }
            return true
        }
        defaultBottlesTask = task
        return await task.value
    }

    /// Gives each missing role to a bottle the user already has, so setup doesn't make a second one:
    /// for Steam a standard bottle named "Games" (what setups before roles made), for the two
    /// protected ones an isolated bottle with the same internet setting (the one with the most
    /// programs). Role bottles that still have a former default name get the current one.
    private func adoptRoleBottles() throws {
        let store = BottleStore(paths: paths)
        for role in Bottle.Role.allCases where bottle(role: role) == nil {
            let candidates = bottles.indices.filter { index in
                let bottle = bottles[index]
                guard bottle.role == nil, bottle.kind == role.kind else { return false }
                if role == .steam { return bottle.name.caseInsensitiveCompare("Games") == .orderedSame }
                return bottle.isolation.allowNetwork == role.isolation.allowNetwork
            }
            let programs = { (index: Int) in self.games.count { $0.bottleID == self.bottles[index].id } }
            guard let index = candidates.max(by: { programs($0) < programs($1) }) else { continue }
            bottles[index].role = role
            bottles[index].name = role.defaultName
            try store.save(bottles[index])
        }
        for index in bottles.indices {
            guard let role = bottles[index].role, bottles[index].name != role.defaultName,
                  role.formerNames.contains(where: { bottles[index].name.caseInsensitiveCompare($0) == .orderedSame })
            else { continue }
            bottles[index].name = role.defaultName
            try store.save(bottles[index])
        }
    }

    /// `<repo>/build` when the app runs from a checkout that has built the runtime (the app itself is
    /// built into `build/DerivedData`, possibly inside a worktree of the repo).
    private static func developmentBuildFolder() -> URL? {
        var folder = Bundle.main.bundleURL.deletingLastPathComponent()
        while folder.path != "/" {
            let build = folder.appending(path: "build", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: build.appending(path: "runtime").path) { return build }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: Stores

    @ObservationIgnored private var isSyncingStores = false
    @ObservationIgnored private var storesChangedWhileSyncing = false

    /// Adds Steam, and the games installed through it, from every bottle: with the tested settings,
    /// or the backend detected from each game. Entries the user removed stay removed. Uninstalled
    /// games stay too, with their settings, shown as not downloaded. Also reads the Steam bottle's
    /// account and library (`steamLibrary`).
    private func syncStores() {
        guard !isSyncingStores else {
            storesChangedWhileSyncing = true
            return
        }
        isSyncingStores = true
        let paths = self.paths
        let bottles = self.bottles
        let known = Set(library.games.compactMap(\.storeKey)).union(library.removedStoreItems)
        let launcher = launcherBottle
        Task {
            let (found, states, programs, steamLibrary) = await Task.detached(priority: .utility) {
                var found: [Game] = []
                var states: [String: Steam.InstallState] = [:]
                var programs: [String: URL] = [:]
                var steamLibrary: SteamLibrary?
                for bottle in bottles {
                    let prefix = BottleLocation(bottleID: bottle.id, paths: paths).prefix
                    found += Steam.libraryEntries(for: bottle, prefix: prefix, excluding: known)
                    states.merge(Steam.installStates(for: bottle, prefix: prefix)) { $1 }
                    for (appID, program) in Steam.installedPrograms(prefix: prefix) {
                        programs[StoreItem(store: Steam.store, appID: appID).key(in: bottle.id)] = program
                    }
                    if bottle.id == launcher?.id, let root = Steam.root(inPrefix: prefix) {
                        let games = Steam.libraryGames(steamRoot: root).map { owned in
                            var game = Steam.entry(appID: owned.appID, name: owned.name, bottleID: bottle.id, steamRoot: root)
                            // The same id every scan, so the page keeps its selection.
                            game.id = Self.stableID(for: game.storeKey!)
                            return game
                        }
                        steamLibrary = SteamLibrary(account: Steam.account(steamRoot: root), games: games)
                    }
                }
                return (found, states, programs, steamLibrary)
            }.value
            isSyncingStores = false
            if storeStates != states { storeStates = states }
            if self.steamLibrary != steamLibrary { self.steamLibrary = steamLibrary }
            var changed = !library.addMissing(found).isEmpty
            // Games listed before they were downloaded get their own icon once they're installed.
            for index in library.games.indices where library.games[index].iconSource == nil {
                guard let key = library.games[index].storeKey, let program = programs[key] else { continue }
                library.games[index].iconSource = program
                LibraryStore(paths: paths).removeCachedIcon(for: library.games[index])
                icons[library.games[index].id] = nil
                changed = true
            }
            if changed { saveLibrary() }
            if storesChangedWhileSyncing {
                storesChangedWhileSyncing = false
                syncStores()
            }
        }
    }

    /// A UUID made from `key` (MD5, as in name-based UUIDs).
    nonisolated private static func stableID(for key: String) -> UUID {
        var bytes = Array(Insecure.MD5.hash(data: Data(key.utf8)))
        bytes[6] = bytes[6] & 0x0F | 0x30
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func refreshRunningBottles() {
        let running = Set(bottles.filter { Launcher.isRunning($0, paths: paths) }.map(\.id))
        guard running != runningBottles else { return }
        let stopped = runningBottles.subtracting(running)
        runningBottles = running
        if !stopped.isEmpty {
            Task { [weak self] in
                // Programs a session leaves behind outlive their server by a moment while they exit.
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                sweepWineLeftovers(in: bottles.filter { stopped.contains($0.id) && !runningBottles.contains($0.id) && !hasActiveSession(in: $0.id) })
            }
        }
        if running.isEmpty { unregisterLoaderBundles() }
        syncStores()
    }

    /// Whether a game runs: a session other than a launcher's, or a Steam game started from Steam.
    private var isGameRunning: Bool {
        !runningSteamApps.isEmpty || sessions.values.contains { $0.isActive && !Steam.isClient($0.game.executable) }
    }

    /// Settings → "While you play": Steam and Rockstar's launcher at background priority during a game.
    static let lowersLaunchersKey = "LowerLaunchersDuringGames"
    /// Settings → "While you play": installed games left out of Time Machine backups.
    static let excludesGamesFromBackupsKey = "ExcludeGamesFromBackups"
    /// Settings → "Privacy": anonymous usage counts (`Analytics`). On until turned off there, or by
    /// install.sh with DO_NOT_TRACK.
    static let sendsUsageCountsKey = "SendsUsageCounts"
    static var sendsUsageCounts: Bool { UserDefaults.standard.object(forKey: sendsUsageCountsKey) as? Bool ?? true }

    @ObservationIgnored private var wasGameRunning = false
    @ObservationIgnored private var loweredPrograms: Set<pid_t> = []

    /// Gives the Mac to a game while one runs: drops decoded art, and (when set) lowers the
    /// launchers once the game is up. Puts the launchers back after.
    private func updateWhilePlaying() {
        let playing = isGameRunning
        if playing != wasGameRunning {
            wasGameRunning = playing
            if playing { SteamArtwork.purge() }
        }
        // Not while a launch is pending: a game may wait on Steam as it starts.
        if playing, pending.isEmpty, UserDefaults.standard.bool(forKey: Self.lowersLaunchersKey) {
            let games = Set(sessions.values.filter { $0.isActive && !Steam.isClient($0.game.executable) }
                .map { $0.game.executable.lastPathComponent.lowercased() })
            for bottle in bottles where runningBottles.contains(bottle.id) {
                loweredPrograms.formUnion(BackgroundPrograms.lower(prefix: BottleLocation(bottleID: bottle.id, paths: paths).prefix, sparing: games))
            }
        } else if !playing || !UserDefaults.standard.bool(forKey: Self.lowersLaunchersKey) {
            restoreLaunchers()
        }
    }

    /// Normal priority again for the launchers lowered during a game (also when the app quits).
    func restoreLaunchers() {
        guard !loweredPrograms.isEmpty else { return }
        BackgroundPrograms.restore(loweredPrograms)
        loweredPrograms = []
    }

    /// Applies the backup setting to every bottle's game folders (new installs included).
    func updateBackupExclusions() {
        let excluded = UserDefaults.standard.bool(forKey: Self.excludesGamesFromBackupsKey)
        let prefixes = bottles.map { BottleLocation(bottleID: $0.id, paths: paths).prefix }
        Task.detached(priority: .background) {
            for prefix in prefixes { BackupExclusion.apply(excluded, prefix: prefix) }
        }
    }

    /// A session runs in the bottle, or any action is under way (a launch starts its programs a moment
    /// before their server).
    private func hasActiveSession(in bottleID: Bottle.ID) -> Bool {
        !pending.isEmpty || sessions.values.contains { $0.isActive && $0.game.bottleID == bottleID }
    }

    /// Stops programs left running in stopped bottles without their wineserver, and (at start)
    /// removes the folders of servers that died.
    private func sweepWineLeftovers(in bottles: [Bottle], removeServerFolders: Bool = false) {
        let prefixes = bottles.map { BottleLocation(bottleID: $0.id, paths: paths).prefix }
        let base = paths.wineServerDirectory
        Task.detached(priority: .background) {
            for prefix in prefixes {
                let stopped = await WineServer.stopOrphans(prefix: prefix, base: base)
                if !stopped.isEmpty { print("Stopped \(stopped.count) leftover Wine programs in \(prefix.path): \(stopped)") }
            }
            if removeServerFolders { WineServer.removeStaleDirectories(base: base) }
        }
    }

    /// Which running bottles have Steam open, and which Steam games run (off the main thread: it
    /// reads every process's environment).
    private func refreshRunningPrograms() async {
        let prefixes = bottles.filter { runningBottles.contains($0.id) }
            .map { ($0.id, BottleLocation(bottleID: $0.id, paths: paths).prefix) }
        let found = await Task.detached(priority: .utility) {
            prefixes.map { id, prefix in
                let processes = BottleProcesses.list(prefix: prefix)
                return (id, processes.contains { $0.isSteamClient }, Steam.runningApps(prefix: prefix, processes: processes).keys
                    .map { StoreItem(store: Steam.store, appID: $0).key(in: id) })
            }
        }.value
        let steam = Set(found.filter(\.1).map(\.0))
        let apps = Set(found.flatMap(\.2))
        if steam != steamRunning { steamRunning = steam }
        if apps != runningSteamApps { runningSteamApps = apps }
    }

    /// Whether the game runs: launched here, or (a Steam game) from Steam's own window.
    func isRunning(_ game: Game) -> Bool {
        sessions[game.id]?.isActive == true || game.storeKey.map(runningSteamApps.contains) == true
    }

    /// The bundles games run from (for Game Mode) are recorded as installed games while they run;
    /// once nothing runs, they're taken out of LaunchServices again.
    private func unregisterLoaderBundles() {
        let prebuilt = paths.gameModeBundles
        Task.detached(priority: .utility) { LoaderBundles.unregisterAll(prebuilt: prebuilt) }
    }

    // MARK: Library

    func bottle(for game: Game) -> Bottle? { bottles.first { $0.id == game.bottleID } }

    /// Installed, unless it's a Steam game Steam no longer has (or is still downloading). Programs
    /// added by hand, and everything before the first scan, count as installed.
    func installState(of game: Game) -> Steam.InstallState {
        guard game.store?.appID != nil, let key = game.storeKey, let storeStates else { return .installed }
        return storeStates[key] ?? .notInstalled
    }

    /// Icons by game, with the modification date of the program they came from: an updated or
    /// replaced program gets its new icon.
    @ObservationIgnored private var icons: [UUID: (image: NSImage?, modified: Date?)] = [:]

    /// The icon read before, without touching the disk; nil before the first `loadIcon`.
    func cachedIcon(for game: Game) -> NSImage? { icons[game.id]?.image }

    /// Reads the game's icon off the main thread (a program's icon is extracted from its file the
    /// first time), and again once the program has changed.
    func loadIcon(for game: Game) async -> NSImage? {
        let paths = self.paths
        let known = icons[game.id]
        let knownModified = known.map { $0.modified }
        let (modified, data) = await Task.detached(priority: .utility) { () -> (Date?, Data?) in
            let source = game.iconSource ?? game.executable
            let modified = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date
            if let knownModified, knownModified == modified { return (modified, nil) }
            return (modified, LibraryStore(paths: paths).icon(for: game))
        }.value
        if let known, known.modified == modified { return known.image }
        let image = data.flatMap(NSImage.init(data:))
        icons[game.id] = (image, modified)
        return image
    }

    func update(_ game: Game) {
        guard let index = library.games.firstIndex(where: { $0.id == game.id }), library.games[index] != game else { return }
        library.games[index] = game
        saveLibrary()
    }

    /// Takes the game out of the library; Steam entries aren't added back.
    func remove(_ game: Game) {
        library.remove(game.id)
        LibraryStore(paths: paths).removeCachedIcon(for: game)
        saveLibrary()
    }

    private func saveLibrary() {
        do { try LibraryStore(paths: paths).save(library) } catch { errorMessage = Self.describe(error) }
    }

    // MARK: Opening programs

    /// Asks whether to run each program once or add it to the library; `bottle` is offered first.
    /// Downloads (archives, disc images) go to the installer.
    func open(_ urls: [URL], in bottle: Bottle? = nil) {
        let files = urls.filter(\.isFileURL)
        for url in urls where url.scheme == "corkscrew" { handleLink(url) }
        let downloads = files.filter(Archive.isArchive)
        if !downloads.isEmpty { installer.enqueue(downloads, bottle: bottle?.role == .steam ? nil : bottle) }
        let programs = files.filter { ["exe", "msi"].contains($0.pathExtension.lowercased()) }
        if programs.count + downloads.count < files.count {
            errorMessage = "Only Windows programs (.exe), installers (.msi), archives (.zip, .rar, .7z) and disc images (.iso) can be opened."
        }
        for program in programs where !openRequests.contains(where: { $0.program == program }) {
            openRequests.append(OpenRequest(program: program, bottleID: bottle?.role == .steam ? nil : bottle?.id))
        }
    }

    /// Add Program: the sheet asks where the program goes and for its file. `bottle`, the page it was
    /// clicked on, is selected first.
    func addProgram(in bottle: Bottle? = nil) {
        guard !openRequests.contains(where: { $0.program == nil }) else { return }
        openRequests.append(OpenRequest(program: nil, bottleID: bottle?.role == .steam ? nil : bottle?.id))
    }

    /// The bottle the Add Program sheet selects first.
    func openBottle(for request: OpenRequest) -> Bottle? {
        programBottles.first { $0.id == request.bottleID } ?? suggestedBottle(for: request.program)
    }

    func closeOpenRequest(_ request: OpenRequest) {
        openRequests.removeAll { $0.id == request.id }
    }

    /// `corkscrew://launch/<game id>` and `corkscrew://stop/<game id>`, for shortcuts and scripts.
    private func handleLink(_ url: URL) {
        guard let id = UUID(uuidString: url.lastPathComponent), let game = games.first(where: { $0.id == id }) else {
            errorMessage = "No game in the library matches \(url.absoluteString)."
            return
        }
        switch url.host() {
        case "launch": play(game)
        case "stop": stop(game)
        default: errorMessage = "Unknown link \(url.absoluteString)."
        }
    }

    /// The bottle a program already lives in, if it's inside one.
    func bottle(containing program: URL) -> Bottle? {
        let path = program.standardizedFileURL.resolvingSymlinksInPath().path
        return bottles.first { bottle in
            let prefix = BottleLocation(bottleID: bottle.id, paths: paths).prefix.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix(prefix + "/")
        }
    }

    /// Where a new program goes unless the user picks another bottle: the bottle it's already in,
    /// otherwise the offline sandbox. Never the Steam bottle, which only has Steam's games.
    func suggestedBottle(for program: URL?) -> Bottle? {
        let bottles = programBottles
        return program.flatMap(bottle(containing:)).flatMap { found in bottles.first { $0.id == found.id } }
            ?? bottles.first { $0.role == .sandbox }
            ?? bottles.first
    }

    /// The bottles programs can be opened in: all but the Steam bottle.
    var programBottles: [Bottle] { bottles.filter { $0.role != .steam } }

    /// Whether running `program` in `bottle` needs a copy inside it first (isolated bottles only see their own drive).
    func needsImport(_ program: URL, into bottle: Bottle) -> Bool {
        bottle.kind == .isolated && self.bottle(containing: program)?.id != bottle.id
    }

    /// Adds the program to the library (copying it into an isolated bottle first) and returns it.
    @discardableResult
    func addToLibrary(_ program: URL, bottle: Bottle, name: String? = nil) async -> Game? {
        guard let executable = await prepareProgram(program, for: bottle) else { return nil }
        let game = Game(name: name ?? Game.defaultName(for: executable), executable: executable, bottleID: bottle.id)
        library.games.append(game)
        saveLibrary()
        return game
    }

    /// Runs the program without adding it to the library.
    func runOnce(_ program: URL, bottle: Bottle) async {
        guard let executable = await prepareProgram(program, for: bottle) else { return }
        let game = Game(name: executable.deletingPathExtension().lastPathComponent, executable: executable, bottleID: bottle.id)
        play(game, transient: true)
    }

    /// Runs a setup from a download in the bottle, without adding it to the library; the session
    /// under the returned entry's id follows it.
    func runSetup(_ setup: URL, in bottle: Bottle, name: String) -> Game {
        let game = Game(name: name, executable: setup, bottleID: bottle.id)
        start(game, transient: true)
        return game
    }

    /// Discs and setup files an install left in the bottles when the app quit during it.
    private func removeInstallLeftovers() {
        let prefixes = bottles.map { BottleLocation(bottleID: $0.id, paths: paths).prefix }
        Task.detached(priority: .utility) {
            for prefix in prefixes {
                DiscImage.detachAll(prefix: prefix)
                SetupFinder.removeLeftovers(prefix: prefix)
            }
        }
    }

    private func prepareProgram(_ program: URL, for bottle: Bottle) async -> URL? {
        guard needsImport(program, into: bottle) else { return program }
        let paths = self.paths
        return await perform("Copying \(program.lastPathComponent) into \(bottle.name)…") {
            try BottleStore(paths: paths).importProgram(program, into: bottle)
        }
    }

    // MARK: Launching

    func session(for game: Game) -> Session? { sessions[game.id] }

    /// A game in the library, the Steam library or running once.
    func game(id: Game.ID) -> Game? {
        games.first { $0.id == id } ?? steamGames.first { $0.id == id } ?? sessions[id]?.game
    }

    /// Running "Run once" programs, newest first.
    var transientSessions: [Session] {
        sessions.values.filter { $0.isTransient && $0.isActive }.sorted { $0.game.addedAt > $1.game.addedAt }
    }

    /// Starts the game; a Steam game that isn't downloaded opens its Steam page instead.
    func play(_ game: Game, transient: Bool = false) {
        guard sessions[game.id]?.isActive != true, !isPending(.launch(game.id)) else { return }
        if installState(of: game) != .installed {
            openInSteam(game)
            return
        }
        if !transient {
            var played = game
            played.lastPlayedAt = .now
            update(played)
        }
        start(game, transient: transient)
        pend(.launch(game.id), untilWindowIn: game.bottleID) { [weak self] in self?.sessions[game.id]?.isActive != true }
    }

    /// Opens Steam in the Steam bottle, to sign in or manage the library. When Steam already runs
    /// (its window closed, or behind others), a second `steam.exe` brings its window up.
    func openSteam() {
        guard !isPending(.openSteam), let launcher = launcherBottle,
              let root = Steam.root(inPrefix: BottleLocation(bottleID: launcher.id, paths: paths).prefix) else { return }
        // The user may have taken Steam out of the library; it's still there.
        let steam = steamClient ?? Game(name: "Steam", executable: root.appending(path: "steam.exe"), bottleID: launcher.id,
                                        profile: Steam.clientProfile, store: StoreItem(store: Steam.store))
        if sessions[steam.id]?.isActive == true || isSteamRunning(in: launcher) {
            let ended = forward(steam)
            pend(.openSteam, untilWindowIn: launcher.id, of: \.isSteamWebHelper, timeout: .seconds(30)) { ended.isSet }
        } else {
            play(steam, transient: steamClient == nil)
            // Steam's updater window shows first; Steam is open when its own window does.
            pend(.openSteam, untilWindowIn: launcher.id, of: \.isSteamWebHelper) { [weak self] in self?.sessions[steam.id]?.isActive != true }
        }
    }

    /// Opens a Steam game's store page in Steam, to download it (again). Steam starts as its library
    /// entry, with its own settings; when Steam already runs, the link goes to the Steam there.
    func openInSteam(_ game: Game) {
        guard let appID = game.store?.appID, !isPending(.steamPage(game.id)), let bottle = bottle(for: game) else { return }
        let entry = games.first { $0.bottleID == game.bottleID && $0.store == StoreItem(store: Steam.store) }
        var steam = entry ?? Game(name: "Steam", executable: game.executable, bottleID: game.bottleID,
                                  profile: Steam.clientProfile, store: StoreItem(store: Steam.store))
        steam.profile.arguments = Steam.storePageArguments(appID: appID)
        if sessions[steam.id]?.isActive == true || isSteamRunning(in: bottle) {
            // This steam.exe only hands the link over.
            let ended = forward(steam)
            pend(.steamPage(game.id), untilWindowIn: game.bottleID, of: \.isSteamWebHelper, timeout: .seconds(30)) { ended.isSet }
        } else {
            start(steam, transient: entry == nil)
            pend(.steamPage(game.id), untilWindowIn: game.bottleID, of: \.isSteamWebHelper) { [weak self] in
                self?.sessions[steam.id]?.isActive != true
            }
        }
    }

    private func isSteamRunning(in bottle: Bottle) -> Bool {
        BottleProcesses.isSteamRunning(prefix: BottleLocation(bottleID: bottle.id, paths: paths).prefix)
    }

    func start(_ game: Game, transient: Bool) {
        guard !isInstallingEngine else {
            errorMessage = "Corkscrew is updating Wine. Try again in a minute."
            return
        }
        guard let bottle = bottle(for: game) else {
            errorMessage = "\(game.name)'s bottle is gone. Add the program again to pick another one."
            return
        }
        let paths = self.paths
        let steamWasRunning = game.store?.appID != nil && runningBottles.contains(bottle.id)
        sessions[game.id] = Session(game: game, isTransient: transient)
        sessions[game.id]?.task = Task { [weak self] in
            do {
                guard let engine = try RuntimeStore(paths: paths).engine(id: bottle.engineID) else {
                    throw AppError("No Wine runtime is installed. Add one in Settings.")
                }
                let prepared = try await Launcher.prepare(gameID: game.id, executable: game.executable, profile: game.profile,
                                                          bottle: bottle, engine: engine, paths: paths,
                                                          steamWebHelperWrapper: Self.steamWebHelperWrapper,
                                                          visibleWindowsHelper: Self.visibleWindowsHelper,
                                                          depthEqualShim: Self.depthEqualShim)
                try Task.checkCancellation()
                self?.sessions[game.id]?.log = prepared.log
                self?.sessions[game.id]?.notes = prepared.notes
                    + (steamWasRunning ? ["Steam was already running in this bottle, so the game starts with Steam's settings, not its own."] : [])
                    + (prepared.inspection?.antiCheat.map { "\($0.kind.rawValue) found (\($0.evidence)): "
                        + ($0.severity == .blocksLaunch ? "this game won't run under Wine." : "online play may not work.") } ?? [])
                self?.sessions[game.id]?.status = .running
                let started = ContinuousClock.now
                if game.profile.performanceOverlay { Self.startOverlay(prefix: prepared.context.location.prefix) }
                let result = try await Launcher.run(prepared)
                self?.sessions[game.id]?.status = Task.isCancelled ? .stopped : .exited(result.status)
                if !Task.isCancelled {
                    // With Steam already running, the game ran with Steam's settings: nothing of its own to share.
                    await self?.sessionEnded(game, result: result, backend: prepared.plan.backend, log: prepared.log,
                                             played: ContinuousClock.now - started, ranOwnSettings: !steamWasRunning)
                }
            } catch is CancellationError {
                self?.sessions[game.id]?.status = .stopped
            } catch {
                self?.sessions[game.id]?.status = Task.isCancelled ? .stopped : .failed(Self.describe(error))
                if !Task.isCancelled { self?.offerReport(.launchFailed, for: game, summary: Self.describe(error)) }
            }
            self?.refreshRunningBottles()
        }
    }

    /// Runs a short-lived program in the game's bottle without tracking it, like `steam.exe` handing a
    /// link to the Steam already running there. The flag is set once it has ended.
    @discardableResult
    private func forward(_ game: Game) -> Flag {
        let ended = Flag()
        guard let bottle = bottle(for: game) else {
            ended.isSet = true
            return ended
        }
        let paths = self.paths
        Task { [weak self] in
            defer { ended.isSet = true }
            do {
                guard let engine = try RuntimeStore(paths: paths).engine(id: bottle.engineID) else {
                    throw AppError("No Wine runtime is installed. Add one in Settings.")
                }
                let prepared = try await Launcher.prepare(gameID: game.id, executable: game.executable, profile: game.profile,
                                                          bottle: bottle, engine: engine, paths: paths)
                _ = try await Launcher.run(prepared)
            } catch {
                self?.errorMessage = Self.describe(error)
            }
        }
        return ended
    }

    /// Stops the launch and everything else running in its bottle (Wine can't stop just one game's processes).
    func stop(_ game: Game) {
        guard !isPending(.stop(game.id)) else { return }
        if let task = sessions[game.id]?.task, sessions[game.id]?.isActive == true {
            task.cancel()
            pend(.stop(game.id), timeout: .seconds(60)) { [weak self] in
                guard let self else { return true }
                return sessions[game.id]?.isActive != true && !runningBottles.contains(game.bottleID)
            }
        } else if let appID = game.store?.appID, isRunning(game) {
            // Started from Steam's window: only the game quits, Steam stays.
            let prefix = BottleLocation(bottleID: game.bottleID, paths: paths).prefix
            Task.detached(priority: .userInitiated) { Steam.stopApp(appID, prefix: prefix) }
            pend(.stop(game.id), timeout: .seconds(30)) { [weak self] in self?.isRunning(game) != true }
        } else if let bottle = bottle(for: game) {
            stop(bottle)
        }
    }

    func stop(_ bottle: Bottle) {
        guard !isPending(.stopBottle(bottle.id)) else { return }
        let paths = self.paths
        pending.insert(.stopBottle(bottle.id))
        Task {
            defer { pending.remove(.stopBottle(bottle.id)) }
            await perform("Stopping \(bottle.name)…") {
                guard let engine = try RuntimeStore(paths: paths).engine(id: bottle.engineID) else { return }
                try Launcher.stop(bottle, engine: engine, paths: paths)
            }
            for (id, session) in sessions where session.isActive && session.game.bottleID == bottle.id {
                sessions[id]?.task?.cancel()
            }
        }
    }

    /// Quits Steam in the Steam bottle the way its own Exit does, then stops the rest of the bottle.
    func quitSteam() {
        guard !isPending(.quitSteam), let launcher = launcherBottle,
              let root = Steam.root(inPrefix: BottleLocation(bottleID: launcher.id, paths: paths).prefix) else { return }
        pending.insert(.quitSteam)
        let paths = self.paths
        Task {
            defer { pending.remove(.quitSteam) }
            await perform("Quitting Steam…") {
                guard let engine = try RuntimeStore(paths: paths).engine(id: launcher.engineID) else { return }
                try await Launcher.quitSteam(in: launcher, steam: root.appending(path: "steam.exe"), engine: engine, paths: paths,
                                             log: paths.logsRoot.appending(path: "bottles/\(launcher.id.uuidString)/steam-quit.log"))
            }
            refreshRunningBottles()
            await refreshRunningPrograms()
        }
    }

    /// Marks `action` pending until `isDone` turns true, `timeout` passes, or (with a bottle) the
    /// bottle shows a window it didn't show before, of the processes `include` picks: the game's,
    /// or Steam's shown again.
    private func pend(_ action: Pending, untilWindowIn bottleID: Bottle.ID? = nil,
                      of include: @escaping @Sendable (BottleProcesses.Entry) -> Bool = { _ in true },
                      timeout: Duration = .seconds(120), isDone: @escaping () -> Bool) {
        pending.insert(action)
        let prefix = bottleID.map { BottleLocation(bottleID: $0, paths: paths).prefix }
        Task {
            defer { pending.remove(action) }
            let before = await Self.windowsOnScreen(prefix, of: include)
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(1))
                if isDone() { return }
                if prefix != nil, !(await Self.windowsOnScreen(prefix, of: include)).isSubset(of: before) { return }
            }
        }
    }

    nonisolated private static func windowsOnScreen(_ prefix: URL?, of include: @escaping @Sendable (BottleProcesses.Entry) -> Bool) async -> Set<Int> {
        guard let prefix else { return [] }
        return await Task.detached(priority: .utility) { BottleProcesses.windowsOnScreen(prefix: prefix, of: include) }.value
    }

    /// Set once something has ended.
    final class Flag {
        var isSet = false
    }

    /// Built from `tools/steamwebhelper-wrapper` into the app's resources (see project.yml).
    private static let steamWebHelperWrapper = Bundle.main.url(forResource: "steamwebhelper-wrapper", withExtension: "exe")
    /// Built from `tools/visible-windows` into the app's resources (see project.yml).
    private static let visibleWindowsHelper = Bundle.main.url(forResource: "visible-windows", withExtension: "exe")
    /// Built from `tools/depth-equal-fix` into the app's resources (see project.yml).
    private static let depthEqualShim = Bundle.main.url(forResource: "depth-equal-fix", withExtension: "dll")

    private static func startOverlay(prefix: URL) {
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "perf-overlay") else { return }
        let overlay = Process()
        overlay.executableURL = tool
        overlay.arguments = [prefix.path]
        try? overlay.run()
    }

    // MARK: Bottles

    /// Creates the bottle, then installs Steam into it if asked.
    func createBottle(name: String, kind: Bottle.Kind, allowNetwork: Bool = false, installSteam: Bool = false) {
        guard !isPending(.createBottle) else { return }
        pending.insert(.createBottle)
        Task {
            defer { pending.remove(.createBottle) }
            guard let bottle = await createBottleNow(name: name, kind: kind, allowNetwork: allowNetwork), installSteam else { return }
            await self.installSteam(into: bottle)
        }
    }

    /// Returns the bottle, if it was created.
    @discardableResult
    private func createBottleNow(name: String, kind: Bottle.Kind, allowNetwork: Bool = false, role: Bottle.Role? = nil) async -> Bottle? {
        let paths = self.paths
        return await perform("Creating the bottle \"\(name)\"… (Wine sets up Windows; this takes a minute)") {
            guard let engine = try RuntimeStore(paths: paths).engine() else {
                throw AppError("Add a Wine runtime first.")
            }
            let bottle = Bottle(name: name, kind: kind, engineID: engine.id, isolation: IsolationPolicy(allowNetwork: allowNetwork), role: role)
            try await BottleStore(paths: paths).create(bottle, engine: engine)
            return bottle
        }
    }

    /// Stops everything in the bottle, moves its folder to the Trash and takes its games out of the library.
    func delete(_ bottle: Bottle) {
        // Setup made it and the app relies on it (see `Bottle.role`).
        guard bottle.role == nil, !isPending(.deleteBottle(bottle.id)) else { return }
        pending.insert(.deleteBottle(bottle.id))
        let paths = self.paths
        for (id, session) in sessions where session.isActive && session.game.bottleID == bottle.id {
            sessions[id]?.task?.cancel()
        }
        Task {
            defer { pending.remove(.deleteBottle(bottle.id)) }
            let trashed: URL?? = await perform("Moving \"\(bottle.name)\" to the Trash…") {
                let engine = try RuntimeStore(paths: paths).engine(id: bottle.engineID)
                return try BottleStore(paths: paths).moveToTrash(bottle, engine: engine)
            }
            guard trashed != nil else { return }
            for game in library.removeBottle(bottle.id) {
                LibraryStore(paths: paths).removeCachedIcon(for: game)
                icons[game.id] = nil
            }
            saveLibrary()
        }
    }

    /// Clean Up and Uninstall: stops every bottle, deletes all of Corkscrew's files (the bottles with
    /// the games in them, runtimes, library, logs, caches, settings) and the app, then quits.
    func uninstall() {
        guard !isPending(.uninstall) else { return }
        pending.insert(.uninstall)
        cancelSetUp()
        for (id, session) in sessions where session.isActive { sessions[id]?.task?.cancel() }
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.prateek-srivastav.Corkscrew"
        let uninstaller = Uninstaller(paths: paths, bundleIdentifier: bundleID)
        let app = Bundle.main.bundleURL
        // Before the files go, so cfprefsd doesn't write the preferences back.
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        CFPreferencesAppSynchronize(bundleID as CFString)
        Task {
            let (left, appRemoved) = await Task.detached(priority: .userInitiated) {
                uninstaller.stopBottles()
                return (uninstaller.removeFiles(), uninstaller.removeApp(at: app))
            }.value
            if !left.isEmpty || !appRemoved {
                let alert = NSAlert()
                alert.messageText = "Some files are still there"
                alert.informativeText = "Corkscrew couldn't delete these. Finder shows them; move them to the Trash.\n\n"
                    + (left + (appRemoved ? [] : [app])).map(\.path).joined(separator: "\n")
                alert.addButton(withTitle: "Quit")
                alert.runModal()
                NSWorkspace.shared.activateFileViewerSelecting(left + (appRemoved ? [] : [app]))
            }
            // Not `terminate`: quitting normally saves window state again.
            exit(0)
        }
    }

    func importBottle(from folder: URL) {
        let paths = self.paths
        guard !isPending(.importBottle) else { return }
        pending.insert(.importBottle)
        Task {
            defer { pending.remove(.importBottle) }
            await perform("Adding the bottle from \(folder.lastPathComponent)…") {
                try BottleStore(paths: paths).importBottle(from: folder)
            }
        }
    }

    func resetToClean(_ bottle: Bottle) {
        let paths = self.paths
        guard !isPending(.resetBottle(bottle.id)) else { return }
        pending.insert(.resetBottle(bottle.id))
        Task {
            defer { pending.remove(.resetBottle(bottle.id)) }
            await perform("Resetting \(bottle.name) to its clean state…") {
                guard let engine = try RuntimeStore(paths: paths).engine(id: bottle.engineID) else { return }
                try BottleStore(paths: paths).resetToClean(bottle, engine: engine)
            }
        }
    }

    func driveC(of bottle: Bottle) -> URL {
        BottleLocation(bottleID: bottle.id, paths: paths).prefix.appending(path: "drive_c", directoryHint: .isDirectory)
    }

    // MARK: Runtimes and components

    func installRuntime(folder: URL) {
        let paths = self.paths
        guard !isPending(.addRuntime) else { return }
        pending.insert(.addRuntime)
        Task {
            defer { pending.remove(.addRuntime) }
            await perform("Adding the Wine runtime from \(folder.lastPathComponent)…", reloading: .setup) {
                try RuntimeStore(paths: paths).install(directory: folder)
            }
        }
    }

    func installRuntime(archive: URL, sha256: String) {
        let paths = self.paths
        guard !isPending(.addRuntime) else { return }
        pending.insert(.addRuntime)
        Task {
            defer { pending.remove(.addRuntime) }
            await perform("Checking and unpacking \(archive.lastPathComponent)…", reloading: .setup) {
                try RuntimeStore(paths: paths).install(archive: archive, sha256: sha256.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func importComponents(from folder: URL) {
        let paths = self.paths
        guard !isPending(.addComponents) else { return }
        pending.insert(.addComponents)
        Task {
            defer { pending.remove(.addComponents) }
            let added = await perform("Adding graphics components from \(folder.lastPathComponent)…", reloading: .setup) {
                try ComponentCatalog.importComponents(from: folder, into: paths.components)
            }
            if added?.isEmpty == true { errorMessage = "No new components in \(folder.path) (looked for dxmt-*, dxvk-macos-*, d3dmetal-*)." }
        }
    }

    /// The pack a downloaded app installs: `EnginePack.current`, or `-EnginePackURL <url>` to try a
    /// local copy of it (same checksum).
    static var enginePack: EnginePack {
        var pack = EnginePack.current
        if let override = UserDefaults.standard.string(forKey: "EnginePackURL"), let url = URL(string: override) { pack.url = url }
        return pack
    }

    /// The pack's archive inside the app (DMG builds), so setup needs no download. Not with
    /// `-EnginePackURL`, which is there to try another copy.
    static var bundledEnginePack: URL? {
        guard UserDefaults.standard.string(forKey: "EnginePackURL") == nil else { return nil }
        return EnginePack.current.bundledArchive(in: Bundle.main.resourceURL)
    }

    /// Everything a new user needs to play, in one go: Rosetta, the engine pack (Wine, D3DMetal, DXMT,
    /// DXVK; inside the DMG's app, otherwise downloaded), the Steam bottle with Steam, then the two
    /// sandboxes. Steps already done are skipped, so it can simply be run
    /// again after a failure; a failed or cancelled step stops the rest.
    func setUp() {
        guard setupTask == nil else { return }
        isSettingUp = true
        setupTask = Task {
            defer {
                setupTask = nil
                isSettingUp = false
                setupStep = nil
            }
            setupFailure = nil
            let started = ContinuousClock.now
            let installsRosetta = !hasRosetta
            var engine = "installed before"
            if !hasRosetta {
                setupStep = .rosetta
                let installed: Void? = await perform("Installing Rosetta… (macOS asks for your password; the download takes a minute)", reloading: .setup) {
                    try Rosetta.install()
                }
                guard installed != nil else { return stopSetUp(at: .rosetta) }
            }
            setupStep = .engine
            if runtimes.isEmpty || Self.enginePack.upgradesInstalledRuntime(in: paths) {
                engine = Self.bundledEnginePack == nil ? "downloaded" : "in the app"
                guard await installEnginePack(), !Task.isCancelled else { return stopSetUp(at: .engine) }
            }
            setupStep = .steam
            guard await createDefaultBottles([.steam]), !Task.isCancelled else { return stopSetUp(at: .steam) }
            if !hasSteam, let launcher = launcherBottle {
                guard await installSteam(into: launcher), !Task.isCancelled else { return stopSetUp(at: .steam) }
            }
            setupStep = .protectedGames
            guard await createDefaultBottles() else { return stopSetUp(at: .protectedGames) }
            guard !Task.isCancelled else { return }
            let seconds = Int(started.duration(to: .now).components.seconds)
            // Not awaited: setup is done, and the count may take seconds.
            Task { await count("setup_done", ["seconds": .int(seconds), "installed_rosetta": .bool(installsRosetta), "engine": .string(engine)]) }
        }
    }

    // MARK: Updates

    /// Where the update check reads update.json: the latest release, or `-UpdateURL <url>` to try a
    /// local copy. Debug builds don't check without one: they aren't installed copies.
    static var updateURL: URL? {
        if let url = UserDefaults.standard.string(forKey: "UpdateURL") { return URL(string: url) }
        return isDebugBuild ? nil : AppUpdate.latestURL
    }

    /// Looks for a newer release once per launch. Offline, or with no update.json, nothing shows.
    private func checkForUpdate() {
        let app = Bundle.main.bundleURL
        // Left by an update that didn't finish.
        try? FileManager.default.removeItem(at: AppUpdate.stagingFolder(nextTo: app))
        guard let url = Self.updateURL else { return }
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let paths = self.paths
        Task {
            guard let update = try? await AppUpdate.check(url), update.isNewer(than: installed) else { return }
            updateSize = update.downloadSize(paths: paths)
            availableUpdate = update
        }
    }

    /// Where the tested list comes from: main, or `-TestedListURL <url>`. Debug builds keep their
    /// own tested.json unless given one, so edits to it show.
    static var testedListURL: URL? {
        if let url = UserDefaults.standard.string(forKey: "TestedListURL") { return URL(string: url) }
        return isDebugBuild ? nil : Steam.testedListURL
    }

    /// Uses the last tested list this version downloaded, then reads the newest once per launch, so
    /// settings accepted since this release apply. Offline, the saved list stays, else the app's own.
    private func updateTestedList() {
        guard let url = Self.testedListURL else { return }
        let paths = self.paths
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if let saved = Steam.savedTestedList(paths: paths, version: version) { Steam.useTestedList(saved) }
        Task {
            guard let games = try? await Steam.downloadTestedList(from: url) else { return }
            try? Steam.saveTestedList(games, paths: paths, version: version)
            // Steam library entries carry the tested settings.
            if Steam.useTestedList(games) { syncStores() }
        }
    }

    /// Downloads the update, puts it where this app is, and restarts into it. Not while programs run
    /// in a bottle (Steam too) or setup runs: the new app may replace Wine when it opens.
    func installUpdate() {
        guard let update = availableUpdate, !isPending(.update) else { return }
        guard runningBottles.isEmpty else {
            errorMessage = "Quit your games and Steam first: Corkscrew restarts to update."
            return
        }
        guard setupTask == nil else {
            errorMessage = "Corkscrew can update when setup is done."
            return
        }
        pending.insert(.update)
        updateProgress = 0
        let app = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.prateek-srivastav.Corkscrew"
        let downloads = paths.cachesRoot.appending(path: "Downloads")
        Task {
            defer {
                pending.remove(.update)
                updateProgress = nil
            }
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try await update.stage(nextTo: app, bundleIdentifier: bundleID, downloads: downloads) { fraction in
                        Task { @MainActor in
                            // Late ones, after the download ended, are dropped.
                            if let progress = self.updateProgress { self.updateProgress = max(progress, fraction) }
                        }
                    }
                }.value
                // A game may have started during the download.
                guard runningBottles.isEmpty else {
                    try? FileManager.default.removeItem(at: AppUpdate.stagingFolder(nextTo: app))
                    throw AppError("quit your games and Steam, then click Update again")
                }
                try AppUpdate.install(staged, replacing: app)
                relaunch(app)
            } catch {
                errorMessage = "Couldn't update Corkscrew: \(Self.describe(error))"
            }
        }
    }

    /// Quits, and opens `app` once this process is gone (`open` would only bring a running copy forward).
    private func relaunch(_ app: URL) {
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/sh")
        opener.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\"", "sh",
                            String(ProcessInfo.processInfo.processIdentifier), app.path]
        do {
            try opener.run()
        } catch {
            errorMessage = "Corkscrew is updated. Quit it and open it again to use the new version."
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: Usage counts

    /// `-AnalyticsKey <key>` sends to another Aptabase app (A-DEV-… to a local server at port 3000).
    private static let analytics = Analytics(key: UserDefaults.standard.string(forKey: "AnalyticsKey") ?? Analytics.appKey,
                                             system: .current(isDebug: isDebugBuild))
    /// Set once the first launch is counted, or when counts were off at the first launch.
    private static let firstLaunchCountedKey = "FirstLaunchCounted"

    /// Debug builds' counts go to Aptabase's debug data, apart from the releases'.
    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Sends one anonymous count unless Settings turned them off, and returns whether it went.
    @discardableResult
    private func count(_ event: String, _ props: [String: Analytics.Value] = [:]) async -> Bool {
        guard Self.sendsUsageCounts, let analytics = Self.analytics else { return false }
        return await analytics.send(event, props: props)
    }

    // MARK: Crash and error reports

    /// A report the report sheet offers, after a crash or an error.
    struct PendingReport: Identifiable {
        let id = UUID()
        var report: ProblemReport
        var logFile: URL?
        /// The Bug report form's name for the graphics backend.
        var backend = "Not related to graphics"
    }

    var pendingReport: PendingReport?
    /// Where Send Report posts reports; `-ReportRelayURL <url>` tries another server.
    static var reportRelay: URL? { UserDefaults.standard.string(forKey: "ReportRelayURL").flatMap(URL.init(string:)) ?? ProblemReport.relayURL }

    /// When the app last looked for its own crash reports.
    private static let crashReportsCheckedKey = "CrashReportsChecked"

    /// A report after a crash or an error. Nothing is sent without a click.
    private func offer(_ report: ProblemReport, logFile: URL? = nil, backend: GraphicsBackend? = nil) {
        pendingReport = PendingReport(report: report, logFile: logFile, backend: backend?.formName ?? "Not related to graphics")
    }

    /// After a launch ends by itself: a report when the program crashed (Wine's backtrace in the
    /// log, or Wine ended by a signal). Or, for a Steam game played a while with settings the
    /// tested list doesn't have, an offer to share them.
    private func sessionEnded(_ game: Game, result: RunResult, backend: GraphicsBackend?, log: URL, played: Duration,
                              ranOwnSettings: Bool) async {
        let found = await Task.detached(priority: .utility) {
            (crash: ProblemReport.crash(inLog: log), tail: ProblemReport.logTail(of: log))
        }.value
        if found.crash != nil || result.crashed {
            offer(ProblemReport(kind: .crash, title: "\(game.name) crashed", summary: found.crash?.summary ?? "Wine \(result.outcome).",
                                details: reportDetails(for: game, backend: backend), backtrace: found.crash?.backtrace, log: found.tail),
                  logFile: log, backend: backend)
        } else if ranOwnSettings, played >= Self.playedBeforeAskingToShare {
            offerToShare(game, played: played)
        }
    }

    /// A launch that failed before the program ran.
    private func offerReport(_ kind: ProblemReport.Kind, for game: Game, summary: String) {
        let log = sessions[game.id]?.log
        offer(ProblemReport(kind: kind, title: "\(game.name) didn't start", summary: summary, details: reportDetails(for: game),
                            log: log.flatMap { ProblemReport.logTail(of: $0) }),
              logFile: log)
    }

    /// The error alert's Report button.
    func reportError() {
        guard let message = errorMessage else { return }
        errorMessage = nil
        let report = ProblemReport(kind: .error, title: "Something went wrong", summary: message, details: reportDetails())
        // After the alert closes: a sheet asked for while it closes doesn't show.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            pendingReport = PendingReport(report: report)
        }
    }

    /// Corkscrew's own crash since the last launch, from macOS's crash reports. Not at the first
    /// check: older reports may be from another version.
    private func offerAppCrashReport() {
        let since = UserDefaults.standard.object(forKey: Self.crashReportsCheckedKey) as? Date
        UserDefaults.standard.set(Date(), forKey: Self.crashReportsCheckedKey)
        guard let since else { return }
        let details = reportDetails()
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
        Task {
            let report = await Task.detached(priority: .utility) { () -> ProblemReport? in
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                let newest = files
                    .filter { $0.lastPathComponent.hasPrefix("Corkscrew-") && $0.pathExtension == "ips" }
                    .compactMap { url in (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map { (url, $0) } }
                    .filter { $0.1 > since }
                    .max { $0.1 < $1.1 }
                return newest.flatMap { ProblemReport.appCrash(ipsFile: $0.0, details: details) }
            }.value
            if let report, pendingReport == nil { offer(report) }
        }
    }

    /// Corkscrew and the Mac, then the program and its settings: what a report says besides the error.
    func reportDetails(for game: Game? = nil, backend: GraphicsBackend? = nil) -> [String] {
        let system = Analytics.System.current(isDebug: Self.isDebugBuild)
        var lines = ["Corkscrew: \(system.appVersion) (\(system.appBuildNumber))" + (Self.isDebugBuild ? ", debug build" : ""),
                     "macOS: \(system.osVersion)",
                     "Mac: \(Hardware.model), \(Hardware.chip), \(Hardware.memoryGB) GB",
                     "Wine: \(runtimes.isEmpty ? "not installed" : runtimes.map(\.id).joined(separator: ", ")), engine pack \(EnginePack.current.version)",
                     "Rosetta: \(hasRosetta ? "installed" : "not installed")"]
        guard let game else { return lines }
        lines.append("Program: \(game.name)" + (game.store?.appID.map { " (Steam app \($0))" } ?? ""))
        if let bottle = bottle(for: game) {
            lines.append("Bottle: \(bottle.name), Wine \(bottle.engineID), \(bottle.windowsVersion.rawValue), " + (bottle.kind == .isolated
                ? "protected, internet \(bottle.isolation.allowNetwork ? "on" : "off")" : "not protected"))
        }
        let profile = game.profile
        lines.append("Graphics: \(backend?.displayName ?? "not chosen") (setting: \(profile.backendOverride?.displayName ?? "Automatic"))")
        lines.append("Settings: MetalFX \(profile.metalFX ? "on" : "off"), Retina mode \(profile.retinaMode ? "on" : "off"), "
                     + "AVX \(profile.advertiseAVX ? "on" : "off"), Steam overlay \(profile.steamOverlay ? "on" : "off")"
                     + (profile.arguments.isEmpty ? "" : ", arguments: \(profile.arguments.joined(separator: " "))")
                     + (profile.environment.isEmpty ? "" : ", environment: "
                        + profile.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")))
        return lines
    }

    /// The issue forms' "Corkscrew version" and "Mac and macOS" fields.
    func formVersionAndMac() -> (version: String, mac: String) {
        let system = Analytics.System.current(isDebug: Self.isDebugBuild)
        return ("\(system.appVersion) (\(system.appBuildNumber))", "\(system.osVersion), \(Hardware.model), \(Hardware.chip), \(Hardware.memoryGB) GB")
    }

    // MARK: Sharing settings that work

    /// A Steam game that ran well, and the settings it ran with: the share sheet offers them for
    /// the tested list.
    struct SharePrompt: Identifiable {
        let id = UUID()
        var game: Game
        var minutes: Int
    }

    var pendingShare: SharePrompt?

    /// How long a game must run before it counts as running well; `-AskToShareAfterSeconds <n>` to try it.
    private static var playedBeforeAskingToShare: Duration {
        .seconds(UserDefaults.standard.string(forKey: "AskToShareAfterSeconds").flatMap(Int.init) ?? 15 * 60)
    }

    /// The settings already offered, by Steam app id: asked once for each set of settings.
    private static let sharePromptsKey = "SharedSettingsAsked"

    private func offerToShare(_ game: Game, played: Duration) {
        guard pendingReport == nil, Self.reportRelay != nil, Steam.canShareSettings(of: game), let appID = game.store?.appID,
              let settings = Steam.settingsReport(of: game) else { return }
        var asked = UserDefaults.standard.dictionary(forKey: Self.sharePromptsKey) as? [String: String] ?? [:]
        guard asked[appID] != settings else { return }
        asked[appID] = settings
        UserDefaults.standard.set(asked, forKey: Self.sharePromptsKey)
        pendingShare = SharePrompt(game: game, minutes: Int(played.components.seconds / 60))
    }

    /// The first launch for this Mac account, once (Clean Up and Uninstall starts over). `set_up`:
    /// Corkscrew was set up before, by a version that didn't count. With counts off at that launch,
    /// it's never sent; one that fails goes at the next launch.
    private func countFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.firstLaunchCountedKey) else { return }
        guard Self.sendsUsageCounts else { return UserDefaults.standard.set(true, forKey: Self.firstLaunchCountedKey) }
        let setUp = !runtimes.isEmpty
        Task {
            if await count("first_launch", ["set_up": .bool(setUp)]) {
                UserDefaults.standard.set(true, forKey: Self.firstLaunchCountedKey)
            }
        }
    }

    /// A step that failed shows as failed; a cancelled one doesn't.
    private func stopSetUp(at step: SetupStep) {
        if !Task.isCancelled { setupFailure = step }
    }

    func cancelSetUp() { setupTask?.cancel() }

    /// Installs the engine pack's runtime and components, replacing ones from an older pack: from
    /// the copy inside the app, or downloaded. Returns whether it did.
    @discardableResult
    private func installEnginePack() async -> Bool {
        let paths = self.paths
        let pack = Self.enginePack
        let bundled = Self.bundledEnginePack
        let archive = bundled ?? paths.cachesRoot.appending(path: "Downloads/\(pack.url.lastPathComponent)")
        if bundled == nil {
            enginePackProgress = EnginePackProgress(step: .downloading)
            do {
                try await Downloader.download(pack.url, to: archive) { fraction in
                    Task { @MainActor in self.advanceEnginePack(.downloading, to: fraction) }
                }
                enginePackProgress = nil
            } catch {
                enginePackProgress = nil
                if (error as? URLError)?.code != .cancelled { errorMessage = "Couldn't download the Wine runtime: \(Self.describe(error))" }
                return false
            }
        }
        isInstallingEngine = true
        enginePackProgress = EnginePackProgress(step: .unpacking, afterDownload: bundled == nil)
        defer {
            isInstallingEngine = false
            enginePackProgress = nil
        }
        let installed: RuntimeManifest? = await perform("Checking and unpacking the Wine runtime…", reloading: .setup) {
            // The copy inside the app stays: it's sealed by the app's signature.
            defer { if bundled == nil { try? FileManager.default.removeItem(at: archive) } }
            return try pack.install(archive: archive, paths: paths) { fraction in
                Task { @MainActor in self.advanceEnginePack(.unpacking, to: fraction) }
            }
        }
        return installed != nil
    }

    /// Late updates, after their step ended, are dropped.
    private func advanceEnginePack(_ step: EnginePackProgress.Step, to fraction: Double) {
        guard var progress = enginePackProgress, progress.step == step else { return }
        progress.fraction = max(progress.fraction, fraction)
        enginePackProgress = progress
    }

    /// Whether Steam's files are in the bottle, listed in the library or not.
    func hasSteam(in bottle: Bottle) -> Bool {
        Steam.root(inPrefix: BottleLocation(bottleID: bottle.id, paths: paths).prefix) != nil
    }

    /// Downloads Valve's installer and installs Steam into `bottle`; Steam then shows up in the library.
    /// An offline isolated bottle gets internet first: Steam doesn't work without it.
    @discardableResult
    func installSteam(into bottle: Bottle) async -> Bool {
        guard !steamInstalls.contains(bottle.id) else { return false }
        steamInstalls.insert(bottle.id)
        defer { steamInstalls.remove(bottle.id) }
        let paths = self.paths
        // One installer per bottle, so two installs at once don't share a file.
        let installer = paths.cachesRoot.appending(path: "Downloads/SteamSetup-\(bottle.id.uuidString).exe")
        let installed: URL? = await perform("Installing Steam into \"\(bottle.name)\"… (it downloads about 240 MB the first time)") {
            defer { try? FileManager.default.removeItem(at: installer) }
            // The saved copy, which may be newer than the one shown.
            let store = BottleStore(paths: paths)
            var target = try store.list().first { $0.id == bottle.id } ?? bottle
            if target.kind == .isolated && !target.isolation.allowNetwork {
                target.isolation.allowNetwork = true
                try store.save(target)
            }
            try await Downloader.download(Steam.installerURL, to: installer) { _ in }
            guard let engine = try RuntimeStore(paths: paths).engine(id: target.engineID) else {
                throw AppError("Add a Wine runtime first.")
            }
            let log = paths.logsRoot.appending(path: "bottles/\(target.id.uuidString)/steam-install.log")
            return try await Steam.install(installer: installer, bottle: target, engine: engine, paths: paths, log: log)
        }
        return installed != nil
    }

    func importGPTK(dmg: URL) {
        let paths = self.paths
        guard !isPending(.importToolkit) else { return }
        pending.insert(.importToolkit)
        Task {
            defer { pending.remove(.importToolkit) }
            await perform("Importing D3DMetal from \(dmg.lastPathComponent)…", reloading: .setup) {
                try GPTKImporter.importToolkit(dmg: dmg, into: paths.components)
            }
        }
    }

    // MARK: Steam store

    /// Where Steam store details and art are cached.
    var storeCache: URL { paths.cachesRoot.appending(path: "Steam Store", directoryHint: .isDirectory) }

    /// Keeps the store cache within its limit, and empties URLCache's copy of store replies from
    /// before the store had its own connection.
    private func trimCaches() {
        let cache = storeCache
        Task.detached(priority: .background) {
            URLCache.shared.removeAllCachedResponses()
            SteamStore.trim(cache: cache)
        }
    }
    @ObservationIgnored private var storeAppIDs: [Game.ID: String] = [:]

    /// The Steam app a game is: its own for a Steam game; for a program in another bottle, the app
    /// named next to it or found by its name in the store. Nil for Steam itself and unknown programs.
    func steamAppID(for game: Game) async -> String? {
        if let store = game.store { return store.appID }
        if let known = storeAppIDs[game.id] { return known }
        let program = game.iconSource ?? game.executable
        let names = [game.name] + SteamStore.folderNames(of: program)
        let cache = storeCache
        let id = await Task.detached(priority: .utility) { await SteamStore.appID(forProgram: program, names: names, cache: cache) }.value
        if let id { storeAppIDs[game.id] = id }
        return id
    }

    /// The game's page in the Steam store: description, makers, genres, screenshots.
    func storeDetails(for game: Game) async -> SteamStore.Details? {
        guard let appID = await steamAppID(for: game) else { return nil }
        let cache = storeCache
        return await Task.detached(priority: .utility) { await SteamStore.details(appID: appID, cache: cache) }.value
    }

    // MARK: Helpers

    /// Runs slow work off the main thread with a status line; errors become an alert. Reloads afterwards.
    @discardableResult
    private func perform<T: Sendable>(_ title: String, reloading scope: Reload = .all,
                                      _ work: @escaping @Sendable () async throws -> T) async -> T? {
        // Several can run at once (a bottle being created while a toolkit imports): the status line
        // stays until the last one ends.
        let id = UUID()
        activities.append((id, title))
        activity = title
        defer {
            activities.removeAll { $0.id == id }
            activity = activities.last?.title
            reload(scope)
        }
        do {
            return try await Task.detached(priority: .userInitiated) { try await work() }.value
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    static func describe(_ error: Error) -> String {
        // Foundation's errors have good localized text; GameCore's describe themselves (their bridged
        // localizedDescription is just "error 3").
        if type(of: error) is NSError.Type || error is CocoaError || error is POSIXError || error is URLError {
            return error.localizedDescription
        }
        return String(describing: error)
    }
}

/// The steps the one-click setup goes through, in order.
enum SetupStep: CaseIterable { case rosetta, engine, steam, protectedGames }

/// How far the engine pack's download, or its checksum and unpack, has got.
struct EnginePackProgress: Equatable {
    enum Step { case downloading, unpacking }
    var step: Step
    var fraction: Double = 0

    /// Unpacking after a download (the pack wasn't inside the app): the download is the first half.
    var afterDownload = false

    var title: String { "\(step == .downloading ? "Downloading" : "Unpacking") Wine… \(Int(fraction * 100))%" }
    /// How far the whole engine pack step is, download included.
    var overall: Double {
        switch step {
        case .downloading: fraction * 0.5
        case .unpacking: afterDownload ? 0.5 + fraction * 0.5 : fraction
        }
    }
}

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
