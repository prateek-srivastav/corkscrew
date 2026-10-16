import AppKit
import Foundation
import GameCore
import Observation

/// Installs a game from a download (zip, rar, 7z, a disc image) into a bottle, one download at a
/// time: unpack it into the bottle, put a disc image in the bottle's drive (or unpack it too), run
/// the setup, then add what it installed to the library and delete the setup files.
@Observable
final class ProgramInstaller {
    /// One download on its way into a bottle.
    struct Job: Identifiable {
        enum Step: Equatable {
            /// Asks for the bottle, and whether to keep the original file.
            case choose
            case unpacking(Double)
            /// The download has disc images: put them in the drive, or unpack them?
            case disc([URL])
            case preparingDisc(mounting: Bool)
            /// Which program to run: the setup, or the game itself when there's none.
            case pickSetup([SetupFinder.Candidate])
            case runningSetup
            /// Setup ended: the programs it installed, most likely first (maybe none).
            case pickProgram([URL])
            case finishing
            case failed(String)
        }

        /// What happens to the file the user picked.
        enum Original { case copy, move }

        let id = UUID()
        /// Every part of the download, first part first; one file unless it was split.
        let parts: [URL]
        let size: Int64
        var bottleID: Bottle.ID?
        var original: Original = .copy
        var step: Step = .choose
        /// Shown above the step: why setup is offered again, and the like.
        var note: String?
        var discs: [DiscImage.Mounted] = []
        var candidates: [SetupFinder.Candidate] = []
        /// The bottle's programs and shortcuts before the setup ran.
        var snapshot: [String: Date] = [:]
        var setup: Game?
        /// The original file is gone (moved in and used up): cancelling now loses the download.
        var originalDeleted = false

        var source: URL { parts[0] }
        /// A disc image picked on its own, not an archive.
        var isDiscImage: Bool { parts.count == 1 && Archive.isDiscImage(source) }
        /// "Game" for Game.part1.rar, Game.7z.001 or Game.iso.
        var name: String { ProgramInstaller.displayName(of: source) }
        var isWorking: Bool {
            switch step {
            case .unpacking, .preparingDisc, .runningSetup, .finishing: true
            default: false
            }
        }
    }

    @ObservationIgnored private unowned let model: AppModel
    private(set) var job: Job?
    /// Whether the install sheet is up; hidden while a long step runs, the activity bar brings it back.
    var isShown = false
    /// Downloads waiting their turn, by first part, with the bottle they were dropped on.
    @ObservationIgnored private var queue: [(parts: [URL], bottle: Bottle.ID?)] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    var bottle: Bottle? { job.flatMap { job in model.programBottles.first { $0.id == job.bottleID } } }
    private var prefix: URL? { bottle.map { BottleLocation(bottleID: $0.id, paths: model.paths).prefix } }
    private var setupFolder: URL? { job.flatMap { job in prefix.map { SetupFinder.setupFolder(prefix: $0, id: job.id) } } }

    // MARK: Queue

    /// Takes downloads in; several picked parts of one split archive are one download.
    func enqueue(_ urls: [URL], bottle: Bottle?) {
        for url in urls {
            let parts: [URL]
            do { parts = try Archive.parts(of: url) } catch {
                model.errorMessage = "\(url.lastPathComponent): \(AppModel.describe(error))"
                continue
            }
            let known = queue.map(\.parts.first) + [job?.source]
            guard !known.contains(parts.first) else { continue }
            queue.append((parts, bottle?.id))
        }
        if job == nil { startNext() }
    }

    private func startNext() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        var job = Job(parts: next.parts, size: Archive.size(of: next.parts))
        job.bottleID = model.programBottles.first { $0.id == next.bottle }?.id
            ?? model.programBottles.first { $0.role == .sandbox }?.id ?? model.programBottles.first?.id
        self.job = job
        isShown = true
    }

    /// Space left where bottles live, in bytes.
    var freeSpace: Int64? {
        (try? model.paths.bottles.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    // MARK: Steps

    func setBottle(_ id: Bottle.ID?) { job?.bottleID = id }
    func setOriginal(_ original: Job.Original) { job?.original = original }

    /// From the first step: unpack the download (a disc image goes straight to the disc question).
    func start() {
        guard let job, let folder = setupFolder else { return }
        if job.isDiscImage {
            self.job?.step = .disc(job.parts)
            return
        }
        self.job?.step = .unpacking(0)
        let parts = job.parts
        let deletesOriginal = job.original == .move
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                if case .unpacking = self?.job?.step { self?.job?.step = .unpacking(fraction) }
            }
        }
        run { [weak self] in
            try await Self.offMain {
                var reported = -1.0
                try Archive.extract(parts, to: folder) { fraction in
                    // Every 0.5%: the archive reports each block it reads.
                    guard fraction - reported >= 0.005 || fraction == 1 else { return }
                    reported = fraction
                    report(fraction)
                }
            }
            // Moved in: the original goes as soon as its files are out, to free the space.
            if deletesOriginal { self?.deleteOriginal() }
            self?.inspect()
        }
    }

    /// The unpacked download: ask about disc images, else offer its programs.
    private func inspect() {
        guard let folder = setupFolder else { return }
        let discs = SetupFinder.discImages(in: folder)
        if !discs.isEmpty {
            job?.step = .disc(discs)
        } else {
            offerPrograms(in: [folder])
        }
    }

    /// `mount`: put the discs in the bottle's drive; otherwise copy their files out first.
    func useDiscs(_ images: [URL], mount: Bool) {
        guard let job, let prefix, let folder = setupFolder else { return }
        self.job?.step = .preparingDisc(mounting: mount)
        let deletesOriginal = job.isDiscImage && job.original == .move
        run { [weak self] in
            if mount {
                let mounted = try await Self.offMain { try DiscImage.attach(images, prefix: prefix) }
                self?.job?.discs = mounted
                self?.offerPrograms(in: mounted.map(\.mountPoint) + [folder])
            } else {
                try await Self.offMain {
                    for image in images {
                        let target = images.count == 1 ? folder : folder.appending(path: image.deletingPathExtension().lastPathComponent)
                        try Archive.extract([image], to: target)
                        // Our own copy goes now; the user's picked image only when they chose Move.
                        if image.path.hasPrefix(folder.path + "/") { try? FileManager.default.removeItem(at: image) }
                    }
                }
                if deletesOriginal { self?.deleteOriginal() }
                self?.offerPrograms(in: [folder])
            }
        }
    }

    private func offerPrograms(in folders: [URL]) {
        let candidates = SetupFinder.candidates(in: folders)
        guard !candidates.isEmpty else {
            job?.step = .failed("There's no Windows program (.exe or .msi) in \(job?.name ?? "the download").")
            return
        }
        job?.candidates = candidates
        job?.step = .pickSetup(candidates)
    }

    /// Runs the setup, or (a game without one) keeps the game's files and adds it.
    func choose(_ candidate: SetupFinder.Candidate) {
        if candidate.isSetup { runSetup(candidate.url) } else { keepGame(candidate.url) }
    }

    private func runSetup(_ installer: URL) {
        guard let bottle, let prefix, let job else { return }
        self.job?.note = nil
        self.job?.step = .runningSetup
        let name = job.name
        // Programs show their Windows path, the one Wine started with its Mac path.
        let sources = [SetupFinder.setupFolder(prefix: prefix, id: job.id), DiscImage.folder(prefix: prefix)]
            .map { $0.path.lowercased().replacingOccurrences(of: "/", with: "\\") }
            + [#"c:\programdata\corkscrew\setup\"# + SetupFinder.setupFolder(prefix: prefix, id: job.id).lastPathComponent]
            + job.discs.map { $0.windowsRoot.lowercased() }
        run { [weak self] in
            guard let self else { return }
            self.job?.snapshot = await Self.offMain { SetupFinder.snapshot(prefix: prefix) }
            let setup = model.runSetup(installer, in: bottle, name: "Setup – \(name)")
            self.job?.setup = setup
            await model.session(for: setup)?.task?.value
            if case .failed(let message) = model.session(for: setup)?.status {
                self.job?.note = "The setup didn't start: \(message)"
                self.job?.step = .pickSetup(self.job?.candidates ?? [])
                return
            }
            // Some setups start another program from the download and quit; wait for those too.
            while await Self.offMain({ Self.isRunningFromDownload(prefix: prefix, sources: sources) }) {
                try await Task.sleep(for: .seconds(2))
            }
            finishSetup()
        }
    }

    /// The setup window is closed but something keeps running: go on anyway.
    func setupIsDone() {
        task?.cancel()
        finishSetup()
    }

    private func finishSetup() {
        guard let prefix, let job else { return }
        let programs = SetupFinder.installedPrograms(prefix: prefix, before: job.snapshot)
        self.job?.note = programs.isEmpty ? "The setup didn't install a program. Run it again, or pick the game's program yourself." : nil
        self.job?.step = .pickProgram(programs)
    }

    func runSetupAgain() {
        job?.note = nil
        job?.step = .pickSetup(job?.candidates ?? [])
    }

    /// Adds the installed program, then deletes the setup files.
    func add(_ program: URL, name: String) {
        guard let bottle else { return }
        job?.step = .finishing
        run { [weak self] in
            guard let self else { return }
            await cleanUp(deletingOriginal: true)
            // Installed again over itself: the library has it already.
            let path = program.standardizedFileURL.path.lowercased()
            if !model.games.contains(where: { $0.bottleID == bottle.id && $0.executable.standardizedFileURL.path.lowercased() == path }) {
                await model.addToLibrary(program, bottle: bottle, name: name.isEmpty ? nil : name)
            }
            done()
        }
    }

    /// A program the user finds themselves, on the bottle's drive.
    func chooseProgram() {
        guard let bottle else { return }
        guard let program = Pickers.file("Choose the game's program (.exe) in \(bottle.name).", extensions: ["exe"],
                                         in: model.driveC(of: bottle))
        else { return }
        let outside = [setupFolder, prefix.map(DiscImage.folder(prefix:))].compactMap { $0?.path }
        guard model.bottle(containing: program)?.id == bottle.id, !outside.contains(where: { program.path.hasPrefix($0 + "/") }) else {
            job?.note = "Pick a program inside \(bottle.name) that isn't one of the setup files."
            return
        }
        add(program, name: Game.defaultName(for: program))
    }

    /// A game that needs no setup: its folder moves out of the setup files to `C:\Games`.
    private func keepGame(_ program: URL) {
        guard let bottle, let prefix, let folder = setupFolder, let job else { return }
        self.job?.step = .finishing
        let name = job.name
        run { [weak self] in
            guard let self else { return }
            let kept: URL = try await Self.offMain {
                let fm = FileManager.default
                let games = prefix.appending(path: "drive_c/Games", directoryHint: .isDirectory)
                // The folder right below the setup files that holds the program, or all of them.
                let inside = SetupFinder.relativeComponents(of: program, in: folder)
                let source = inside.count > 1 ? folder.appending(path: inside[0]) : folder
                var target = games.appending(path: inside.count > 1 ? inside[0] : name)
                var number = 2
                while fm.fileExists(atPath: target.path) {
                    target = games.appending(path: "\(inside.count > 1 ? inside[0] : name) \(number)")
                    number += 1
                }
                try fm.createDirectory(at: games, withIntermediateDirectories: true)
                // Discs are read-only: their files are copied, everything else moves.
                if job.discs.contains(where: { program.path.hasPrefix($0.mountPoint.path + "/") }) {
                    let disc = job.discs.first { program.path.hasPrefix($0.mountPoint.path + "/") }!
                    let onDisc = SetupFinder.relativeComponents(of: program, in: disc.mountPoint)
                    let discSource = onDisc.count > 1 ? disc.mountPoint.appending(path: onDisc[0]) : disc.mountPoint
                    try fm.copyItem(at: discSource, to: target)
                    return onDisc.dropFirst(onDisc.count > 1 ? 1 : 0).reduce(target) { $0.appending(path: $1) }
                }
                try fm.moveItem(at: source, to: target)
                return inside.dropFirst(inside.count > 1 ? 1 : 0).reduce(target) { $0.appending(path: $1) }
            }
            await cleanUp(deletingOriginal: true)
            await model.addToLibrary(kept, bottle: bottle, name: Game.defaultName(for: kept))
            done()
        }
    }

    /// Stops the install and deletes its setup files.
    func cancel() {
        task?.cancel()
        if let setup = job?.setup, model.session(for: setup)?.isActive == true { model.stop(setup) }
        job?.step = .finishing
        Task {
            await cleanUp(deletingOriginal: false)
            done()
        }
    }

    /// Ends the install after its setup ran, without adding anything (the setup files go).
    func finishWithoutAdding() {
        job?.step = .finishing
        Task {
            await cleanUp(deletingOriginal: true)
            done()
        }
    }

    /// How the sheet names a program: `D:\Setup.exe` on a disc, `Game\setup.exe` in the setup
    /// files, `C:\Games\Game\Game.exe` on the bottle's drive.
    func displayPath(of file: URL) -> String {
        if let disc = job?.discs.first(where: { file.path.hasPrefix($0.mountPoint.path + "/") }) {
            return disc.windowsRoot + SetupFinder.relativeComponents(of: file, in: disc.mountPoint).joined(separator: "\\")
        }
        if let folder = setupFolder, file.path.hasPrefix(folder.path + "/") {
            return SetupFinder.relativeComponents(of: file, in: folder).joined(separator: "\\")
        }
        if let bottle {
            return "C:\\" + SetupFinder.relativeComponents(of: file, in: model.driveC(of: bottle)).joined(separator: "\\")
        }
        return file.lastPathComponent
    }

    func hide() { isShown = false }
    func show() { if job != nil { isShown = true } }

    // MARK: Helpers

    /// Ejects the discs and deletes the setup files; `deletingOriginal` (the install is done), with
    /// Move, also the disc image the user picked, which was used in place.
    private func cleanUp(deletingOriginal: Bool) async {
        guard let job, let prefix else { return }
        let folder = SetupFinder.setupFolder(prefix: prefix, id: job.id)
        let discs = job.discs
        await Self.offMain {
            DiscImage.detach(discs, prefix: prefix)
            try? FileManager.default.removeItem(at: folder)
        }
        if deletingOriginal, job.original == .move, !job.originalDeleted { deleteOriginal() }
        self.job?.discs = []
    }

    private func deleteOriginal() {
        guard let job else { return }
        for part in job.parts { try? FileManager.default.removeItem(at: part) }
        self.job?.originalDeleted = true
    }

    private func done() {
        job = nil
        isShown = false
        task = nil
        startNext()
    }

    /// Runs a step; an error ends it on the failed step, cancelling leaves the step to `cancel`.
    private func run(_ work: @escaping () async throws -> Void) {
        task?.cancel()
        task = Task {
            do { try await work() } catch is CancellationError {
            } catch {
                job?.step = .failed(AppModel.describe(error))
            }
        }
    }

    /// Slow work on another thread; cancelling the caller cancels it.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// Whether a program from the setup files or a disc runs in the bottle; `sources` are
    /// lowercased paths with backslashes.
    nonisolated private static func isRunningFromDownload(prefix: URL, sources: [String]) -> Bool {
        BottleProcesses.list(prefix: prefix).contains { entry in
            let program = (entry.arguments.first ?? "").lowercased().replacingOccurrences(of: "/", with: "\\")
            return sources.contains { program.hasPrefix($0) }
        }
    }

    /// "Game" for Game.part1.rar, Game.7z.001, Game.tar.gz or Game.iso.
    nonisolated static func displayName(of file: URL) -> String {
        var url = file
        while Archive.isArchive(url) || url.pathExtension.lowercased().wholeMatch(of: /part\d+/) != nil {
            url.deletePathExtension()
        }
        return url.lastPathComponent
    }
}
