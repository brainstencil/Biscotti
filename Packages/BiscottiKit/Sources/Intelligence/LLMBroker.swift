import Foundation
import LocalLLM
import os
import Synchronization

/// Who is asking for the model. A higher priority runs first among waiting
/// requests; a running lease is never interrupted.
public enum LLMPriority: Int, Comparable, Sendable {
    /// `Intelligence` analysis: summary, title and speaker names.
    case background = 0
    /// Chat.
    case interactive = 1

    public static func < (lhs: LLMPriority, rhs: LLMPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What happens to the connection when a lease ends.
public enum LLMKeepAlive: Sendable, Equatable {
    /// Close after this long with no new lease.
    case keepOpen(Duration)
    /// Close as soon as no lease is waiting.
    case close
}

/// Why a request is not running yet, reported while it waits.
public enum LLMWait: Sendable, Equatable {
    /// Waiting for the running lease, named by its purpose (e.g. "summary").
    case queued(behind: String)
    /// The model is loading.
    case loadingModel
}

public enum LLMBrokerError: LocalizedError, Equatable, Sendable {
    /// There is no model to load. For callers that resolve the model URL
    /// before they ask for a lease.
    case modelUnavailable
    /// The model could not be loaded. Carries the opener error's
    /// localized description.
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable: "No AI model is downloaded."
        case let .connectionFailed(reason): reason
        }
    }
}

/// Opens a connection to the model that stays open until it is closed.
/// Production: `LiveLLMConnectionOpener`; tests: scripted fakes.
public protocol LLMConnectionOpening: Sendable {
    func open(model: URL, config: EngineConfig) async throws -> any LLMOpenSession
}

/// An `LLMSession` that the broker can close.
public protocol LLMOpenSession: LLMSession {
    func close() async
}

/// Owns the app's one connection to the local model and lends it to one job
/// at a time.
///
/// Every connection to `BiscottiLLM.xpc` loads its own copy of the model, so
/// chat and `Intelligence` share this broker instead of opening their own.
/// Waiting requests run in priority order, first come first served within a
/// priority. After a lease, the connection stays open for the lease's
/// keep-alive, so a follow-up job reuses the loaded model and the KV cache of
/// its shared prompt prefix.
public actor LLMBroker {
    private struct Connection {
        let id: UInt64
        let session: any LLMOpenSession
        let model: URL
        /// The context size the session was last reconfigured to, or nil when
        /// unknown (a fresh model-only load, or a failed reconfigure).
        var contextSize: Int?
    }

    private struct Lease {
        let purpose: String
        let priority: LLMPriority
        let keepAlive: LLMKeepAlive
    }

    private struct Waiter {
        let id: UInt64
        let lease: Lease
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let opener: any LLMConnectionOpening
    private let defaultKeepAlive: LLMKeepAlive
    private let clock: any Clock<Duration>
    private let logger = Logger(subsystem: "net.scosman.biscotti", category: "llm-broker")

    private var connection: Connection?
    private var running: Lease?
    /// Sorted by priority (highest first), then by arrival.
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0
    private var idleClose: Task<Void, Never>?
    /// Set by `closeWhenIdle()` while a lease runs: close when the broker is
    /// next idle.
    private var closeRequested = false

    public init(
        opener: any LLMConnectionOpening,
        defaultKeepAlive: LLMKeepAlive = .keepOpen(.seconds(180)),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.opener = opener
        self.defaultKeepAlive = defaultKeepAlive
        self.clock = clock
    }

    /// The purpose of the running lease, or nil when idle. For status text.
    public var runningPurpose: String? {
        running?.purpose
    }

    /// The purposes of the waiting requests, next to run first.
    var waitingPurposes: [String] {
        waiters.map(\.lease.purpose)
    }

    /// Runs `body` with exclusive use of a loaded session for `model`.
    ///
    /// Waits behind the running lease and behind waiting requests of equal or
    /// higher priority. Opens the connection if none is open, or reopens it if
    /// the model URL differs. The session's `reconfigure(contextSize:)` is
    /// skipped when the size is unchanged, so the KV cache survives.
    ///
    /// A stream `body` starts reading should be read to its end (until it
    /// returns nil or throws). If it is not, for example because the task was
    /// cancelled between pulls or the body stopped at `.done`, the connection
    /// is closed when the lease ends and the next lease reloads the model.
    ///
    /// - Parameter keepAlive: What to do with the connection when this lease
    ///   ends and nobody waits. Nil uses the broker's default.
    /// - Throws: `CancellationError` if the caller is cancelled while waiting
    ///   (it leaves the queue); `LLMBrokerError.connectionFailed` if the model
    ///   cannot load; anything `body` throws.
    public func withLease<T: Sendable>(
        model: URL,
        priority: LLMPriority,
        purpose: String,
        keepAlive: LLMKeepAlive? = nil,
        onWait: @escaping @Sendable (LLMWait) -> Void = { _ in },
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T {
        let lease = Lease(purpose: purpose, priority: priority, keepAlive: keepAlive ?? defaultKeepAlive)
        let requested = ContinuousClock.now
        try await acquire(lease, onWait: onWait)
        guard !Task.isCancelled else {
            await endLease(lease, dropReason: nil)
            throw CancellationError()
        }
        let started = ContinuousClock.now
        logger.info("Lease start: \(purpose, privacy: .public), priority \(priority.rawValue), waited \(Self.milliseconds(started - requested)) ms")

        let streams = StreamLedger()
        let session: BrokerSession
        do {
            session = try await connectedSession(model: model, streams: streams, onWait: onWait)
        } catch {
            await endLease(lease, dropReason: nil)
            throw error
        }

        do {
            let result = try await body(session)
            logger.info("Lease end: \(purpose, privacy: .public) after \(Self.milliseconds(.now - started)) ms")
            await endLease(lease, dropReason: Self.dropReason(error: nil, streams: streams))
            return result
        } catch {
            logger.info("Lease end: \(purpose, privacy: .public) after \(Self.milliseconds(.now - started)) ms with \(String(describing: type(of: error)), privacy: .public)")
            await endLease(lease, dropReason: Self.dropReason(error: error, streams: streams))
            throw error
        }
    }

    /// Closes the connection now, or, while a lease runs or waits, as soon as
    /// the broker is next idle. Returns without waiting for that lease.
    public func closeWhenIdle() async {
        cancelIdleClose()
        guard running == nil else {
            closeRequested = true
            return
        }
        await closeConnection(reason: "requested")
    }

    // MARK: - Queue

    /// Returns once `lease` is the running lease.
    private func acquire(
        _ lease: Lease, onWait: @escaping @Sendable (LLMWait) -> Void
    ) async throws {
        let mustWait = running != nil
            || waiters.contains { $0.lease.priority >= lease.priority }
        guard mustWait else {
            running = lease
            cancelIdleClose()
            return
        }

        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                insert(Waiter(id: id, lease: lease, continuation: continuation))
                if let running {
                    onWait(.queued(behind: running.purpose))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func insert(_ waiter: Waiter) {
        let index = waiters.firstIndex { $0.lease.priority < waiter.lease.priority }
            ?? waiters.endIndex
        waiters.insert(waiter, at: index)
    }

    private func cancelWaiter(id: UInt64) {
        // Absent when the waiter was already handed the lease; `withLease`
        // then sees the cancellation and gives the lease up.
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Ends the running lease: closes the connection when `dropReason` is
    /// set, then hands the lease to the first waiter, or applies the ended
    /// lease's keep-alive when nobody waits.
    private func endLease(_ lease: Lease, dropReason: String?) async {
        if let dropReason {
            await closeConnection(reason: dropReason)
        }

        guard waiters.isEmpty else {
            // The next lease is marked running before its task wakes, so a
            // request arriving in between queues behind it.
            let next = waiters.removeFirst()
            running = next.lease
            next.continuation.resume()
            return
        }

        running = nil
        if closeRequested || lease.keepAlive == .close {
            closeRequested = false
            await closeConnection(reason: "lease ended")
        } else if case let .keepOpen(delay) = lease.keepAlive, connection != nil {
            cancelIdleClose()
            idleClose = makeIdleClose(after: delay)
        }
    }

    // MARK: - Connection

    private func connectedSession(
        model: URL, streams: StreamLedger, onWait: @Sendable (LLMWait) -> Void
    ) async throws -> BrokerSession {
        if let connection, connection.model == model {
            return BrokerSession(broker: self, connectionID: connection.id, session: connection.session, streams: streams)
        }
        await closeConnection(reason: "model changed")

        onWait(.loadingModel)
        let started = ContinuousClock.now
        let session: any LLMOpenSession
        do {
            session = try await opener.open(model: model, config: .modelOnly)
        } catch let error as CancellationError {
            throw error
        } catch {
            logger.error("Model open failed: \(String(describing: type(of: error)), privacy: .public): \(error.localizedDescription, privacy: .private)")
            throw LLMBrokerError.connectionFailed(error.localizedDescription)
        }

        let id = nextID
        nextID += 1
        connection = Connection(id: id, session: session, model: model)
        logger.info("Model opened: \(model.lastPathComponent, privacy: .public) in \(Self.milliseconds(.now - started)) ms")
        return BrokerSession(broker: self, connectionID: id, session: session, streams: streams)
    }

    /// Reconfigures the leased session unless it already has `contextSize`.
    fileprivate func reconfigure(contextSize: Int, connectionID: UInt64) async throws {
        guard let current = connection, current.id == connectionID else {
            throw LLMServiceError.connectionClosed
        }
        if current.contextSize == contextSize {
            logger.debug("Reconfigure skipped: context already \(contextSize)")
            return
        }
        // The old KV cache is gone once a reconfigure starts, even if it fails.
        connection?.contextSize = nil
        try await current.session.reconfigure(contextSize: contextSize)
        if connection?.id == connectionID {
            connection?.contextSize = contextSize
        }
        logger.info("Reconfigured context to \(contextSize)")
    }

    private func closeConnection(reason: String) async {
        guard let closing = connection else { return }
        // Cleared before the await, so a lease that starts meanwhile opens a
        // fresh connection instead of using the closing one.
        connection = nil
        logger.info("Closing model connection: \(reason, privacy: .public)")
        await closing.session.close()
    }

    // MARK: - Idle close

    private func makeIdleClose(after delay: Duration) -> Task<Void, Never> {
        let sleep = clock.sleeper(after: delay)
        return Task { [weak self] in
            do {
                try await sleep()
            } catch {
                return
            }
            await self?.closeAfterIdle()
        }
    }

    private func closeAfterIdle() async {
        // A lease that started after the timer fired has cancelled this task.
        guard !Task.isCancelled, running == nil else { return }
        idleClose = nil
        await closeConnection(reason: "idle")
    }

    private func cancelIdleClose() {
        idleClose?.cancel()
        idleClose = nil
    }

    // MARK: - Helpers

    /// Why the connection must be closed when a lease ends, or nil to keep it.
    ///
    /// A stream pulled but not read to its end closes the connection, even
    /// after a cancellation: `LLMConnection` holds its one-slot gate from a
    /// stream's first pull until the stream ends, and a consumer cancelled
    /// between pulls never reaches that end. The gate then stays held, the
    /// service keeps generating, and every later call on the connection waits
    /// forever. Closing it stops the generation and frees the next lease to
    /// reconnect.
    private static func dropReason(error: (any Error)?, streams: StreamLedger) -> String? {
        if streams.hasUnfinished {
            return "a stream was not read to its end"
        }
        // Cancellation leaves the connection healthy; any other error may
        // mean the service is gone, so the next lease reconnects.
        if let error, !(error is CancellationError || (error as? LLMServiceError) == .cancelled) {
            return "lease failed"
        }
        return nil
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }
}

/// The session a lease's body sees: forwards to the open session, routes
/// `reconfigure` through the broker so an unchanged size is skipped, and
/// records in `streams` whether each stream was read to its end.
private struct BrokerSession: LLMSession {
    let broker: LLMBroker
    let connectionID: UInt64
    let session: any LLMOpenSession
    let streams: StreamLedger

    func countTokens(messages: [LLMMessage]) async throws -> Int {
        try await session.countTokens(messages: messages)
    }

    func reconfigure(contextSize: Int) async throws {
        try await broker.reconfigure(contextSize: contextSize, connectionID: connectionID)
    }

    func generate(
        messages: [LLMMessage], options: GenerationOptions
    ) async throws -> String {
        try await session.generate(messages: messages, options: options)
    }

    func generateStreaming(
        messages: [LLMMessage], options: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error> {
        let reader = await StreamReader(
            session.generateStreaming(messages: messages, options: options),
            streams: streams
        )
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }
}

/// Counts a lease's streams that were pulled at least once but not read to
/// their end. A stream never pulled has not taken the connection's gate.
private final class StreamLedger: Sendable {
    private let unfinished = Mutex(0)

    var hasUnfinished: Bool {
        unfinished.withLock { $0 > 0 }
    }

    func started() {
        unfinished.withLock { $0 += 1 }
    }

    func ended() {
        unfinished.withLock { $0 -= 1 }
    }
}

/// Reads one inner stream and tells the ledger when reading starts and when
/// the inner stream ends (returns nil or throws). If the consumer is
/// cancelled between pulls, the outer stream stops calling `next`, so the
/// end is never recorded.
///
/// `@unchecked Sendable`: `AsyncThrowingStream(unfolding:)` never calls its
/// closure concurrently, so `iterator` and `phase` see one pull at a time.
private final class StreamReader: @unchecked Sendable {
    private enum Phase { case notStarted, reading, ended }

    private var iterator: AsyncThrowingStream<StreamEvent, Error>.AsyncIterator
    private let streams: StreamLedger
    private var phase = Phase.notStarted

    init(_ stream: AsyncThrowingStream<StreamEvent, Error>, streams: StreamLedger) {
        iterator = stream.makeAsyncIterator()
        self.streams = streams
    }

    func next() async throws -> StreamEvent? {
        if phase == .notStarted {
            phase = .reading
            streams.started()
        }
        do {
            guard let event = try await iterator.next() else {
                end()
                return nil
            }
            return event
        } catch {
            end()
            throw error
        }
    }

    private func end() {
        guard phase == .reading else { return }
        phase = .ended
        streams.ended()
    }
}

private extension Clock where Duration == Swift.Duration {
    /// A sleep that ends `delay` after now. The deadline is taken when this is
    /// called, not when the sleep starts, so the idle period starts when the
    /// lease ends even if the sleeping task runs later.
    func sleeper(after delay: Duration) -> @Sendable () async throws -> Void {
        let deadline = now.advanced(by: delay)
        return { try await sleep(until: deadline, tolerance: nil) }
    }
}
