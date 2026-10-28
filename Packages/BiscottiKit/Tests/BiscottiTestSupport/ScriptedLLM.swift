import Foundation
import Intelligence
import LocalLLM
import Synchronization

// MARK: - Script

/// How one scripted `generateStreaming` call plays out.
public struct ScriptedStream: Sendable {
    public enum Ending: Sendable {
        /// Ends with `.done` carrying the joined tokens.
        case done
        /// Ends with neither `.done` nor an error, like a real stream cut short.
        case withoutDone
        /// Throws this error after the tokens.
        case error(any Error)
    }

    public var tokens: [String]
    /// Waited before each token, on `clock`. A consumer cancelled during the
    /// wait gets `LLMServiceError.cancelled`, like a real connection.
    public var tokenDelay: Duration?
    public var ending: Ending
    /// Times `tokenDelay`.
    public var clock: any Clock<Duration>

    public init(
        _ tokens: [String],
        tokenDelay: Duration? = nil,
        ending: Ending = .done,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.tokens = tokens
        self.tokenDelay = tokenDelay
        self.ending = ending
        self.clock = clock
    }
}

/// What a scripted model says. One script is shared by every session an
/// opener hands out, and each reply and stream is used once, in order, so a
/// reopened connection carries on where the last one stopped.
public final class LLMScript: Sendable {
    private struct State {
        var tokenCount: Int
        var replies: [String]
        var streams: [ScriptedStream]
    }

    private let state: Mutex<State>

    public init(tokenCount: Int = 100, replies: [String] = [], streams: [ScriptedStream] = []) {
        state = Mutex(State(tokenCount: tokenCount, replies: replies, streams: streams))
    }

    /// What every `countTokens` call returns.
    public var tokenCount: Int {
        get { state.withLock { $0.tokenCount } }
        set { state.withLock { $0.tokenCount = newValue } }
    }

    /// Replies to `generate`, in order. `""` once they run out.
    public var replies: [String] {
        get { state.withLock { $0.replies } }
        set { state.withLock { $0.replies = newValue } }
    }

    /// Streams for `generateStreaming`, in order. An empty stream that ends
    /// with `.done` once they run out.
    public var streams: [ScriptedStream] {
        get { state.withLock { $0.streams } }
        set { state.withLock { $0.streams = newValue } }
    }

    func nextReply() -> String {
        state.withLock { $0.replies.isEmpty ? "" : $0.replies.removeFirst() }
    }

    func nextStream() -> ScriptedStream {
        state.withLock { $0.streams.isEmpty ? ScriptedStream([]) : $0.streams.removeFirst() }
    }
}

/// Errors the scripted fakes throw.
public enum ScriptedLLMFailure: Error, Equatable {
    /// A test asked an open to fail.
    case openFailed
    /// A test asked a generation to fail.
    case generationFailed
    /// A call reached a session whose stream was pulled and never read to its
    /// end. The real connection would wait forever here.
    case sessionBlocked
}

// MARK: - Session

/// A fake open model session: answers from its `LLMScript` and records calls.
///
/// Like `LLMConnection`'s one-slot gate, a stream holds the session from its
/// first pull until it ends (returns nil or throws). A consumer cancelled
/// between pulls never reaches that end; every later call then throws
/// `ScriptedLLMFailure.sessionBlocked` where the real connection would block.
public final class ScriptedSession: LLMOpenSession {
    private struct Calls {
        var countTokens: [[LLMMessage]] = []
        var reconfigure: [Int] = []
        var generate: [[LLMMessage]] = []
        var streaming: [[LLMMessage]] = []
        var closeCount = 0
    }

    public let script: LLMScript
    private let calls = Mutex(Calls())
    private let gateHeld = Mutex(false)

    public init(script: LLMScript = LLMScript()) {
        self.script = script
    }

    /// Whether a stream has been pulled and not read to its end.
    public var isBlocked: Bool {
        gateHeld.withLock { $0 }
    }

    public var countTokensCalls: [[LLMMessage]] {
        calls.withLock { $0.countTokens }
    }

    public var reconfigureCalls: [Int] {
        calls.withLock { $0.reconfigure }
    }

    public var generateCalls: [[LLMMessage]] {
        calls.withLock { $0.generate }
    }

    public var streamingCalls: [[LLMMessage]] {
        calls.withLock { $0.streaming }
    }

    public var closeCount: Int {
        calls.withLock { $0.closeCount }
    }

    public func countTokens(messages: [LLMMessage]) async throws -> Int {
        try checkGate()
        calls.withLock { $0.countTokens.append(messages) }
        return script.tokenCount
    }

    public func reconfigure(contextSize: Int) async throws {
        try checkGate()
        calls.withLock { $0.reconfigure.append(contextSize) }
    }

    public func generate(
        messages: [LLMMessage], options _: GenerationOptions
    ) async throws -> String {
        try checkGate()
        calls.withLock { $0.generate.append(messages) }
        return script.nextReply()
    }

    public func generateStreaming(
        messages: [LLMMessage], options _: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error> {
        calls.withLock { $0.streaming.append(messages) }
        let player = StreamPlayer(script.nextStream(), session: self)
        return AsyncThrowingStream { try await player.next() }
    }

    public func close() async {
        calls.withLock { $0.closeCount += 1 }
    }

    private func checkGate() throws {
        if isBlocked {
            throw ScriptedLLMFailure.sessionBlocked
        }
    }

    /// Taken by a stream's first pull.
    fileprivate func holdGate() throws {
        try gateHeld.withLock { held in
            if held {
                throw ScriptedLLMFailure.sessionBlocked
            }
            held = true
        }
    }

    /// Freed when the stream that holds the gate ends.
    fileprivate func releaseGate() {
        gateHeld.withLock { $0 = false }
    }
}

/// Plays a `ScriptedStream` one event per pull, so tokens are produced only
/// as fast as the consumer reads them. Holds the session's gate from the
/// first pull until the stream ends.
private final class StreamPlayer: Sendable {
    private let scripted: ScriptedStream
    private let session: ScriptedSession
    private let position = Mutex(0)

    init(_ scripted: ScriptedStream, session: ScriptedSession) {
        self.scripted = scripted
        self.session = session
    }

    func next() async throws -> StreamEvent? {
        let index = position.withLock { position in
            defer { position += 1 }
            return position
        }
        if index == 0 {
            try session.holdGate()
        }
        do {
            guard let event = try await event(at: index) else {
                session.releaseGate()
                return nil
            }
            return event
        } catch {
            session.releaseGate()
            throw error
        }
    }

    private func event(at index: Int) async throws -> StreamEvent? {
        let tokens = scripted.tokens
        if index < tokens.count {
            if let delay = scripted.tokenDelay {
                do {
                    try await scripted.clock.sleep(for: delay)
                } catch {
                    throw LLMServiceError.cancelled
                }
            }
            return .token(tokens[index])
        }
        guard index == tokens.count else { return nil }
        switch scripted.ending {
        case .done:
            return .done(makeGenerationResult(text: tokens.joined()))
        case .withoutDone:
            return nil
        case let .error(error):
            throw error
        }
    }
}

// MARK: - Opener

/// A fake `LLMConnectionOpening` that hands out `ScriptedSession`s sharing
/// one script, and records every open and close.
public final class ScriptedLLMOpener: LLMConnectionOpening {
    public struct OpenRequest: Sendable, Equatable {
        public let model: URL
        public let config: EngineConfig
    }

    private struct State {
        var openErrors: [any Error] = []
        var openDelay: Duration?
        var openGate: Latch?
        var clock: any Clock<Duration> = ContinuousClock()
        var requests: [OpenRequest] = []
        var sessions: [ScriptedSession] = []
    }

    public let script: LLMScript
    private let state = Mutex(State())

    public init(script: LLMScript = LLMScript()) {
        self.script = script
    }

    /// Each open attempt throws the first of these, if any, and removes it.
    public var openErrors: [any Error] {
        get { state.withLock { $0.openErrors } }
        set { state.withLock { $0.openErrors = newValue } }
    }

    /// Waited before each open, on `clock`, to stand in for a slow model load.
    public var openDelay: Duration? {
        get { state.withLock { $0.openDelay } }
        set { state.withLock { $0.openDelay = newValue } }
    }

    /// Each open waits for this to open, and does not stop when its caller
    /// is cancelled, like a real model load.
    public var openGate: Latch? {
        get { state.withLock { $0.openGate } }
        set { state.withLock { $0.openGate = newValue } }
    }

    /// Times `openDelay`.
    public var clock: any Clock<Duration> {
        get { state.withLock { $0.clock } }
        set { state.withLock { $0.clock = newValue } }
    }

    /// Every open attempt, failed ones included.
    public var requests: [OpenRequest] {
        state.withLock { $0.requests }
    }

    /// The sessions opened successfully, oldest first.
    public var sessions: [ScriptedSession] {
        state.withLock { $0.sessions }
    }

    /// Successful opens.
    public var openCount: Int {
        sessions.count
    }

    /// Closes across every session this opener handed out.
    public var closeCount: Int {
        sessions.reduce(0) { $0 + $1.closeCount }
    }

    public func open(model: URL, config: EngineConfig) async throws -> any LLMOpenSession {
        let (error, delay, clock, gate) = state.withLock { state in
            state.requests.append(OpenRequest(model: model, config: config))
            let error = state.openErrors.isEmpty ? nil : state.openErrors.removeFirst()
            return (error, state.openDelay, state.clock, state.openGate)
        }
        if let delay {
            try await clock.sleep(for: delay)
        }
        await gate?.wait()
        if let error {
            throw error
        }
        let session = ScriptedSession(script: script)
        state.withLock { $0.sessions.append(session) }
        return session
    }
}

// MARK: - Results

/// A `GenerationResult` for a `.done` event. It has no public memberwise
/// init, but it is `Codable`.
public func makeGenerationResult(text: String) -> GenerationResult {
    let json: [String: Any] = [
        "text": text,
        "promptTokenCount": 0,
        "generatedTokenCount": 1,
        "cachedPromptTokenCount": 0,
        "finishReason": ["endOfTurn": [String: Any]()],
        "promptEvalDuration": 0.0,
        "generationDuration": 0.0,
        "totalDuration": 0.0,
        "renderedPrompt": "",
        "rawText": text
    ]
    // swiftlint:disable:next force_try
    let data = try! JSONSerialization.data(withJSONObject: json)
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode(GenerationResult.self, from: data)
}
