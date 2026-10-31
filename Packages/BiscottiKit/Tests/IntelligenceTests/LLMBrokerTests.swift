import BiscottiTestSupport
import DataStore
import Foundation
import LocalLLM
import Synchronization
import Testing
@testable import Intelligence

private let modelA = URL(fileURLWithPath: "/models/a.gguf")
private let modelB = URL(fileURLWithPath: "/models/b.gguf")

// MARK: - Helpers

/// A thread-safe list of what happened, in order.
private final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    var all: [Value] {
        values.withLock { $0 }
    }

    func append(_ value: Value) {
        values.withLock { $0.append(value) }
    }
}

/// A lease requested in its own task. Its body records its purpose, then
/// holds the lease until `release` opens (already open when not holding).
private struct Request {
    let task: Task<Void, any Error>
    let entered: Latch
    let release: Latch
    let waits: Recorder<LLMWait>

    var isQueued: Bool {
        waits.all.contains { if case .queued = $0 { true } else { false } }
    }
}

private func request(
    _ broker: LLMBroker,
    purpose: String,
    priority: LLMPriority = .background,
    model: URL = modelA,
    keepAlive: LLMKeepAlive? = nil,
    holds: Bool = true,
    log: Recorder<String>
) -> Request {
    let entered = Latch()
    let release = Latch()
    if !holds {
        release.open()
    }
    let waits = Recorder<LLMWait>()
    let onWait: @Sendable (LLMWait) -> Void = { waits.append($0) }
    let task = Task {
        try await broker.withLease(
            model: model, priority: priority, purpose: purpose,
            keepAlive: keepAlive, onWait: onWait
        ) { _ in
            log.append(purpose)
            entered.open()
            await release.wait()
        }
    }
    return Request(task: task, entered: entered, release: release, waits: waits)
}

/// Runs one lease to completion.
private func lease(
    _ broker: LLMBroker,
    model: URL = modelA,
    keepAlive: LLMKeepAlive? = nil,
    waits: Recorder<LLMWait>? = nil,
    _ body: @Sendable (any LLMSession) async throws -> Void = { _ in }
) async throws {
    try await broker.withLease(
        model: model, priority: .background, purpose: "summary",
        keepAlive: keepAlive, onWait: { waits?.append($0) }, body
    )
}

/// Gives a woken task time to act, for checks that something did NOT happen.
private func settle() async throws {
    try await Task.sleep(for: .milliseconds(20))
}

// MARK: - LLMBroker

@Suite("LLMBroker")
struct LLMBrokerTests {
    let opener = ScriptedLLMOpener()
    let clock = TestClock()
    private let log = Recorder<String>()

    func makeBroker(defaultKeepAlive: LLMKeepAlive = .keepOpen(.seconds(180))) -> LLMBroker {
        LLMBroker(opener: opener, defaultKeepAlive: defaultKeepAlive, clock: clock)
    }

    // MARK: Keeping the model open

    @Test("two sequential leases on one model open it once, model-only, and keep it open")
    func leaseOpensTheModelOnce() async throws {
        let broker = makeBroker()

        try await lease(broker)
        try await broker.withLease(model: modelA, priority: .interactive, purpose: "chat") { _ in }

        #expect(opener.openCount == 1)
        #expect(opener.requests.map(\.config) == [.modelOnly])
        #expect(opener.closeCount == 0)
    }

    @Test("the connection closes once the keep-alive passes with no new lease")
    func idleCloseAfterKeepAlive() async throws {
        let broker = makeBroker(defaultKeepAlive: .keepOpen(.seconds(180)))
        try await lease(broker)

        clock.advance(by: .seconds(179))
        try await settle()
        #expect(opener.closeCount == 0)

        clock.advance(by: .seconds(1))
        try await waitUntil("the idle close") { opener.closeCount == 1 }
    }

    @Test("a lease's own keep-alive replaces the default")
    func leaseOverridesDefaultKeepAlive() async throws {
        let broker = makeBroker(defaultKeepAlive: .keepOpen(.seconds(180)))
        try await lease(broker, keepAlive: .keepOpen(.seconds(10)))

        clock.advance(by: .seconds(10))
        try await waitUntil("the idle close") { opener.closeCount == 1 }
    }

    @Test("a lease inside the idle period restarts it")
    func newLeaseCancelsIdleClose() async throws {
        let broker = makeBroker(defaultKeepAlive: .keepOpen(.seconds(180)))
        try await lease(broker)
        clock.advance(by: .seconds(100))
        try await lease(broker)

        clock.advance(by: .seconds(100))
        try await settle()
        #expect(opener.closeCount == 0)

        clock.advance(by: .seconds(80))
        try await waitUntil("the idle close") { opener.closeCount == 1 }
        #expect(opener.openCount == 1)
    }

    @Test(".close closes when the lease ends, unless a lease is waiting")
    func closeKeepAliveClosesAtOnce() async throws {
        let broker = makeBroker()
        try await lease(broker, keepAlive: .close)
        #expect(opener.closeCount == 1)

        let first = request(broker, purpose: "chat", keepAlive: .close, log: log)
        try await waitUntil("the first lease") { first.entered.isOpen }
        let next = request(broker, purpose: "summary", log: log)
        try await waitUntil("the next lease to queue") { next.isQueued }
        first.release.open()
        try await first.task.value
        next.release.open()
        try await next.task.value

        #expect(log.all == ["chat", "summary"])
        #expect(opener.openCount == 2)
        #expect(opener.closeCount == 1)
    }

    @Test("closeWhenIdle closes at once when idle, and after the running lease otherwise")
    func closeWhenIdleClosesNowOrAfterLease() async throws {
        let broker = makeBroker()
        try await lease(broker)
        await broker.closeWhenIdle()
        #expect(opener.closeCount == 1)

        let running = request(broker, purpose: "chat", log: log)
        try await waitUntil("the lease") { running.entered.isOpen }
        await broker.closeWhenIdle()
        #expect(opener.sessions.last?.closeCount == 0)

        running.release.open()
        try await running.task.value
        #expect(opener.sessions.last?.closeCount == 1)
        #expect(opener.openCount == 2)
    }

    // MARK: Keeping the model loaded

    @Test("kept loaded, a keep-open lease leaves no idle close; a close lease still closes")
    func keepsModelLoadedSkipsIdleClose() async throws {
        let broker = makeBroker(defaultKeepAlive: .keepOpen(.seconds(180)))
        await broker.setKeepsModelLoaded(true)
        try await lease(broker)

        clock.advance(by: .seconds(3600))
        try await settle()
        #expect(opener.closeCount == 0)
        #expect(clock.pendingSleepCount == 0, "no idle close is scheduled")

        try await lease(broker, keepAlive: .close)
        #expect(opener.closeCount == 1, "the memory rule's .close wins")
    }

    @Test("turning keep-loaded on cancels a pending idle close; turning it off starts one from now")
    func keepsModelLoadedToggles() async throws {
        let broker = makeBroker(defaultKeepAlive: .keepOpen(.seconds(180)))
        try await lease(broker, keepAlive: .keepOpen(.seconds(60)))
        clock.advance(by: .seconds(30))
        await broker.setKeepsModelLoaded(true)
        clock.advance(by: .seconds(60))
        try await settle()
        #expect(opener.closeCount == 0)

        await broker.setKeepsModelLoaded(false)
        clock.advance(by: .seconds(59))
        try await settle()
        #expect(opener.closeCount == 0, "the last lease's keep-alive, from the moment it was turned off")
        clock.advance(by: .seconds(1))
        try await waitUntil("the idle close") { opener.closeCount == 1 }
    }

    @Test("closeWhenIdle closes a model kept loaded")
    func closeWhenIdleClosesKeptModel() async throws {
        let broker = makeBroker()
        await broker.setKeepsModelLoaded(true)
        try await lease(broker)

        await broker.closeWhenIdle()

        #expect(opener.closeCount == 1)
    }

    // MARK: Loading ahead

    @Test("loading ahead opens the model in a lease of its own, then applies its keep-alive")
    func loadAheadOpensAndIdleCloses() async throws {
        let broker = makeBroker()
        let waits = Recorder<LLMWait>()

        let loaded = try await broker.loadAhead(
            model: modelA, priority: .interactive, purpose: "ahead",
            keepAlive: .keepOpen(.seconds(30)), onWait: { waits.append($0) }
        )

        #expect(loaded)
        #expect(waits.all == [.loadingModel])
        #expect(opener.openCount == 1)
        try await lease(broker)
        #expect(opener.openCount == 1, "the next lease finds the model loaded")
        try await lease(broker, keepAlive: .keepOpen(.seconds(30)))
        clock.advance(by: .seconds(30))
        try await waitUntil("the idle close") { opener.closeCount == 1 }
    }

    @Test("loading ahead does nothing when the model is loaded or a lease runs")
    func loadAheadSkipsWhenLoadedOrBusy() async throws {
        let broker = makeBroker()
        try await lease(broker)
        #expect(try await broker.loadAhead(model: modelA, priority: .interactive, purpose: "ahead") == false)

        let running = request(broker, purpose: "summary", model: modelB, log: log)
        try await waitUntil("the running lease") { running.entered.isOpen }
        #expect(try await broker.loadAhead(model: modelA, priority: .interactive, purpose: "ahead") == false)
        running.release.open()
        try await running.task.value

        #expect(opener.requests.map(\.model) == [modelA, modelB])
    }

    @Test("a request made while the model loads ahead waits for it and reuses the model")
    func requestWaitsForLoadAhead() async throws {
        let broker = makeBroker()
        let gate = Latch()
        opener.openGate = gate
        let ahead = Task { try await broker.loadAhead(model: modelA, priority: .interactive, purpose: "ahead") }
        try await waitUntil("the load to start") { await broker.runningPurpose == "ahead" }

        let chat = request(broker, purpose: "chat", priority: .interactive, holds: false, log: log)
        try await waitUntil("the request to queue") { chat.isQueued }
        #expect(chat.waits.all == [.queued(behind: "ahead")])
        gate.open()

        #expect(try await ahead.value)
        try await chat.task.value
        #expect(opener.openCount == 1)
    }

    // MARK: Ordering

    @Test("a waiting interactive request runs before a background one that queued first")
    func interactiveRunsBeforeWaitingBackground() async throws {
        let broker = makeBroker()
        let running = request(broker, purpose: "transcript", log: log)
        try await waitUntil("the running lease") { running.entered.isOpen }

        let background = request(broker, purpose: "summary", holds: false, log: log)
        try await waitUntil("the background request to queue") { background.isQueued }
        let interactive = request(broker, purpose: "chat", priority: .interactive, holds: false, log: log)
        try await waitUntil("the interactive request to queue") { interactive.isQueued }

        running.release.open()
        try await background.task.value
        try await interactive.task.value

        #expect(log.all == ["transcript", "chat", "summary"])
    }

    @Test("an interactive request waits for the running background lease")
    func runningLeaseIsNotInterrupted() async throws {
        let broker = makeBroker()
        let summary = request(broker, purpose: "summary", log: log)
        try await waitUntil("the summary") { summary.entered.isOpen }

        let chat = request(broker, purpose: "chat", priority: .interactive, log: log)
        try await waitUntil("the chat request to queue") { chat.isQueued }
        #expect(chat.waits.all == [.queued(behind: "summary")])
        #expect(await broker.runningPurpose == "summary")
        #expect(log.all == ["summary"])

        summary.release.open()
        try await waitUntil("the chat lease") { chat.entered.isOpen }
        #expect(await broker.runningPurpose == "chat")

        chat.release.open()
        try await chat.task.value
        #expect(await broker.runningPurpose == nil)
    }

    @Test("requests of one priority run in arrival order")
    func fifoWithinPriority() async throws {
        let broker = makeBroker()
        let running = request(broker, purpose: "first", log: log)
        try await waitUntil("the running lease") { running.entered.isOpen }

        var queued: [Request] = []
        for purpose in ["a", "b", "c"] {
            let next = request(broker, purpose: purpose, holds: false, log: log)
            try await waitUntil("\(purpose) to queue") { next.isQueued }
            queued.append(next)
        }

        running.release.open()
        for next in queued {
            try await next.task.value
        }

        #expect(log.all == ["first", "a", "b", "c"])
    }

    @Test("a cancelled waiter leaves the queue and the next one still runs")
    func cancelledWaiterLeavesQueue() async throws {
        let broker = makeBroker()
        let running = request(broker, purpose: "summary", log: log)
        try await waitUntil("the running lease") { running.entered.isOpen }
        let cancelled = request(broker, purpose: "cancelled", holds: false, log: log)
        try await waitUntil("the request to cancel to queue") { cancelled.isQueued }
        let next = request(broker, purpose: "next", holds: false, log: log)
        try await waitUntil("the next request to queue") { next.isQueued }

        cancelled.task.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.task.value }

        running.release.open()
        try await next.task.value
        #expect(log.all == ["summary", "next"])
    }
}

// MARK: - LLMBroker connection

@Suite("LLMBroker connection")
struct LLMBrokerConnectionTests {
    let opener = ScriptedLLMOpener()
    private let log = Recorder<String>()

    func makeBroker() -> LLMBroker {
        LLMBroker(opener: opener, clock: TestClock())
    }

    @Test("the first lease reports loading the model; a lease on the open connection reports nothing")
    func loadingModelReported() async throws {
        let broker = makeBroker()
        let first = Recorder<LLMWait>()
        let second = Recorder<LLMWait>()

        try await lease(broker, waits: first)
        try await lease(broker, waits: second)

        #expect(first.all == [.loadingModel])
        #expect(second.all.isEmpty)
    }

    @Test("a lease for another model closes the old connection and opens the new one")
    func modelChangeReopens() async throws {
        let broker = makeBroker()
        try await lease(broker, model: modelA)
        try await lease(broker, model: modelB)

        #expect(opener.requests.map(\.model) == [modelA, modelB])
        #expect(opener.sessions.map(\.closeCount) == [1, 0])
    }

    @Test("a failed open fails that lease and the next waiter opens afresh")
    func failedOpenWakesNext() async throws {
        let broker = makeBroker()
        let running = request(broker, purpose: "summary", model: modelA, log: log)
        try await waitUntil("the running lease") { running.entered.isOpen }
        let failing = request(broker, purpose: "chat", model: modelB, holds: false, log: log)
        try await waitUntil("the failing request to queue") { failing.isQueued }
        let next = request(broker, purpose: "title", model: modelB, holds: false, log: log)
        try await waitUntil("the next request to queue") { next.isQueued }
        opener.openErrors = [ScriptedLLMFailure.openFailed]

        running.release.open()
        let error = await #expect(throws: LLMBrokerError.self) { try await failing.task.value }
        #expect(error == .connectionFailed(ScriptedLLMFailure.openFailed.localizedDescription))
        try await next.task.value

        #expect(log.all == ["summary", "title"])
        #expect(opener.requests.map(\.model) == [modelA, modelB, modelB])
        #expect(opener.openCount == 2)
    }

    @Test("a body error drops the connection, and the next lease reopens")
    func bodyErrorDropsConnection() async throws {
        let broker = makeBroker()
        await #expect(throws: ScriptedLLMFailure.generationFailed) {
            try await lease(broker) { _ in throw ScriptedLLMFailure.generationFailed }
        }
        #expect(opener.closeCount == 1)

        try await lease(broker)
        #expect(opener.openCount == 2)
    }

    @Test("a stream cancelled between pulls closes the connection, and the next lease gets a fresh one")
    func unfinishedStreamDropsConnection() async throws {
        opener.script.streams = [ScriptedStream(["a"]), ScriptedStream(["b"]), ScriptedStream(["c", "d"])]
        let broker = makeBroker()
        try await lease(broker) { session in
            for try await _ in await session.generateStreaming(messages: [], options: .default) {}
        }
        try await lease(broker) { session in
            _ = await session.generateStreaming(messages: [], options: .default)
        }
        #expect(opener.closeCount == 0)

        let pulled = Latch()
        let resume = Latch()
        let stopped = Task {
            try await lease(broker) { session in
                var events = await session.generateStreaming(messages: [], options: .default).makeAsyncIterator()
                _ = try await events.next()
                pulled.open()
                await resume.wait()
                // Cancelled between pulls: the stream ends here without
                // reaching its own end, and the body returns normally.
                #expect(try await events.next() == nil)
            }
        }
        try await waitUntil("the first token") { pulled.isOpen }
        stopped.cancel()
        resume.open()
        try await stopped.value

        let stuck = try #require(opener.sessions.first)
        #expect(stuck.isBlocked)
        #expect(stuck.closeCount == 1)
        try await lease(broker) { _ = try await $0.countTokens(messages: []) }
        #expect(opener.openCount == 2)
    }

    @Test("a cancelled generation that left no stream unfinished keeps the connection")
    func cancelledGenerationKeepsConnection() async throws {
        let broker = makeBroker()
        await #expect(throws: LLMServiceError.cancelled) {
            try await lease(broker) { _ in throw LLMServiceError.cancelled }
        }
        await #expect(throws: CancellationError.self) {
            try await lease(broker) { _ in throw CancellationError() }
        }
        try await lease(broker)

        #expect(opener.openCount == 1)
        #expect(opener.closeCount == 0)
    }

    @Test("reconfiguring to the size the session already has is skipped")
    func sameContextSizeSkipsReconfigure() async throws {
        let broker = makeBroker()
        try await lease(broker) { try await $0.reconfigure(contextSize: 8192) }
        try await lease(broker) { try await $0.reconfigure(contextSize: 8192) }
        #expect(opener.sessions.first?.reconfigureCalls == [8192])

        try await lease(broker) { try await $0.reconfigure(contextSize: 16384) }
        #expect(opener.sessions.first?.reconfigureCalls == [8192, 16384])

        await #expect(throws: ScriptedLLMFailure.generationFailed) {
            try await lease(broker) { _ in throw ScriptedLLMFailure.generationFailed }
        }
        try await lease(broker) { try await $0.reconfigure(contextSize: 16384) }
        #expect(opener.sessions.last?.reconfigureCalls == [16384])
        #expect(opener.openCount == 2)
    }

    @Test("an unfinished stream drops the connection even when the body throws a cancellation")
    func unfinishedStreamDropsConnectionOnCancellation() async throws {
        opener.script.streams = [ScriptedStream(["a", "b"])]
        let broker = makeBroker()
        await #expect(throws: CancellationError.self) {
            try await lease(broker) { session in
                var events = await session.generateStreaming(messages: [], options: .default).makeAsyncIterator()
                _ = try await events.next()
                throw CancellationError()
            }
        }
        #expect(opener.closeCount == 1)

        try await lease(broker) { _ = try await $0.countTokens(messages: []) }
        #expect(opener.openCount == 2)
    }

    @Test("a stream cancelled while it waits for a token keeps the connection")
    func streamCancelledMidPullKeepsConnection() async throws {
        opener.script.streams = [ScriptedStream(["slow"], tokenDelay: .seconds(60))]
        let broker = makeBroker()
        let reading = Task {
            try await lease(broker) { session in
                for try await _ in await session.generateStreaming(messages: [], options: .default) {}
            }
        }
        try await waitUntil("the first pull") { opener.sessions.first?.isBlocked == true }
        reading.cancel()
        await #expect(throws: LLMServiceError.cancelled) { try await reading.value }
        #expect(opener.closeCount == 0)

        try await lease(broker) { _ = try await $0.countTokens(messages: []) }
        #expect(opener.openCount == 1)
    }
}

// MARK: - BrokeredLLMRunner

@Suite("BrokeredLLMRunner")
struct BrokeredLLMRunnerTests {
    let opener = ScriptedLLMOpener()
    private let log = Recorder<String>()

    func makeBroker() -> LLMBroker {
        LLMBroker(opener: opener, clock: TestClock())
    }

    @Test("BrokeredLLMRunner runs a background lease named summary")
    func brokeredRunnerIsBackground() async throws {
        let broker = makeBroker()
        let runner = BrokeredLLMRunner(broker: broker)
        let running = request(broker, purpose: "transcript", log: log)
        try await waitUntil("the running lease") { running.entered.isOpen }

        let analysis = Task {
            try await runner.withSession(model: modelA, config: .modelOnly) { _ in
                await log.append(broker.runningPurpose ?? "none")
            }
        }
        try await waitUntil("the runner's request to queue") {
            await broker.waitingPurposes == ["summary"]
        }
        let chat = request(broker, purpose: "chat", priority: .interactive, holds: false, log: log)
        try await waitUntil("the chat request to queue") { chat.isQueued }
        #expect(await broker.waitingPurposes == ["chat", "summary"])

        running.release.open()
        try await chat.task.value
        try await analysis.value

        #expect(log.all == ["transcript", "chat", "summary"])
    }

    @Test("BrokeredLLMRunner applies a non-zero context size before the body")
    func brokeredRunnerHonorsContextSize() async throws {
        let runner = BrokeredLLMRunner(broker: makeBroker())

        try await runner.withSession(model: modelA, config: EngineConfig(contextSize: 4096)) { _ in }
        try await runner.withSession(model: modelA, config: .modelOnly) { _ in }

        #expect(opener.requests.map(\.config) == [.modelOnly])
        #expect(opener.sessions.first?.reconfigureCalls == [4096])
    }
}

// MARK: - Intelligence through the broker

@Suite("Intelligence through the broker")
struct IntelligenceThroughBrokerTests {
    private struct Outcome: Equatable {
        let summary: String?
        let speakerNames: [Int: String]
    }

    @Test("an analysis through the broker stores what the fake runner stores")
    @MainActor func intelligenceThroughBroker() async throws {
        let replies = ["0 | Alice |\n1 | Bob |"]
        let tokens = ["## Meeting Notes\n", "Summary text"]

        let session = FakeSession()
        session.generateResponses = replies
        session.streamingTokens = [tokens]
        let viaFakeRunner = try await analyze(with: FakeLLMRunner(session: session))

        let opener = ScriptedLLMOpener(script: LLMScript(replies: replies, streams: [ScriptedStream(tokens)]))
        let broker = LLMBroker(opener: opener, clock: TestClock())
        let viaBroker = try await analyze(with: BrokeredLLMRunner(broker: broker))

        #expect(viaBroker == viaFakeRunner)
        #expect(viaBroker.summary == "## Meeting Notes\nSummary text")
        #expect(viaBroker.speakerNames == [0: "Alice", 1: "Bob"])
        #expect(opener.openCount == 1)
        #expect(opener.sessions.first?.reconfigureCalls.count == 1)
    }

    @MainActor private func analyze(with llm: any LLMRunning) async throws -> Outcome {
        let store = try DataStore(storage: .inMemory)
        let meetingID = try await store.createMeeting(title: "Planning")
        let transcriptID = try await store.addTranscript(
            FakeTranscriber.defaultResult, vocabularyUsed: [],
            mappedEventIdentifier: nil, to: meetingID
        )
        try await store.setPreferredTranscript(transcriptID, for: meetingID)

        let models = FakeModelProvider(downloadedIDs: [LLMModelCatalog.all.first?.id ?? ""])
        let modelManager = ModelManager(store: store, models: models, hardware: FakeHardwareProbe())
        for model in models.catalog {
            modelManager.downloads[model.id] = models.isDownloaded(model.id) ? .downloaded : .notDownloaded
        }
        let intelligence = Intelligence(
            store: store, llm: llm, modelManager: modelManager,
            settings: { AISettings(enabled: true, summaryPrompt: IntelligencePrompts.defaultSummaryPrompt) }
        )

        await intelligence.runAutoEnhancements(meetingID: meetingID)

        #expect(intelligence.jobs[meetingID] == .completed)
        let detail = try #require(try await store.meetingDetail(id: meetingID))
        return Outcome(
            summary: detail.summary,
            speakerNames: detail.preferredTranscript?.speakerAssignments.mapValues(\.name) ?? [:]
        )
    }
}
