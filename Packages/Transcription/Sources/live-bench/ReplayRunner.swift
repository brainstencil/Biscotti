import Foundation
import LiveTranscriptModel
import Synchronization

/// One line of `events.jsonl`.
struct EventRecord: Encodable {
    /// Source time: the end of the audio released when the update was logged.
    var tRelease: TimeInterval
    /// Seconds on the monotonic clock since the replay started.
    var tEvent: TimeInterval
    var update: LiveTrackUpdate
}

/// `final.json`: what `finish(timeout:)` returned and how long it took.
struct FinalRecord: Encodable {
    var tRelease: TimeInterval
    var tEvent: TimeInterval
    var finishSeconds: TimeInterval
    /// True when the session had ended before `finish` was called: the engine failed.
    var sessionEndedEarly: Bool
    var updates: [LiveTrackUpdate]
}

/// What a replay needs from the session beyond the protocol.
struct SessionControl {
    /// Runs one scheduler pass; used only on a virtual clock.
    let runPass: @Sendable () async -> Void
    /// The revision of the latest update sent.
    let latestRevision: @Sendable () async -> Int
    /// True once the session has ended by itself, which before `finish` means it failed.
    let hasEnded: @Sendable () async -> Bool
    /// Makes the session's finish deadline, `timeout` after `finish` began,
    /// pass. A virtual clock does not move while finishing, so the replay
    /// moves it once the deadline has passed in real time.
    let expireFinishDeadline: @Sendable (_ timeout: Duration) -> Void
}

/// Plays one clip into a started session and logs every update it sends.
struct ReplayRunner {
    static let finishTimeout = Duration.seconds(10)

    let session: any LiveTranscriptionSession
    let control: SessionControl
    /// A simulated source also drives the session's scheduler; a real-time
    /// session schedules itself.
    let source: PacedSource
    let clip: ClipAudio
    let mode: BenchMode
    var finishTimeout = Self.finishTimeout

    /// - Returns: How long `finish(timeout:)` took, in seconds.
    @discardableResult
    func run(events: JSONLinesWriter, finalURL: URL) async throws -> Double {
        let start = ContinuousClock.now
        let reader = UpdateReader()
        let readTask = Task { [session, source] in
            defer { reader.finish() }
            for await update in session.updates {
                let event = EventRecord(tRelease: source.releasedThrough, tEvent: start.duration(to: .now).seconds, update: update)
                try events.write(event)
                reader.didRead(update.revision)
            }
        }
        do {
            try await feed(reader: reader)
        } catch {
            await session.cancel()
            _ = try? await readTask.value
            throw error
        }
        let sessionEndedEarly = await control.hasEnded()
        let finishStart = ContinuousClock.now
        let deadline = Task { [control, finishTimeout] in
            try await Task.sleep(for: finishTimeout)
            control.expireFinishDeadline(finishTimeout)
        }
        let updates = await session.finish(timeout: finishTimeout)
        deadline.cancel()
        let finishSeconds = finishStart.duration(to: .now).seconds
        try await readTask.value
        let record = FinalRecord(
            tRelease: source.releasedThrough,
            tEvent: start.duration(to: .now).seconds,
            finishSeconds: finishSeconds,
            sessionEndedEarly: sessionEndedEarly,
            updates: updates
        )
        try BenchJSON.write(record, to: finalURL)
        return finishSeconds
    }

    private func feed(reader: UpdateReader) async throws {
        var assembler = ChunkAssembler(mode: mode)
        // A session that ended by itself has failed; replaying the rest of a
        // long clip into it would only pass time.
        while await !hasStopped(reader), try await source.releaseNextStep() {
            for chunk in assembler.take(releasedSamples: source.releasedSamples, of: clip) {
                await session.append(chunk)
            }
            if source.isSimulated {
                await control.runPass()
                // Time moves on only once every update of this pass is logged
                // with this step's source time.
                await reader.waitUntilRead(control.latestRevision())
            }
        }
        // An ended session takes no more audio.
        guard await !hasStopped(reader) else { return }
        for chunk in assembler.flush(clip) {
            await session.append(chunk)
        }
    }

    /// Asks the session itself, not only whether the reader has seen the
    /// stream end: the reader task may not have run yet.
    private func hasStopped(_ reader: UpdateReader) async -> Bool {
        if reader.isFinished {
            return true
        }
        return await control.hasEnded()
    }
}

/// Tracks how far the update reader has got, so a virtual-clock replay can wait for it.
final class UpdateReader: Sendable {
    private struct State {
        var revision = 0
        var isFinished = false
        var waiters: [(revision: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var isFinished: Bool {
        state.withLock { $0.isFinished }
    }

    func didRead(_ revision: Int) {
        resumeWaiters { $0.revision = max($0.revision, revision) }
    }

    /// The stream ended: nobody waits for revisions that will never come.
    func finish() {
        resumeWaiters { $0.isFinished = true }
    }

    func waitUntilRead(_ revision: Int) async {
        await withCheckedContinuation { continuation in
            let isDone = state.withLock { state in
                guard state.revision < revision, !state.isFinished else { return true }
                state.waiters.append((revision, continuation))
                return false
            }
            if isDone {
                continuation.resume()
            }
        }
    }

    private func resumeWaiters(after change: (inout State) -> Void) {
        let ready = state.withLock { state in
            change(&state)
            let current = state.revision
            let isFinished = state.isFinished
            let ready = state.waiters.filter { isFinished || $0.revision <= current }
            state.waiters.removeAll { isFinished || $0.revision <= current }
            return ready.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
