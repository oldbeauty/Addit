import Foundation

/// One run of some async work per key, shared by everyone who asks for that
/// key while it's in flight.
///
/// Built for track downloads (`AudioCacheService.cacheTrack`). The moment a
/// track starts, the gapless preload and the prefetch both ask for the one
/// after it, and each used to download it separately: two copies of one file
/// racing over the same connection, which on a weak one is exactly where the
/// preload could least afford to get half of it.
///
/// Cancelling a caller lets only that caller go. It gets `CancellationError`
/// at once, and the work carries on for whoever else is waiting. Once nobody
/// is, the work is cancelled, but only after `grace`, because the usual way
/// to stop waiting on a download is to ask for it again straight away: at a
/// track boundary with nothing staged, `next()` cancels the preload and the
/// boundary's own load asks for the same file a moment later. That load
/// should pick up the bytes already on their way, not start the file over.
final class SharedTasks<Key: Hashable & Sendable, Value: Sendable> {
    private final class Run {
        var task: Task<Void, Never>?
        var waiters: [Int: CheckedContinuation<Value, any Error>] = [:]
    }

    private var runs: [Key: Run] = [:]
    private var nextWaiter = 0
    private let grace: Duration

    init(grace: Duration = .seconds(2)) {
        self.grace = grace
    }

    /// The result of the run in flight for `key`, or of a new one started with
    /// `work` if there isn't one.
    func join(_ key: Key, _ work: @escaping () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let run = runs[key] ?? start(key, work)
        let waiter = nextWaiter
        nextWaiter &+= 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.waiters[waiter] = continuation
            }
        } onCancel: {
            // Runs wherever the cancel came from; the bookkeeping is ours.
            Task { @MainActor in self.leave(waiter, run: run, key: key) }
        }
    }

    private func start(_ key: Key, _ work: @escaping () async throws -> Value) -> Run {
        let run = Run()
        runs[key] = run
        run.task = Task {
            let result: Result<Value, any Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            // Out of the table before anyone hears, so nobody can join a run
            // that has already finished.
            if runs[key] === run { runs[key] = nil }
            let waiters = run.waiters
            run.waiters = [:]
            for continuation in waiters.values {
                continuation.resume(with: result)
            }
        }
        return run
    }

    private func leave(_ waiter: Int, run: Run, key: Key) {
        // Nothing to do if the run finished before the cancel got here: its
        // result has already been handed over.
        guard let continuation = run.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        guard run.waiters.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: grace)
            guard run.waiters.isEmpty, runs[key] === run else { return }
            runs[key] = nil
            run.task?.cancel()
        }
    }
}
