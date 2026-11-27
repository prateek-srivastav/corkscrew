import Foundation

/// Follows a Steam game's launch by what Steam's log says of its programs (`SteamGameLog`), waking
/// when something happens (`LaunchTriggers`) rather than looking every few seconds.
///
/// Until Steam starts a program for the game, the phase is `.steam`; then the newest program's name,
/// until a window of the game's programs shows. For `windowWatch` after each thing Steam says, it
/// looks for those windows, then less often until one shows. Once Steam ends the game, what started
/// with it closes by itself: the launch follows those programs as they exit, for up to
/// `closingLimit`. Nothing is closed here.
struct SteamGameFollower {
    /// After Steam says something of the game, how long its windows are looked for (to show
    /// "Running" and bring them forward), and how often. After that, until one shows, every
    /// `slowWindowPoll`: a game can take minutes to open its window.
    static let windowWatch: Duration = .seconds(60)
    static let windowPoll: Duration = .seconds(1)
    static let slowWindowPoll: Duration = .seconds(5)
    /// After Steam ends the game: what still runs this long after stays (a launcher that lives in the
    /// menu bar), and the launch ends without it.
    static let closingLimit: Duration = .seconds(30)
    /// Before Steam starts a program for the game: how long nothing of the launch's may run (Steam's
    /// installers do) before the launch ends. Steam may never start it: a dialog the player closed,
    /// a game that runs on another computer.
    static let startLimit: Duration = .seconds(600)

    typealias Progress = Launcher.LaunchProgress

    private var log: SteamGameLog
    private let prefix: URL
    /// Steam's folder, as `Launcher.driveCFolder` has it: its programs aren't the game's leftovers.
    private let steamFolder: String?
    /// Steam's windows already open before the launch: they don't ask anything of this one.
    private let steamWindows: Set<Int>
    private let triggers: LaunchTriggers
    private var trace: LaunchTrace

    private let clock = ContinuousClock()
    private var watchUntil: ContinuousClock.Instant
    /// Since when nothing of the launch's has run, before Steam starts the game (`startLimit`).
    private var quietSince: ContinuousClock.Instant
    /// Once a window has shown, the game plays: it may go full screen, on its own Space.
    private var windowed = false
    /// The program that won't get the game started (`RockstarLauncher.hasLostService`).
    private var stuck: String?
    /// How many programs Steam had started when `stuck` was set: a program from a game's folder
    /// started after them means the game started after all.
    private var stuckAfter = 0
    private var lostService: RockstarLauncher.LostServiceWatch
    /// What ran when the launch began, and when Steam started the game: not what the game leaves
    /// running. `before` is nil when Steam started and ended the game between two looks.
    private var initial: Set<pid_t>?
    private var before: Set<pid_t>?
    private var endedAt: ContinuousClock.Instant?
    /// Programs still closing after the game ended, in the order first seen, so the line only shortens.
    private var closing: [String] = []
    private var names: [String: String] = [:]

    init(log: SteamGameLog, prefix: URL, steamFolder: String?, steamWindows: Set<Int>, triggers: LaunchTriggers, trace: LaunchTrace) {
        self.log = log
        self.prefix = prefix
        self.steamFolder = steamFolder
        self.steamWindows = steamWindows
        self.triggers = triggers
        self.trace = trace
        lostService = RockstarLauncher.LostServiceWatch(prefix: prefix, since: Date())
        watchUntil = clock.now + Self.windowWatch
        quietSince = clock.now
    }

    /// Whether Steam ended the game, rather than quitting or crashing itself.
    var gameEnded: Bool { log.hasEnded }

    /// The programs Steam followed for the game, by file name, lowercased (`rdr2.exe`), once each.
    var programs: [String] {
        var seen: Set<String> = []
        return log.started.map { BottleProcesses.fileName(of: $0.path).lowercased() }.filter { seen.insert($0).inserted }
    }

    /// Follows the launch until it's over: Steam ended the game and what it started has closed,
    /// Steam itself is gone (`steamHasExited`, and no Steam client runs), or Steam never started
    /// the game (`startLimit`). `progress` hears each change.
    mutating func follow(steamHasExited: () -> Bool, progress: (@Sendable (Progress) -> Void)?) async {
        var last: Progress?
        triggers.wake()
        triggers.wake(after: Self.startLimit)
        for await _ in triggers.events {
            if log.update() { watchUntil = clock.now + Self.windowWatch }
            let processes = BottleProcesses.list(prefix: prefix, maxAge: .zero)
            if initial == nil { initial = Set(processes.map(\.pid)) }
            // Steam quit (or crashed). Not when its process only handed the game to the Steam already
            // running, and left.
            if steamHasExited(), !processes.contains(where: \.isSteamClient) { break }
            let watching = clock.now < watchUntil
            guard let now = log.hasEnded ? lookWhileClosing(processes) : lookWhileStarting(processes, watching: watching) else { break }
            let waitsForWindow = !windowed && !log.started.isEmpty
            triggers.tick(!log.hasEnded && (watching || waitsForWindow), every: watching ? Self.windowPoll : Self.slowWindowPoll)
            trace.note("\(now.phase) " + LaunchTrace.programs(processes))
            if let progress, now != last { progress(now) }
            last = now
        }
        triggers.stop()
        trace.note("launch over")
    }

    /// While Steam follows the game: what starts, and the window to bring forward. Nil once Steam
    /// has started nothing for the game, and nothing of the launch's has run, for `startLimit`.
    private mutating func lookWhileStarting(_ processes: [BottleProcesses.Entry], watching: Bool) -> Progress? {
        endedAt = nil
        closing = []
        if log.started.isEmpty {
            if !Launcher.leftovers(processes, before: initial ?? [], steamFolder: steamFolder).isEmpty {
                quietSince = clock.now
                triggers.wake(after: Self.startLimit)
            } else if clock.now - quietSince >= Self.startLimit {
                trace.note("Steam started nothing for the game")
                return nil
            }
        }
        let paths = Set(log.programs.map { $0.path.lowercased() })
        let tracked = Set(processes.filter { paths.contains($0.program) }.map(\.pid))
        if before == nil, !log.started.isEmpty { before = Set(processes.map(\.pid)).subtracting(tracked) }
        let wasWindowed = windowed
        if !windowed, watching || !log.started.isEmpty { windowed = BottleProcesses.hasWindowOnScreen(pids: tracked) }
        // A window found after `windowWatch` comes forward too: macOS opens it behind.
        let front = watching || windowed != wasWindowed ? frontWindow(processes, tracked: tracked) : nil
        return Progress(phase: startingPhase(), front: front)
    }

    private mutating func startingPhase() -> Launcher.LaunchPhase {
        let newest = log.programs.last ?? log.started.last
        if stuck != nil, log.started.dropFirst(stuckAfter).contains(where: { $0.path.lowercased().contains(#"\steamapps\common\"#) }) {
            // The launcher started the game after all.
            stuck = nil
            trace.note("the game started after all")
        } else if stuck == nil, stuckAfter == 0, newest != nil, lostService.update() {
            // It fails within seconds of the launcher starting, while windows are looked for.
            stuck = name(RockstarLauncher.launcherProgram)
            stuckAfter = log.started.count
        }
        if let stuck { return .stuck(stuck) }
        if windowed { return .playing }
        if let newest { return .starting(name(newest.path)) }
        return .steam
    }

    /// The frontmost of the game's windows, else (before Steam starts the game) one Steam opened.
    private func frontWindow(_ processes: [BottleProcesses.Entry], tracked: Set<pid_t>) -> pid_t? {
        if let owner = BottleProcesses.frontWindowOwner(among: tracked) { return owner }
        guard log.started.isEmpty else { return nil }
        let steam = Set(processes.filter(Launcher.isSteamInterface).map(\.pid))
        return BottleProcesses.frontWindowOwner(among: steam, excluding: steamWindows)
    }

    /// After Steam ended the game: what started with it and still runs. Nil once nothing does, or
    /// after `closingLimit`.
    private mutating func lookWhileClosing(_ processes: [BottleProcesses.Entry]) -> Progress? {
        windowed = false
        let ended = endedAt ?? clock.now
        if endedAt == nil {
            endedAt = ended
            triggers.wake(after: Self.closingLimit)
        }
        let left = Launcher.leftovers(processes, before: before ?? initial ?? [], steamFolder: steamFolder)
        if left.isEmpty || clock.now - ended >= Self.closingLimit { return nil }
        triggers.watchExits(of: Set(left.map(\.pid)))
        let running = left.map { name($0.program) }
        for program in running where !closing.contains(program) { closing.append(program) }
        return Progress(phase: .closing(closing.filter(running.contains)), front: nil)
    }

    /// `Launcher.programName`, read once per program.
    private mutating func name(_ path: String) -> String {
        let key = path.lowercased()
        if let known = names[key] { return known }
        let found = Launcher.programName(path, prefix: prefix)
        names[key] = found
        return found
    }
}
