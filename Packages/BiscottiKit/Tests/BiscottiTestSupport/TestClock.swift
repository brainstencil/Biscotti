import Synchronization

/// A clock that moves only when the test calls `advance(by:)`.
///
/// A sleep resumes once the clock reaches its deadline; one whose deadline has
/// already passed returns at once, so a deadline taken before `advance` is
/// honored even if the sleeper registers after it.
public final class TestClock: Clock {
    public typealias Duration = Swift.Duration

    public struct Instant: InstantProtocol {
        public var offset: Swift.Duration

        public func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UInt64
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant {
        state.withLock { $0.now }
    }

    public var minimumResolution: Swift.Duration {
        .zero
    }

    /// Moves the clock forward and resumes every sleep that is now due.
    public func advance(by duration: Swift.Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    public func sleep(until deadline: Instant, tolerance _: Swift.Duration?) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case wait, resume, cancel }
                // Checked under the lock, so a cancellation that lands before
                // the sleeper is stored is never missed.
                let outcome = state.withLock { state -> Outcome in
                    if Task.isCancelled { return .cancel }
                    if deadline <= state.now { return .resume }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .wait
                }
                switch outcome {
                case .wait: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}
