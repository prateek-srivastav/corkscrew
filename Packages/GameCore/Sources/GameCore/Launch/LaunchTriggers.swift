import Foundation

/// What wakes a Steam game's launch, rather than a timer: Steam writing its log of the game's
/// programs (`SteamGameLog`), a program exiting, `wake()`, and while windows are looked for, a tick.
/// `events` yields once per wake; wakes that come while the launch is busy merge into one.
final class LaunchTriggers: @unchecked Sendable {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let file: URL
    // Everything below is used on `queue` only.
    private let queue = DispatchQueue(label: "app.corkscrew.launch-triggers")
    private var log: DispatchSourceFileSystemObject?
    private var exits: [pid_t: DispatchSourceProcess] = [:]
    private var ticker: DispatchSourceTimer?
    private var tickInterval: Duration?
    private var alarm: DispatchSourceTimer?

    init(watching file: URL) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.file = file
        queue.sync { watchLog() }
        continuation.onTermination = { [weak self] _ in self?.stop() }
    }

    func wake() { continuation.yield() }

    /// Wakes when one of `pids` exits; stops watching the others.
    func watchExits(of pids: Set<pid_t>) {
        queue.async { [self] in
            for (pid, source) in exits where !pids.contains(pid) {
                source.cancel()
                exits[pid] = nil
            }
            for pid in pids where exits[pid] == nil {
                let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
                source.setEventHandler { [weak self] in self?.wake() }
                source.resume()
                exits[pid] = source
                // It exited before the watch began.
                if kill(pid, 0) != 0, errno == ESRCH { wake() }
            }
        }
    }

    /// While `on`, wakes every `interval`.
    func tick(_ on: Bool, every interval: Duration) {
        queue.async { [self] in
            guard on else {
                ticker?.cancel()
                ticker = nil
                return
            }
            guard ticker == nil || tickInterval != interval else { return }
            ticker?.cancel()
            ticker = timer(after: interval, repeating: interval)
            tickInterval = interval
        }
    }

    /// Wakes once, after `delay`, in place of an earlier `wake(after:)`.
    func wake(after delay: Duration) {
        queue.async { [self] in
            alarm?.cancel()
            alarm = timer(after: delay, repeating: nil)
        }
    }

    func stop() {
        queue.async { [self] in
            for source in exits.values { source.cancel() }
            exits = [:]
            for source in [log, ticker, alarm] as [DispatchSourceProtocol?] { source?.cancel() }
            log = nil
            ticker = nil
            alarm = nil
        }
        continuation.finish()
    }

    /// Watches the log, or until it exists, its folder.
    private func watchLog() {
        log?.cancel()
        log = nil
        let exists = FileManager.default.fileExists(atPath: file.path)
        let descriptor = open((exists ? file : file.deletingLastPathComponent()).path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename],
                                                               queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            // The log appeared in its folder, or Steam started a new one.
            if !exists || !source.data.isDisjoint(with: [.delete, .rename]) { watchLog() }
            wake()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        log = source
    }

    private func timer(after delay: Duration, repeating interval: Duration?) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay / .seconds(1), repeating: interval.map { $0 / .seconds(1) } ?? .infinity)
        timer.setEventHandler { [weak self] in self?.wake() }
        timer.resume()
        return timer
    }
}
