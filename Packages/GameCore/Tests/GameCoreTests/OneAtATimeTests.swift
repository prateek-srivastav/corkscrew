import Testing
@testable import GameCore

@MainActor
struct OneAtATimeTests {
    /// Quick clicks on Reports while a check runs wait for it; none starts a second check.
    @Test func callsWhileItRunsWaitForThatRun() async {
        let one = OneAtATime()
        let probe = Probe()
        let work: @MainActor () async -> Void = {
            probe.runs += 1
            await probe.gate()
            probe.done = true
        }
        let first = Task { await one.run(work) }
        while probe.runs == 0 { await Task.yield() }
        let others = (0..<3).map { _ in
            Task {
                probe.entered += 1
                await one.run(work)
                // A waiter returns only once the run it waited for is done.
                return probe.done
            }
        }
        // Each one checks for the running work before it first waits.
        while probe.entered < 3 { await Task.yield() }
        probe.open()
        _ = await first.value
        for other in others { #expect(await other.value) }
        #expect(probe.runs == 1)

        // Once it's done, the next click checks again.
        await one.run(work)
        #expect(probe.runs == 2)
    }

    @Test func runsAgainAfterEachRun() async {
        let one = OneAtATime()
        let probe = Probe()
        for _ in 0..<3 { await one.run { probe.runs += 1 } }
        #expect(probe.runs == 3)
    }
}

@MainActor
private final class Probe {
    var runs = 0
    var entered = 0
    var done = false
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func gate() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
