---
status: complete
---

# Component: LLM broker

## Purpose and Scope

`LLMBroker` owns the app's single connection to the local model in `BiscottiLLM.xpc` and lends it to one job at a time. Chat and `Intelligence` (summary, title, speaker names) both go through it, so the model is never loaded twice. It keeps the connection open for a short idle period after a job, so a follow-up question reuses the loaded model and the KV cache of the shared prompt prefix.

Not its job: building prompts, counting what fits, choosing context sizes (callers do that), or deciding the memory policy (the chat service passes the keep-alive it wants).

Lives in `Intelligence`, next to `LLMRunning`, because `Intelligence` already owns model access and `MeetingChat` depends on `Intelligence`.

## Public Interface

```swift
/// Who is asking. Higher runs first among waiting requests; a running lease is never interrupted.
public enum LLMPriority: Int, Comparable, Sendable {
    case background = 0   // Intelligence analysis
    case interactive = 1  // chat
}

/// What happens to the connection when a lease ends.
public enum LLMKeepAlive: Sendable, Equatable {
    case keepOpen(Duration)  // close after this long with no new lease
    case close               // close as soon as no lease is waiting
}

/// Why a request is not running yet, reported while it waits.
public enum LLMWait: Sendable, Equatable {
    case queued(behind: String)  // the purpose of the running lease, e.g. "summary"
    case loadingModel
}

public enum LLMBrokerError: Error, Equatable, Sendable {
    case modelUnavailable        // no model URL
    case connectionFailed(String)
}

/// Opens a connection that stays open until closed. Real: LocalLLM's `LLMService.openConnection`
/// with the hosted backend; tests: scripted fakes.
public protocol LLMConnectionOpening: Sendable {
    func open(model: URL, config: EngineConfig) async throws -> any LLMOpenSession
}

/// An `LLMSession` that the broker can close.
public protocol LLMOpenSession: LLMSession {
    func close() async
}

public actor LLMBroker {
    public init(
        opener: any LLMConnectionOpening,
        defaultKeepAlive: LLMKeepAlive = .keepOpen(.seconds(180)),
        clock: any Clock<Duration> = ContinuousClock()
    )

    /// Runs `body` with exclusive use of a loaded session for `model`.
    /// Waits behind the running lease and behind waiting requests of equal or higher priority.
    /// Opens or reopens the connection if none is open or the model URL differs.
    /// - Throws: `CancellationError` if the caller is cancelled while waiting (it is removed
    ///   from the queue); `LLMBrokerError.connectionFailed` if the model cannot load;
    ///   anything `body` throws.
    public func withLease<T: Sendable>(
        model: URL,
        priority: LLMPriority,
        purpose: String,
        keepAlive: LLMKeepAlive? = nil,
        onWait: @escaping @Sendable (LLMWait) -> Void = { _ in },
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T

    /// The purpose of the running lease, or nil when idle. For status text.
    public var runningPurpose: String? { get }

    /// Loads `model` before anyone needs it, as a lease of its own with an empty body
    /// (it reports `.loadingModel`, requests made meanwhile wait for it, and `keepAlive`
    /// applies when it ends). Returns false without loading while a lease runs or waits,
    /// or when `model` is already loaded.
    public func loadAhead(
        model: URL, priority: LLMPriority, purpose: String,
        keepAlive: LLMKeepAlive? = nil,
        onWait: @escaping @Sendable (LLMWait) -> Void = { _ in }
    ) async throws -> Bool

    /// While true, a lease that ends with `.keepOpen` leaves the connection open with no
    /// idle close; `.close` leases and `closeWhenIdle()` still close it. Turning it off
    /// starts the idle close of the lease that ended last, from now.
    public func setKeepsModelLoaded(_ keeps: Bool)

    /// Closes the connection now, after the running lease if there is one.
    public func closeWhenIdle() async
}

/// `LLMRunning` for `Intelligence`: every `withSession` becomes a background lease.
public struct BrokeredLLMRunner: LLMRunning {
    public init(broker: LLMBroker, purpose: String = "summary")
    public func withSession<T: Sendable>(
        model: URL, config: EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T   // = broker.withLease(model:priority: .background, purpose:, body)
}

/// The production opener.
public struct LiveLLMConnectionOpener: LLMConnectionOpening {
    public init(serviceName: String = RuntimeConfiguration.current.llmServiceName)
}
```

## Internal Design

**State** (actor-isolated):
- `connection: (session: any LLMOpenSession, model: URL, contextSize: Int?)?`
- `running: (purpose: String, keepAlive: LLMKeepAlive)?`
- `waiters: [Waiter]`, where `Waiter = (id: UInt64, priority: LLMPriority, continuation: CheckedContinuation<Void, Error>)`, kept sorted by priority (descending), then by `id` (ascending, so FIFO within a priority).
- `idleClose: Task<Void, Never>?`, the pending idle close.

**`withLease`:**
1. If something is running, or any waiter outranks or equals this request, append a waiter and suspend on its continuation, reporting `.queued(behind: running.purpose)` through `onWait`. Cancellation uses `withTaskCancellationHandler`: the handler removes the waiter and resumes it with `CancellationError`.
2. When resumed (or immediately), mark `running` and cancel `idleClose`.
3. If `connection` is nil or its model differs from `model`, close the old one, report `.loadingModel`, and `opener.open(model:config: .modelOnly)`. A failure clears `running`, wakes the next waiter, and throws `connectionFailed`.
4. Wrap the session in `BrokerSession`, which forwards every call but skips `reconfigure(contextSize:)` when the size equals the cached `contextSize` (so the KV cache survives between turns of a thread) and records the new size otherwise.
5. Run `body`. Afterwards (`defer`-style, on success and error):
   - If `body` threw anything other than `CancellationError` or `LLMServiceError.cancelled`, close and drop the connection: the next lease reconnects to a fresh service.
   - Clear `running`. Resume the first waiter if there is one; otherwise apply the keep-alive: `.close` closes now, `.keepOpen(d)` schedules `idleClose` after `d` on `clock`.

**Keep-alive** is the lease's own value, or `defaultKeepAlive`. A later lease cancels a pending idle close. A model change in Settings is caught at the next lease by the URL comparison.

**Keeping the model loaded and loading ahead** (added 30 October 2026, Backlog B10). Chat's "Keep the AI model ready" setting needs the model to stay loaded after every lease, the summary's included, so the hold is the broker's, not a lease's: `setKeepsModelLoaded(true)` skips the idle close that a `.keepOpen` lease would schedule, and cancels a pending one. The memory rule still wins, because chat turns the hold off during a recording on Macs under 24 GB, and a `.close` lease or `closeWhenIdle()` closes the connection whatever the hold. Turning the hold off applies the last lease's keep-alive from that moment. `loadAhead` is how chat loads the model before a question: it checks that nothing runs or waits and that the model is not loaded, then takes a lease with an empty body. `withLease` takes the lease before its first suspension, so no request can start between the check and the load.

**Logging** (`Logger(subsystem: "net.scosman.biscotti", category: "llm-broker")`): lease start and end with purpose, priority and wait time; model opens with their duration and the purpose of the lease that loaded it ("Model opened: … in 31234 ms, for chat"), one line per load; the keep-loaded hold when it changes; reconfigures with the size; idle closes; dropped connections with the error's type, never prompt text.

## Changes outside the broker

- `AppCore+Live.buildModelAndIntelligence` creates one `LLMBroker(opener: LiveLLMConnectionOpener())` and passes `BrokeredLLMRunner(broker:)` to `Intelligence` in place of `LiveLLMRunner()`. `AppCore` keeps the broker (`public let llmBroker: LLMBroker`) for `MeetingChatService`.
- `LiveLLMRunner` stays for the manual-test app and CLI tools, which have no broker.
- `PreviewAppCore` uses a broker with a preview opener that returns empty streams.
- `CoreFixture` gains `llmBroker` built on `ScriptedLLMOpener` (see test plan) and wires `Intelligence` to it.

## Dependencies

- Depends on `LocalLLM` (`LLMService.openConnection`, `LLMConnection`, `EngineConfig`, `LLMServiceError`) and `BiscottiRuntime` (service name).
- Used by `Intelligence` (through `BrokeredLLMRunner`), `MeetingChatService` and `AppCore`.

## Test Plan (`IntelligenceTests/LLMBrokerTests.swift`)

Fakes in `BiscottiTestSupport`: `ScriptedLLMOpener` (counts opens and closes, can fail an open, hands out `ScriptedSession`s) and `ScriptedSession` (records calls, streams scripted tokens with optional per-token delay, can throw or end without `.done`). Time uses a test clock.

- `leaseOpensTheModelOnce`: two sequential leases on one model open once and close zero times before the idle period.
- `idleCloseAfterKeepAlive`: after the last lease, advancing the clock by the keep-alive closes the connection; advancing by less does not.
- `closeKeepAliveClosesAtOnce`: a `.close` lease closes when it ends if nobody waits, and does not close while a waiter is queued.
- `interactiveRunsBeforeWaitingBackground`: with lease A running, a background request then an interactive request queue; B (interactive) runs before the background one.
- `runningLeaseIsNotInterrupted`: an interactive request waits for a running background lease to finish; `onWait` reports `.queued(behind: "summary")`.
- `fifoWithinPriority`: three background requests run in arrival order.
- `cancelledWaiterLeavesQueue`: cancelling a waiting task throws `CancellationError` and the next waiter still runs.
- `modelChangeReopens`: a lease for a different URL closes the old connection and opens the new one.
- `failedOpenWakesNext`: an open that throws fails that lease with `connectionFailed`, and the next waiter gets a fresh open attempt.
- `bodyErrorDropsConnection`: a body that throws a non-cancellation error closes the connection; the next lease reopens.
- `cancelledGenerationKeepsConnection`: a body that throws `LLMServiceError.cancelled` keeps the connection open.
- `sameContextSizeSkipsReconfigure`: two leases that reconfigure to the same size call the session's `reconfigure` once.
- `keepsModelLoadedSkipsIdleClose`: with the hold on, a `.keepOpen` lease schedules no idle close, and a `.close` lease still closes.
- `keepsModelLoadedToggles`: turning the hold on cancels a pending idle close; turning it off starts the last lease's idle close from then.
- `closeWhenIdleClosesKeptModel`: `closeWhenIdle()` closes a model the hold keeps.
- `loadAheadOpensAndIdleCloses`: `loadAhead` reports `.loadingModel`, opens once, and the next lease reuses the model.
- `loadAheadSkipsWhenLoadedOrBusy`: it returns false with the model loaded or a lease running.
- `requestWaitsForLoadAhead`: a request made during the load waits behind it and opens nothing more.
- `brokeredRunnerIsBackground`: `BrokeredLLMRunner.withSession` runs as a background lease with purpose "summary".
- `intelligenceThroughBroker` (in `IntelligenceTests`): an analysis run through `BrokeredLLMRunner` produces the same stored summary as through the old fake runner.
