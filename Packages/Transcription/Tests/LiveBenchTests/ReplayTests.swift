import Foundation
import LiveTranscription
import LiveTranscriptModel
import Testing
@testable import live_bench

@Suite("Replay")
struct ReplayTests {
    @Test("two-track chunks are 250 ms per track at exact times; mixed chunks are the sum")
    func chunksMatchThePump() {
        let clip = ClipAudio(id: "clip", mic: (0 ..< 10000).map { Float($0) }, system: Array(repeating: 1, count: 9000))
        var twoTrack = ChunkAssembler(mode: .twoTrack)

        let first = twoTrack.take(releasedSamples: 8000, of: clip)
        #expect(first.map(\.track) == [.mic, .system, .mic, .system])
        #expect(first.map(\.startTime) == [0, 0, 0.25, 0.25])
        #expect(first.allSatisfy { $0.samples.count == 4000 && !$0.isDiscontinuity })
        #expect(first[2].samples.first == 4000)
        #expect(twoTrack.take(releasedSamples: 9600, of: clip).isEmpty)

        let last = twoTrack.flush(clip)
        #expect(last.map(\.startTime) == [0.5, 0.5])
        #expect(last.map(\.samples.count) == [2000, 2000])
        #expect(last[1].samples.last == 0, "the shorter system track is padded with silence")

        var mixed = ChunkAssembler(mode: .mixed)
        let mixedChunks = mixed.take(releasedSamples: 4000, of: clip)
        #expect(mixedChunks.map(\.track) == [.mixed])
        #expect(mixedChunks[0].samples[10] == 11)
    }

    @Test("a simulated replay logs every streamed update with its step's source time")
    func replayLogsEveryUpdateWithReleaseTimes() async throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let words = [
            TimedWord(text: " hello", start: 0.5, end: 0.8, probability: 0.9),
            TimedWord(text: " world", start: 1.0, end: 1.3, probability: 0.9),
            TimedWord(text: " again", start: 3.6, end: 3.9, probability: 0.9)
        ]
        let clip = ClipAudio(id: "clip", mic: Array(repeating: 0.1, count: 4 * 16000 + 800), system: Array(repeating: 0, count: 4 * 16000 + 800))
        let clock = VirtualClock()
        let session = WhisperLiveSession(decoder: ScriptedDecoder(words: words), clock: clock, scheduling: .manual)
        try await session.start(LiveSessionConfig(
            sessionID: UUID(), generation: 1, engine: .whisper, whisperModel: "test",
            tracks: [.mic, .system], updateInterval: 1, language: .english, vocabulary: []
        ))
        let source = PacedSource(sampleCount: clip.sampleCount, pacing: .simulated(clock))
        let runner = ReplayRunner(session: session, control: session.replayControl(virtualClock: clock), source: source, clip: clip, mode: .twoTrack)
        let eventsURL = temporary.url.appending(path: "events.jsonl")
        let events = try JSONLinesWriter(url: eventsURL)

        try await runner.run(events: events, finalURL: temporary.url.appending(path: "final.json"))
        try events.close()

        let lines = try jsonLines(eventsURL)
        let updates = lines.compactMap { $0["update"] as? [String: Any] }
        #expect(!lines.isEmpty && updates.count == lines.count)
        #expect(updates.compactMap { $0["revision"] as? Int } == Array(1 ... lines.count), "every streamed update is logged once, in order")
        let releaseTimes = lines.compactMap { $0["t_release"] as? Double }
        #expect(releaseTimes == releaseTimes.sorted())
        #expect(releaseTimes.allSatisfy { abs($0 * 10 - ($0 * 10).rounded()) < 1e-9 }, "simulated updates carry their step's time")
        for (line, update) in zip(lines, updates) {
            let released = line["t_release"] as? Double ?? 0
            #expect((update["transcribed_through"] as? Double ?? .infinity) <= released + 1e-9, "nothing is transcribed before it is released")
        }
        let final = try jsonObject(temporary.url.appending(path: "final.json"))
        #expect(final["session_ended_early"] as? Bool == false)
        #expect(final["t_release"] as? Double == clip.duration)
        let finalRows = (final["updates"] as? [[String: Any]] ?? []).flatMap { $0["rows"] as? [[String: Any]] ?? [] }
        let streamedRows = updates.flatMap { $0["rows"] as? [[String: Any]] ?? [] }
        let text = (streamedRows + finalRows).compactMap { $0["settled_text"] as? String }.joined()
        #expect(text.contains("hello") && text.contains("world") && text.contains("again"))
    }

    @Test("a replay stops feeding once the session fails, and says so in final.json")
    func replayStopsWhenTheSessionFails() async throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let clip = ClipAudio(id: "clip", mic: Array(repeating: 0.1, count: 60 * 16000), system: Array(repeating: 0.1, count: 60 * 16000))
        let clock = VirtualClock()
        let session = WhisperLiveSession(decoder: FailingDecoder(), clock: clock, scheduling: .manual)
        try await session.start(LiveSessionConfig(
            sessionID: UUID(), generation: 1, engine: .whisper, whisperModel: "test",
            tracks: [.mixed], updateInterval: 1, language: .english, vocabulary: []
        ))
        let source = PacedSource(sampleCount: clip.sampleCount, pacing: .simulated(clock))
        let events = try JSONLinesWriter(url: temporary.url.appending(path: "events.jsonl"))

        try await ReplayRunner(session: session, control: session.replayControl(virtualClock: clock), source: source, clip: clip, mode: .mixed)
            .run(events: events, finalURL: temporary.url.appending(path: "final.json"))

        let final = try jsonObject(temporary.url.appending(path: "final.json"))
        #expect(final["session_ended_early"] as? Bool == true)
        #expect((final["updates"] as? [Any])?.isEmpty == true)
        #expect(source.releasedThrough < 5, "stopped long before the end of the clip")
    }

    @Test("on a virtual clock, a final decode that never returns still meets the finish deadline")
    func virtualReplayFinishMeetsItsDeadline() async throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let clip = ClipAudio(id: "clip", mic: Array(repeating: 0.1, count: 2 * 16000 + 1600), system: [])
        let clock = VirtualClock()
        let session = WhisperLiveSession(decoder: HangingFinalDecoder(end: clip.duration), clock: clock, scheduling: .manual)
        try await session.start(LiveSessionConfig(
            sessionID: UUID(), generation: 1, engine: .whisper, whisperModel: "test",
            tracks: [.mixed], updateInterval: 1, language: .english, vocabulary: []
        ))
        let source = PacedSource(sampleCount: clip.sampleCount, pacing: .simulated(clock))
        let events = try JSONLinesWriter(url: temporary.url.appending(path: "events.jsonl"))
        var runner = ReplayRunner(session: session, control: session.replayControl(virtualClock: clock), source: source, clip: clip, mode: .mixed)
        runner.finishTimeout = .milliseconds(100)

        let finishSeconds = try await runner.run(events: events, finalURL: temporary.url.appending(path: "final.json"))

        #expect(finishSeconds < 5)
        let final = try jsonObject(temporary.url.appending(path: "final.json"))
        let rows = (final["updates"] as? [[String: Any]] ?? []).flatMap { $0["rows"] as? [[String: Any]] ?? [] }
        #expect(final["session_ended_early"] as? Bool == false)
        #expect(rows.contains { $0["is_incomplete"] as? Bool == true }, "the open row is committed and marked incomplete")
    }

    @Test("cost decodes are prompted with whole words that end before the window, within the limit")
    func costContextUsesTheTextBeforeEachWindow() {
        let reference = ReferenceText(words: [
            .init(text: "so", start: 0, end: 0.4),
            .init(text: "twenty-five", start: 0.5, end: 1.2),
            .init(text: "euros", start: 1.3, end: 1.8),
            .init(text: "later", start: 2.5, end: 2.9)
        ])

        #expect(reference.context(before: 1.8, limit: 100) == "so twenty-five euros")
        #expect(reference.context(before: 1.8, limit: 18) == "twenty-five euros")
        #expect(reference.context(before: 1.0, limit: 100) == "so")
        #expect(reference.context(before: 0.1, limit: 100).isEmpty)
    }

    @Test("cost statistics: a true median and a nearest-rank p95")
    func costStatisticsUseNearestRank() {
        let values = (1 ... 10).map(Double.init).shuffled()

        #expect(CostStatistics.median(values) == 5.5)
        #expect(CostStatistics.percentile(values, 95) == 10)
        #expect(CostStatistics.percentile(values, 50) == 5)
        #expect(CostStatistics.percentile([3, 1, 2], 50) == 2)
        #expect(CostStatistics.median([]) == 0)
    }

    @Test("cost windows spread over the clip and always fit")
    func windowOffsetsSpreadOverTheClip() {
        #expect(CostStatistics.windowOffsets(sampleCount: 100, windowSamples: 30, count: 3) == [0, 35, 70])
        #expect(CostStatistics.windowOffsets(sampleCount: 100, windowSamples: 30, count: 1) == [0])
        #expect(CostStatistics.windowOffsets(sampleCount: 20, windowSamples: 30, count: 2) == [0, 0])
    }

    @Test("call load idles in proportion to its duty cycle and sizes GPU batches to the target")
    func callLoadDutyCycle() {
        #expect(abs(SimulatedCallLoad.idleSeconds(afterBusy: 0.03, dutyCycle: 0.3) - 0.07) < 1e-12)
        #expect(SimulatedCallLoad.nextBatchSize(current: 4, measuredSeconds: 0.06) == 2)
        #expect(SimulatedCallLoad.nextBatchSize(current: 1, measuredSeconds: 0.001) == 30)
        #expect(SimulatedCallLoad.nextBatchSize(current: 1, measuredSeconds: 0) == 1)
    }
}
