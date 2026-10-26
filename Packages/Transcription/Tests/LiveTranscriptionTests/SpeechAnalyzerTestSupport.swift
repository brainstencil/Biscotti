import Foundation
import LiveTranscriptModel
import Synchronization
@testable import LiveTranscription

struct FakeAnalyzerError: Error {}

/// Stands in for Apple's analyzer. It records every input, keeps a timeline
/// as the analyzer does (a start time sets it, nil continues it), and sends
/// whatever events a test gives it.
///
/// Like SpeechAnalyzer, after a jump in its timeline it returns the first
/// phrase it hears from there as one punctuation-only word.
final class FakeSpeechAnalyzer: SpeechTrackAnalyzer {
    enum FinishBehavior {
        /// Sends these events, then ends the stream.
        case completes([SpeechAnalyzerEvent])
        /// Never returns until cancelled.
        case hangs
    }

    private struct State {
        var inputs: [SpeechInput] = []
        /// Where each input starts on the analyzer's own timeline.
        var inputStarts: [TimeInterval] = []
        var timelineEnd: TimeInterval = 0
        /// Where the timeline last jumped, until the first final result after it.
        var jumpedTo: TimeInterval?
        var timelineJumps = 0
        var isFull = false
        var finishBehavior = FinishBehavior.completes([])
        var finishCalls = 0
        var cancelCalls = 0
    }

    let events: AsyncThrowingStream<SpeechAnalyzerEvent, any Error>
    private let sink: AsyncThrowingStream<SpeechAnalyzerEvent, any Error>.Continuation
    private let state = Mutex(State())

    init() {
        (events, sink) = AsyncThrowingStream.makeStream(of: SpeechAnalyzerEvent.self)
    }

    func enqueue(_ input: SpeechInput) -> Bool {
        state.withLock { state in
            guard !state.isFull else { return false }
            if let start = input.startTime, !state.inputs.isEmpty {
                state.timelineJumps += 1
                state.jumpedTo = start
            }
            let start = input.startTime ?? state.timelineEnd
            state.inputs.append(input)
            state.inputStarts.append(start)
            state.timelineEnd = start + Double(input.samples.count) / LiveAudioChunk.sampleRate
            return true
        }
    }

    func finish() async throws {
        let behavior = state.withLock { state in
            state.finishCalls += 1
            return state.finishBehavior
        }
        switch behavior {
        case let .completes(events):
            events.forEach(send)
            sink.finish()
        case .hangs:
            try await Task.sleep(for: .seconds(3600))
        }
    }

    func cancel() async {
        state.withLock { $0.cancelCalls += 1 }
        sink.finish(throwing: CancellationError())
    }

    // MARK: Test controls

    func send(_ event: SpeechAnalyzerEvent) {
        let garbled = state.withLock { state -> SpeechAnalyzerEvent in
            guard case let .result(result) = event, result.isFinal, let jump = state.jumpedTo, result.start >= jump else { return event }
            state.jumpedTo = nil
            return .result(Self.garblingFirstPhrase(of: result))
        }
        sink.yield(garbled)
    }

    /// The words through the first sentence end become one "...", as the
    /// review's probe saw: "...@199.24-201.46", then "Thanks@201.52".
    static func garblingFirstPhrase(of result: SpeechResult) -> SpeechResult {
        guard let first = result.words.first else { return result }
        let phraseEnd = result.words.firstIndex { $0.text.hasSuffix(".") } ?? result.words.count - 1
        var garbled = result
        garbled.words = [TimedWord(text: "...", start: first.start, end: result.words[phraseEnd].end)] + result.words.dropFirst(phraseEnd + 1)
        return garbled
    }

    func fail() {
        sink.finish(throwing: FakeAnalyzerError())
    }

    func setFull(_ isFull: Bool) {
        state.withLock { $0.isFull = isFull }
    }

    func setFinishBehavior(_ behavior: FinishBehavior) {
        state.withLock { $0.finishBehavior = behavior }
    }

    var inputs: [SpeechInput] {
        state.withLock { $0.inputs }
    }

    var inputStarts: [TimeInterval] {
        state.withLock { $0.inputStarts }
    }

    var timelineJumps: Int {
        state.withLock { $0.timelineJumps }
    }

    var finishCalls: Int {
        state.withLock { $0.finishCalls }
    }

    var cancelCalls: Int {
        state.withLock { $0.cancelCalls }
    }
}

/// Makes a fresh fake analyzer for every request and records the requests.
final class FakeSpeechAnalyzerFactory: SpeechTrackAnalyzerFactory {
    struct Request: Equatable {
        var track: LiveTrack
        var locale: String
        var vocabulary: [String]
    }

    private struct State {
        var requests: [Request] = []
        var made: [LiveTrack: [FakeSpeechAnalyzer]] = [:]
    }

    private let error: LiveSessionError?
    private let state = Mutex(State())

    init(error: LiveSessionError? = nil) {
        self.error = error
    }

    func makeAnalyzer(for track: LiveTrack, locale: String, vocabulary: [String]) async throws -> any SpeechTrackAnalyzer {
        state.withLock { $0.requests.append(Request(track: track, locale: locale, vocabulary: vocabulary)) }
        if let error {
            throw error
        }
        let analyzer = FakeSpeechAnalyzer()
        state.withLock { $0.made[track, default: []].append(analyzer) }
        return analyzer
    }

    /// The track's current analyzer: the newest one made.
    func analyzer(_ track: LiveTrack) -> FakeSpeechAnalyzer? {
        analyzers(track).last
    }

    func analyzers(_ track: LiveTrack) -> [FakeSpeechAnalyzer] {
        state.withLock { $0.made[track] ?? [] }
    }

    var requests: [Request] {
        state.withLock { $0.requests }
    }
}

// MARK: - Session

func speechConfig(tracks: [LiveTrack] = [.mic, .system], language: LiveLanguage = .english, vocabulary: [String] = []) -> LiveSessionConfig {
    LiveSessionConfig(
        sessionID: UUID(),
        generation: 1,
        engine: .speechAnalyzer,
        whisperModel: nil,
        tracks: tracks,
        updateInterval: 2,
        language: language,
        vocabulary: vocabulary
    )
}

func startedSpeechSession(
    _ factory: FakeSpeechAnalyzerFactory,
    clock: ManualClock = ManualClock(),
    config: LiveSessionConfig = speechConfig()
) async throws -> SpeechAnalyzerLiveSession {
    let session = SpeechAnalyzerLiveSession(factory: factory, clock: clock)
    try await session.start(config)
    return session
}

extension SpeechAnalyzerLiveSession {
    func append(_ chunks: [LiveAudioChunk]) async {
        for chunk in chunks {
            await append(chunk)
        }
    }
}

extension AsyncStream<LiveTrackUpdate>.Iterator {
    /// The next `count` updates.
    mutating func next(_ count: Int) async -> [LiveTrackUpdate] {
        await next { $0.count >= count }
    }

    /// Updates until those read so far satisfy `isDone`, or the stream ends.
    mutating func next(until isDone: ([LiveTrackUpdate]) -> Bool) async -> [LiveTrackUpdate] {
        var updates: [LiveTrackUpdate] = []
        while !isDone(updates), let update = await next() {
            updates.append(update)
        }
        return updates
    }
}

// MARK: - Results

func finalResult(_ words: [TimedWord], from start: TimeInterval, to end: TimeInterval, finalizedThrough: TimeInterval? = nil) -> SpeechAnalyzerEvent {
    .result(SpeechResult(words: words, start: start, end: end, isFinal: true, finalizedThrough: finalizedThrough ?? end))
}

/// Volatile text is timed as a whole, from the analyzer's finalization point.
func volatileResult(_ text: String, from start: TimeInterval, to end: TimeInterval) -> SpeechAnalyzerEvent {
    .result(SpeechResult(words: [TimedWord(text: text, start: start, end: end)], start: start, end: end, isFinal: false, finalizedThrough: start))
}
