/// Runs a piece of work one at a time: a call while it runs waits for that run instead of starting
/// another (quick clicks on Reports in the sidebar read the issues once). A call after it ends runs it again.
@MainActor
public final class OneAtATime {
    private var running: Task<Void, Never>?

    public init() {}

    public func run(_ work: @escaping @MainActor () async -> Void) async {
        if let running { return await running.value }
        let task = Task { @MainActor in
            await work()
            // Before the waiters resume, so a call that comes after them starts a new run.
            running = nil
        }
        running = task
        await task.value
    }
}
