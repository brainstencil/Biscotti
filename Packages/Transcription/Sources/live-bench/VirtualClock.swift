import Foundation
import Synchronization

/// A clock that moves only when the replay advances it, for `--virtual-clock`
/// runs: the session's scheduler and the source share it, so time passes in
/// 100 ms steps however long a decode really takes.
final class VirtualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        /// Sleeps cancelled before they were registered, so they end at once.
        var cancelledEarly: Set<UUID> = []
    }

    private let state = Mutex(State())

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration {
        .zero
    }

    /// Sleeps waiting for the clock to move.
    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }

    func sleep(until deadline: Instant, tolerance _: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelledEarly.remove(id) != nil {
                        return .failure(CancellationError())
                    }
                    guard deadline > state.now else { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome {
                    continuation.resume(with: outcome)
                }
            }
        } onCancel: {
            // The handler can run before the sleeper is registered; it then
            // leaves a note so the sleep ends instead of waiting for good.
            let cancelled = state.withLock { state in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelledEarly.insert(id)
                    return Sleeper?.none
                }
                return state.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }
}
