import ArgumentParser
import Foundation
import LiveTranscription
import LiveTranscriptModel
import Synchronization
import Testing
@testable import live_bench

@Suite("SpeechAnalyzer option")
struct SpeechAnalyzerBenchTests {
    static let required = ["--models", "m", "--fixtures", "f", "--out", "o", "--interval", "2", "--mode", "two-track", "--clips", "smoke"]

    /// The message `run` prints for these arguments, or nil when they parse.
    func parseError(_ arguments: [String]) -> String? {
        do {
            _ = try RunCommand.parse(Self.required + arguments)
            return nil
        } catch {
            return RunCommand.message(for: error)
        }
    }

    @Test("flags that belong to the other engine are refused when parsing")
    func speechAnalyzerFlagsAreValidated() throws {
        #expect(parseError(["--option", "speechanalyzer", "--model", "x"])?.contains("--model applies only to the Whisper options") == true)
        #expect(parseError(["--option", "speechanalyzer", "--virtual-clock"])?.contains("--virtual-clock applies only to the Whisper options") == true)
        #expect(parseError(["--option", "whisper-current", "--fast-results"])?.contains("--fast-results applies only to --option speechanalyzer") == true)

        let fast = try RunCommand.parse(Self.required + ["--option", "speechanalyzer", "--fast-results"])
        #expect(fast.folderName.hasSuffix("-speechanalyzer-i2-two-track-fast"))
        #expect(parseError(["--option", "whisper-small", "--model", "openai_whisper-base"]) == nil)
    }

    @Test("work alongside the replay is named in the folder and must be described")
    func alongsideIsRecorded() throws {
        let beside = try RunCommand.parse(Self.required + ["--option", "whisper-current", "--load", "call", "--alongside", "final pass of soak"])
        #expect(beside.folderName.hasSuffix("-whisper-current-i2-two-track-load-alongside"))
        #expect(beside.alongside == "final pass of soak")
        #expect(parseError(["--option", "whisper-current", "--alongside", " "])?.contains("--alongside needs a description") == true)
    }

    @Test("the Whisper prompt choice is refused with SpeechAnalyzer and named in the folder")
    func whisperPromptIsWhisperOnly() throws {
        #expect(parseError(["--option", "speechanalyzer", "--whisper-prompt", "none"])?.contains("--whisper-prompt applies only to the Whisper options") == true)

        let unprompted = try RunCommand.parse(Self.required + ["--option", "whisper-small", "--whisper-prompt", "none"])
        #expect(unprompted.folderName.hasSuffix("-whisper-small-i2-two-track-prompt-none"))
        #expect(unprompted.whisperPrompt.decoderPrompt == .none)
        let restored = try RunCommand.parse(Self.required + ["--option", "whisper-current", "--whisper-prompt", "settled-text-timestamp-rules"])
        #expect(restored.whisperPrompt.decoderPrompt == .vocabularyAndSettledText && restored.whisperPrompt.restoresTimestampRules)
        let spec = try RunCommand.parse(Self.required + ["--option", "whisper-current"])
        #expect(spec.folderName.hasSuffix("-whisper-current-i2-two-track"), "the spec's prompt is the default and adds nothing")
    }

    @Test("dry-run cuts are checked when parsing and cut a clip to its first seconds")
    func dryRunCutsAreParsed() throws {
        #expect(parseError(["--option", "whisper-current", "--clip-seconds", "0"])?.contains("--clip-seconds must be positive") == true)
        #expect(parseError(["--option", "whisper-current", "--baseline-seconds", "0"])?.contains("--baseline-seconds must be at least 1") == true)
        let paths = ["--models", "m", "--fixtures", "f", "--out", "o", "--clips", "smoke"]
        #expect(throws: (any Error).self) { try FinalPassCommand.parse(paths + ["--clip-seconds", "-1"]) }
        #expect(try FinalPassCommand.parse(paths + ["--clip-seconds", "5"]).clipSeconds == 5)
        let cut = try RunCommand.parse(Self.required + ["--option", "whisper-current", "--clip-seconds", "0.5", "--baseline-seconds", "2"])
        #expect(cut.dryRun.clipSeconds == 0.5 && cut.dryRun.baselineSeconds == 2)

        let clip = ClipAudio(id: "clip", mic: Array(repeating: 0.1, count: 16000), system: Array(repeating: 0.2, count: 12000))
        #expect(clip.prefix(seconds: 0.5).sampleCount == 8000)
        #expect(clip.prefix(seconds: 0.5).system.allSatisfy { $0 == 0.2 })
        #expect(clip.prefix(seconds: 5).sampleCount == 16000, "never longer than the clip")
        #expect(clip.prefix(seconds: nil).sampleCount == 16000)
    }

    @Test("a replay through the SpeechAnalyzer session logs its updates and the finish")
    func replayRunsASpeechAnalyzerSession() async throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let clip = ClipAudio(id: "clip", mic: Array(repeating: 0.1, count: 16000), system: Array(repeating: 0.1, count: 16000))
        let session = SpeechAnalyzerLiveSession(factory: EchoSpeechAnalyzerFactory())
        try await session.start(LiveSessionConfig(
            sessionID: UUID(), generation: 1, engine: .speechAnalyzer, whisperModel: nil,
            tracks: [.mic, .system], updateInterval: 2, language: .locale("en-US"), vocabulary: []
        ))
        let source = PacedSource(sampleCount: clip.sampleCount, pacing: .simulated(VirtualClock()))
        let eventsURL = temporary.url.appending(path: "events.jsonl")
        let events = try JSONLinesWriter(url: eventsURL)

        try await ReplayRunner(session: session, control: session.replayControl(), source: source, clip: clip, mode: .twoTrack)
            .run(events: events, finalURL: temporary.url.appending(path: "final.json"))
        try events.close()

        // The session reads its analyzers on its own tasks, so how many updates
        // stream before `finish` depends on scheduling; their order does not.
        let updates = try jsonLines(eventsURL).compactMap { $0["update"] as? [String: Any] }
        #expect(updates.compactMap { $0["revision"] as? Int } == updates.indices.map { $0 + 1 })
        let final = try jsonObject(temporary.url.appending(path: "final.json"))
        #expect(final["session_ended_early"] as? Bool == false)
        let finalUpdates = final["updates"] as? [[String: Any]] ?? []
        #expect(finalUpdates.compactMap { $0["track"] as? String } == ["mic", "system"])
        let rows = finalUpdates.flatMap { $0["rows"] as? [[String: Any]] ?? [] }
        #expect(rows.compactMap { $0["settled_text"] as? String } == ["hello", "hello"])
        #expect(finalUpdates.compactMap { $0["settled_through"] as? Double } == [1, 1])
    }
}

/// Reports the audio it takes, and hears "hello" once finished.
final class EchoSpeechAnalyzer: SpeechTrackAnalyzer {
    let events: AsyncThrowingStream<SpeechAnalyzerEvent, any Error>
    private let sink: AsyncThrowingStream<SpeechAnalyzerEvent, any Error>.Continuation
    private let timelineEnd = Mutex<TimeInterval>(0)

    init() {
        (events, sink) = AsyncThrowingStream.makeStream(of: SpeechAnalyzerEvent.self)
    }

    func enqueue(_ input: SpeechInput) -> Bool {
        let end = timelineEnd.withLock { end in
            end = (input.startTime ?? end) + Double(input.samples.count) / LiveAudioChunk.sampleRate
            return end
        }
        sink.yield(.received(through: end))
        return true
    }

    func finish() async throws {
        let end = timelineEnd.withLock { $0 }
        let hello = TimedWord(text: " hello", start: 0.2, end: 0.5)
        sink.yield(.result(SpeechResult(words: [hello], start: 0, end: end, isFinal: true, finalizedThrough: end)))
        sink.finish()
    }

    func cancel() async {
        sink.finish()
    }
}

struct EchoSpeechAnalyzerFactory: SpeechTrackAnalyzerFactory {
    func makeAnalyzer(for _: LiveTrack, locale _: String, vocabulary _: [String]) async throws -> any SpeechTrackAnalyzer {
        EchoSpeechAnalyzer()
    }
}
