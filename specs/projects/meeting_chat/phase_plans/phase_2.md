---
status: complete
---

# Phase 2: LLM broker

## Overview

Chat and `Intelligence` must share one connection to the local model, because each connection to `BiscottiLLM.xpc` loads its own copy of the model. This phase adds `LLMBroker` to `Intelligence`: an actor that owns the one connection, lends it to one job at a time in priority order (chat before waiting analysis, never pre-empting a running lease), keeps it open for an idle period so follow-up questions reuse the loaded model and KV cache, and closes it on idle, model change, `.close` keep-alive or a body error. `Intelligence` moves onto the broker through `BrokeredLLMRunner` in `AppCore+Live`, `PreviewAppCore` and `CoreFixture`, and `AppCore` keeps the broker for the chat service built in phase 4. No UI changes.

## Steps

1. **`Intelligence/LLMBroker.swift`** (new): the public types from the component design.
   - `LLMPriority: Int, Comparable, Sendable` (`background = 0`, `interactive = 1`), `LLMKeepAlive` (`keepOpen(Duration)`, `close`), `LLMWait` (`queued(behind:)`, `loadingModel`), `LLMBrokerError` (`modelUnavailable`, `connectionFailed(String)`).
   - `LLMConnectionOpening` (`open(model:config:) async throws -> any LLMOpenSession`) and `LLMOpenSession: LLMSession` (`close() async`).
   - `public actor LLMBroker`:
     ```swift
     public init(opener: any LLMConnectionOpening,
                 defaultKeepAlive: LLMKeepAlive = .keepOpen(.seconds(180)),
                 clock: any Clock<Duration> = ContinuousClock())
     public func withLease<T: Sendable>(model: URL, priority: LLMPriority, purpose: String,
         keepAlive: LLMKeepAlive? = nil,
         onWait: @escaping @Sendable (LLMWait) -> Void = { _ in },
         _ body: @Sendable (any LLMSession) async throws -> T) async throws -> T
     public var runningPurpose: String? { get }
     public func closeWhenIdle() async
     ```
   - State: `connection` (session, model URL, cached context size, an id), `running` (purpose, keep-alive), `waiters` sorted by priority descending then arrival id, `idleClose: Task<Void, Never>?`, and a `closeRequested` flag for `closeWhenIdle`.
   - Acquire: run at once when nothing runs and no waiter has equal or higher priority; otherwise insert a waiter, report `.queued(behind: running purpose)`, and suspend under `withTaskCancellationHandler` (the handler hops to the actor and resumes the waiter with `CancellationError`). Ending a lease hands it straight to the first waiter (`running` is set before the waiter is resumed), so a newcomer can never slip in between. A waiter that is handed the lease after being cancelled gives it up at once and throws `CancellationError`.
   - Connection: reuse when the model URL matches; otherwise close the old one, report `.loadingModel`, and `opener.open(model:config: .modelOnly)`. An open failure ends the lease (next waiter runs) and throws `connectionFailed`; a `CancellationError` from the open is rethrown as is.
   - `BrokerSession` (private struct): forwards every call; `reconfigure(contextSize:)` goes through the broker, which skips it when the size equals the cached size, records the new size on success, and forgets it on failure.
   - End of lease (success or error): a body error other than `CancellationError` / `LLMServiceError.cancelled` drops and closes the connection. Then hand off to the first waiter, or, when nobody waits, close now (`.close` or a pending `closeWhenIdle`) or schedule the idle close. The idle-close deadline is taken from the clock when the lease ends (a generic helper opens the `any Clock` existential), so a test clock advanced right after the lease is deterministic.
   - `closeWhenIdle()` cancels the idle timer and closes now when idle; while a lease runs or waits, it sets `closeRequested` and the close happens when the broker next becomes idle.
   - `os.Logger` category `llm-broker`: lease start (purpose, priority, wait), lease end, model open with duration, reconfigure size and skips, idle close, dropped connection with the error's type. No prompt text.
2. **`Intelligence/BrokeredLLMRunner.swift`** (new): `BrokeredLLMRunner: LLMRunning` (`init(broker:purpose: = "summary")`). `withSession` runs `broker.withLease(model:priority: .background, purpose:)`; it honors a non-zero `config.contextSize` by reconfiguring the leased session before `body` (the broker always loads model-only).
3. **`Intelligence/LiveLLMRunning.swift`**: add `LiveLLMConnectionOpener: LLMConnectionOpening` (`init(serviceName: = RuntimeConfiguration.current.llmServiceName)`), opening `LLMService.openConnection(model:backend: .hosted(serviceName:), config:)` and returning `LiveLLMSession`, which gains `close()` and conforms to `LLMOpenSession`. `LiveLLMRunner` stays for the manual-test app and CLI tools.
4. **`AppCore`**: `AppCore.init` gains a required `llmBroker: LLMBroker` parameter (after `modelManager`) stored as `public let llmBroker`. `AppCore+Live.buildModelAndIntelligence` creates `LLMBroker(opener: LiveLLMConnectionOpener())`, passes `BrokeredLLMRunner(broker:)` to `Intelligence`, and returns the broker. `PreviewAppCore` replaces `PreviewLLMRunner` with a `PreviewLLMOpener` whose sessions return empty streams, and wires `Intelligence` and `AppCore` to one broker.
5. **`BiscottiTestSupport/ScriptedLLM.swift`** (new):
   - `LLMScript` (final class, `Mutex`-guarded, shared by every session one opener hands out, consumed in order): `tokenCount`, `replies` for `generate`, `streams: [ScriptedStream]` for `generateStreaming`, `generateError`. `ScriptedStream(tokens, tokenDelay:, ending: .done | .withoutDone | .error(any Error))`. When the lists run out: `""` and an empty stream that ends with `.done`.
   - `ScriptedSession: LLMOpenSession`: records `countTokens`, `reconfigure`, `generate` and `generateStreaming` calls and `close` count; a consumer cancelled mid-stream gets `LLMServiceError.cancelled`, like the real connection.
   - `ScriptedLLMOpener: LLMConnectionOpening`: `script`, `openErrors` (each open consumes one), `openDelay`, and records `openCount`, `closeCount`, `openedModels`, `openedConfigs`, `sessions`.
   - `TestClock: Clock` (manual): `advance(by:)` resumes sleepers whose deadline has passed; a sleep whose deadline already passed returns at once; cancellation resumes with `CancellationError`.
   - `makeGenerationResult(text:)` helper for `.done` events.
6. **`CoreFixture`**: replace `fakeLLMRunner: FakeCoreLLMRunner` with `llmOpener: ScriptedLLMOpener`, `llmClock: TestClock` and `llmBroker: LLMBroker`; `Intelligence` uses `BrokeredLLMRunner(broker:)`; `AppCore` gets the broker. Delete `FakeCoreLLMRunner` and `FakeCoreLLMSession`. Update the six `fakeLLMRunner.sessionCount` assertions (in `AppCoreIntelligenceTests` and `PipelineStatusTests`) to `llmOpener.openCount`, and the two `SettingsUITests` `AppCore` builders to share one scripted broker with their `Intelligence`.
7. **`Package.swift`**: `IntelligenceTests` gains the `BiscottiTestSupport` dependency.

## Tests

`IntelligenceTests/LLMBrokerTests.swift` (Swift Testing, `TestClock`, `ScriptedLLMOpener`; leases held open with continuations so ordering is deterministic):

- `leaseOpensTheModelOnce`: two sequential leases on one model open once (model-only config) and close zero times before the idle period.
- `idleCloseAfterKeepAlive`: after the last lease, advancing the clock by less than the keep-alive does not close; advancing to it closes.
- `leaseOverridesDefaultKeepAlive`: a lease's own `.keepOpen` duration is used instead of the default.
- `newLeaseCancelsIdleClose`: a lease that starts inside the idle period keeps the connection open past the first deadline.
- `closeKeepAliveClosesAtOnce`: a `.close` lease closes when it ends if nobody waits, and does not close while a waiter is queued (the waiter reuses the connection).
- `interactiveRunsBeforeWaitingBackground`: with lease A running, a background request then an interactive request queue; the interactive one runs first.
- `runningLeaseIsNotInterrupted`: an interactive request waits for a running background lease; `onWait` reports `.queued(behind: "summary")`, and `runningPurpose` reads "summary" then "chat".
- `fifoWithinPriority`: three background requests run in arrival order.
- `cancelledWaiterLeavesQueue`: cancelling a waiting task throws `CancellationError`, its body never runs, and the next waiter still runs.
- `modelChangeReopens`: a lease for a different URL closes the old connection and opens the new one.
- `loadingModelReported`: the first lease reports `.loadingModel`; a lease on the open connection reports nothing.
- `failedOpenWakesNext`: an open that throws fails that lease with `connectionFailed`, and the queued waiter gets a fresh open attempt that succeeds.
- `bodyErrorDropsConnection`: a body that throws a non-cancellation error closes the connection; the next lease reopens.
- `cancelledGenerationKeepsConnection`: a body that throws `LLMServiceError.cancelled` (and one that throws `CancellationError`) keeps the connection open.
- `sameContextSizeSkipsReconfigure`: two leases that reconfigure to the same size call the session's `reconfigure` once; a different size calls it again; after a reopen the first reconfigure is not skipped.
- `closeWhenIdleClosesNowOrAfterLease`: idle → closes at once; with a lease running → closes when the lease ends.
- `brokeredRunnerIsBackground`: `BrokeredLLMRunner.withSession` runs as a background lease with purpose "summary" (an interactive request queued after it reports `.queued(behind: "summary")`, and it queues behind an interactive waiter).
- `brokeredRunnerHonorsContextSize`: a non-zero `config.contextSize` reconfigures the session before the body; `.modelOnly` does not.

`IntelligenceTests/IntelligenceTests.swift`:

- `intelligenceThroughBroker`: an auto-run analysis through `BrokeredLLMRunner` over a `ScriptedLLMOpener` stores the same summary and speaker names as the same script through `FakeLLMRunner`.

Existing suites that exercise the wiring (`AppCoreIntelligenceTests`, `PipelineStatusTests`, the `SettingsUITests` builders) keep passing with the broker-backed `Intelligence`.
