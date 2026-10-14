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
    private(set) var library = Library()
    var games: [Game] { library.games }
    private(set) var bottles: [Bottle] = []
    private(set) var runtimes: [RuntimeManifest] = []
    private(set) var components: [String] = []
    /// Bottles whose wineserver is up, refreshed every couple of seconds.
    private(set) var runningBottles: Set<UUID> = []
    /// Steam games' install states by `Game.storeKey`; nil until the first scan.
    private(set) var storeStates: [String: Steam.InstallState]?
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
    }

    private(set) var pending: Set<Pending> = []
    /// Bottles where Steam's client runs, refreshed with `runningBottles`.
    private(set) var steamRunning: Set<Bottle.ID> = []
    /// `Game.storeKey`s of Steam games with a program running: started here or from Steam's window.
    private(set) var runningSteamApps: Set<String> = []
    func isPending(_ action: Pending) -> Bool { pending.contains(action) }

    /// Programs opened from Finder, dropped on the window or picked with Add Program, waiting for
    /// the user to choose "Run Once" or "Add to Library".
    var openRequests: [URL] = []
    /// The bottle to offer first for an opened program, when it was opened from that bottle.
    private(set) var openBottles: [URL: Bottle.ID] = [:]
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
    private(set) var steamLibrary: SteamLibrary?

    /// Steam has an account that's signed in now: Steam runs, or signs in by itself when it starts.
    var steamAccount: Steam.Account? {
        guard let account = steamLibrary?.account, let launcher = launcherBottle else { return nil }
        return account.remembersSignIn || runningBottles.contains(launcher.id) ? account : nil
    }

    /// The Steam page's games: the account's library, with the library entries (and their settings)
    /// for games that have one, and installed games Steam hasn't listed yet. Not other entries, such
    /// as tested games the account doesn't own.
    var steamGames: [Game] {
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

    /// The Library page: the signed-in account's Steam games and every program in another bottle,
    /// without the launchers themselves.
    var allGames: [Game] {
        let steam = steamAccount == nil ? [] : steamGames
        let others = games.filter { $0.bottleID != launcherBottle?.id }
        return (steam + others)
            .filter { !($0.store != nil && $0.store?.appID == nil) }
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
        reload()
        if runningBottles.isEmpty { Self.unregisterLoaderBundles() }
        Task { await setUpAutomatically() }
        Task { [weak self] in
            var tick = 0
            while let self {
                self.refreshRunningBottles()
                await self.refreshRunningPrograms()
                // While Steam may be installing or uninstalling games, look at its manifests now and then.
                tick += 1
                if tick % 15 == 0, !self.runningBottles.isEmpty { self.syncStores() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Back from Steam (or Finder): pick up games installed or uninstalled meanwhile.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncStores() }
        }
    }

    /// `~/Library/…/Corkscrew`, or one folder for everything when the `DataRoot` default is set
    /// (`defaults write io.github.prateek-srivastav.Corkscrew DataRoot <folder>`, or `-DataRoot <folder>` at launch),
    /// e.g. the CLI's `build/dev-data`.
    static var configuredPaths: AppPaths {
        guard let root = UserDefaults.standard.string(forKey: "DataRoot"), !root.isEmpty else { return .standard }
        return .rooted(at: URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true))
    }

    func reload() {
        do {
            library = try LibraryStore(paths: paths).load()
            bottles = try BottleStore(paths: paths).list()
            try adoptRoleBottles()
        } catch {
            errorMessage = Self.describe(error)
        }
        hasRosetta = Rosetta.isInstalled
        runtimes = RuntimeStore(paths: paths).list()
        components = ComponentCatalog.staged(in: paths.components)
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
                await perform("Adding the Wine runtime and graphics components from \(build.path)…") {
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
        runningBottles = running
        if running.isEmpty { Self.unregisterLoaderBundles() }
        syncStores()
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
    private static func unregisterLoaderBundles() {
        Task.detached(priority: .utility) { LoaderBundles.unregisterAll() }
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

    func icon(for game: Game) -> NSImage? {
        let source = game.iconSource ?? game.executable
        let modified = (try? FileManager.default.attributesOfItem(atPath: source.path))?[.modificationDate] as? Date
        if let cached = icons[game.id], cached.modified == modified { return cached.image }
        let image = LibraryStore(paths: paths).icon(for: game).flatMap(NSImage.init(data:))
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
    func open(_ urls: [URL], in bottle: Bottle? = nil) {
        let files = urls.filter(\.isFileURL)
        for url in urls where url.scheme == "corkscrew" { handleLink(url) }
        let programs = files.filter { ["exe", "msi"].contains($0.pathExtension.lowercased()) }
        if programs.count < files.count { errorMessage = "Only Windows programs (.exe) and installers (.msi) can be opened." }
        for program in programs { openBottles[program] = bottle?.role == .steam ? nil : bottle?.id }
        openRequests += programs.filter { !openRequests.contains($0) }
    }

    /// The bottle the Open sheet selects first for `program`.
    func openBottle(for program: URL) -> Bottle? {
        programBottles.first { $0.id == openBottles[program] } ?? suggestedBottle(for: program)
    }

    func closeOpenRequest(_ program: URL) {
        openRequests.removeAll { $0 == program }
        openBottles[program] = nil
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
    func suggestedBottle(for program: URL) -> Bottle? {
        let bottles = programBottles
        return bottle(containing: program).flatMap { found in bottles.first { $0.id == found.id } }
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

    private func start(_ game: Game, transient: Bool) {
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
                    throw AppError("No Wine runtime is installed. Add one under Setup.")
                }
                let prepared = try await Launcher.prepare(gameID: game.id, executable: game.executable, profile: game.profile,
                                                          bottle: bottle, engine: engine, paths: paths,
                                                          steamWebHelperWrapper: Self.steamWebHelperWrapper,
                                                          visibleWindowsHelper: Self.visibleWindowsHelper)
                try Task.checkCancellation()
                self?.sessions[game.id]?.log = prepared.log
                self?.sessions[game.id]?.notes = prepared.notes
                    + (steamWasRunning ? ["Steam was already running in this bottle, so the game starts with Steam's settings, not its own."] : [])
                    + (prepared.inspection?.antiCheat.map { "\($0.kind.rawValue) found (\($0.evidence)): "
                        + ($0.severity == .blocksLaunch ? "this game won't run under Wine." : "online play may not work.") } ?? [])
                self?.sessions[game.id]?.status = .running
                if game.profile.performanceOverlay { Self.startOverlay(prefix: prepared.context.location.prefix) }
                let result = try await Launcher.run(prepared)
                self?.sessions[game.id]?.status = Task.isCancelled ? .stopped : .exited(result.status)
            } catch is CancellationError {
                self?.sessions[game.id]?.status = .stopped
            } catch {
                self?.sessions[game.id]?.status = Task.isCancelled ? .stopped : .failed(Self.describe(error))
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
                    throw AppError("No Wine runtime is installed. Add one under Setup.")
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
            await perform("Adding the Wine runtime from \(folder.lastPathComponent)…") {
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
            await perform("Checking and unpacking \(archive.lastPathComponent)…") {
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
            let added = await perform("Adding graphics components from \(folder.lastPathComponent)…") {
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
            if !hasRosetta {
                setupStep = .rosetta
                let installed: Void? = await perform("Installing Rosetta… (macOS asks for your password; the download takes a minute)") {
                    try Rosetta.install()
                }
                guard installed != nil else { return stopSetUp(at: .rosetta) }
            }
            setupStep = .engine
            if runtimes.isEmpty || Self.enginePack.upgradesInstalledRuntime(in: paths) {
                guard await installEnginePack(), !Task.isCancelled else { return stopSetUp(at: .engine) }
            }
            setupStep = .steam
            guard await createDefaultBottles([.steam]), !Task.isCancelled else { return stopSetUp(at: .steam) }
            if !hasSteam, let launcher = launcherBottle {
                guard await installSteam(into: launcher), !Task.isCancelled else { return stopSetUp(at: .steam) }
            }
            setupStep = .protectedGames
            guard await createDefaultBottles() else { return stopSetUp(at: .protectedGames) }
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
        let installed: RuntimeManifest? = await perform("Checking and unpacking the Wine runtime…") {
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
            await perform("Importing D3DMetal from \(dmg.lastPathComponent)…") {
                try GPTKImporter.importToolkit(dmg: dmg, into: paths.components)
            }
        }
    }

    // MARK: Steam store

    /// Where Steam store details and art are cached.
    var storeCache: URL { paths.cachesRoot.appending(path: "Steam Store", directoryHint: .isDirectory) }
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
    private func perform<T: Sendable>(_ title: String, _ work: @escaping @Sendable () async throws -> T) async -> T? {
        // Several can run at once (a bottle being created while a toolkit imports): the status line
        // stays until the last one ends.
        let id = UUID()
        activities.append((id, title))
        activity = title
        defer {
            activities.removeAll { $0.id == id }
            activity = activities.last?.title
            reload()
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
