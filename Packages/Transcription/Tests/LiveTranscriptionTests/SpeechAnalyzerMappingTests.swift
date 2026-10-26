import Foundation
import LiveTranscriptModel
import Testing
@testable import LiveTranscription

@Suite("SpeechAnalyzer result mapping")
struct SpeechAnalyzerMappingTests {
    @Test("final results settle their words in the open row and clear the tail; a pause opens a new row")
    func finalResultsBecomeSettledRows() throws {
        var transcript = SpeechTrackTranscript(track: .system, startTime: 0)
        let shown = transcript.apply(volatileResult("Hello every", from: 0, to: 2))
        let rowID = try #require(shown.first?.id)

        let settled = transcript.apply(finalResult([word("Hello,", 0.2, 0.5), word("everyone.", 0.5, 1.0)], from: 0, to: 1.02))
        #expect(settled.map(\.id) == [rowID], "the tail's bubble becomes the settled row")
        #expect(settled.map(\.settledText) == ["Hello, everyone."])
        #expect(settled.allSatisfy { $0.tailText.isEmpty && !$0.isClosed })

        let joined = transcript.apply(finalResult([word("Thanks", 1.1, 1.4)], from: 1.02, to: 1.5))
        #expect(joined.map(\.settledText) == ["Hello, everyone. Thanks"])

        let afterPause = transcript.apply(finalResult([word("Bye.", 4.0, 4.3)], from: 1.5, to: 4.4))
        #expect(afterPause.map(\.settledText) == ["Hello, everyone. Thanks", "Bye."])
        #expect(afterPause.map(\.isClosed) == [true, false])
        #expect(afterPause[1].id != rowID)
        #expect(transcript.settledThrough == 4.4)
    }

    @Test("each volatile result replaces the tail of the same row; settled text stays")
    func volatileResultReplacesTail() {
        var transcript = SpeechTrackTranscript(track: .mic, startTime: 0)
        _ = transcript.apply(finalResult([word("We", 0.0, 0.3)], from: 0, to: 0.4))

        let first = transcript.apply(volatileResult(" agreed", from: 0.4, to: 2))
        let second = transcript.apply(volatileResult(" agreed on twenty", from: 0.4, to: 3))

        #expect(first.map(\.tailText) == [" agreed"])
        #expect(second.map(\.tailText) == [" agreed on twenty"])
        #expect(first.map(\.id) == second.map(\.id))
        #expect(second.map(\.settledText) == ["We"])
        #expect(transcript.settledThrough == 0.4, "volatile text is not settled")
        #expect(transcript.transcribedThrough == 3)
    }

    @Test("inputs keep the analyzer's timeline on the recording's: a start time first, then silence for a gap")
    func resultTimesUseBufferStartTime() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let session = try await startedSpeechSession(factory)
        let mic = try #require(factory.analyzer(.mic))
        var updates = session.updates.makeAsyncIterator()

        await session.append(chunks(.mic, from: 100, to: 101))
        var afterGap = chunks(.mic, from: 130, to: 130.5)
        afterGap[0].isDiscontinuity = true
        await session.append(afterGap)

        #expect(mic.inputs.map(\.startTime) == [100, nil, nil, nil, nil, nil])
        #expect(mic.inputs[4].samples.count == 29 * 16000 + 4000, "29 s of silence, then the chunk")
        #expect(mic.inputs[4].samples.prefix(29 * 16000).allSatisfy { $0 == 0 })
        #expect(mic.inputStarts == [100, 100.25, 100.5, 100.75, 101, 130.25])
        let gaps = await updates.next(1).flatMap(\.gaps)
        #expect(gaps == [LiveGap(track: .mic, startTime: 101, duration: 29, reason: .captureGap)])

        mic.send(finalResult([word("hello", 100.2, 100.6)], from: 100, to: 100.8))
        mic.send(finalResult([word("again", 130.1, 130.4)], from: 130, to: 130.5))
        let rows = await latestRows(updates.next(2))
        #expect(rows.map(\.startTime) == [100.2, 130.1])
        #expect(rows.map(\.settledText) == ["hello", "again"])
        await session.cancel()
    }

    @Test(
        "after a gap over 60 s the track's analyzer finishes and a fresh one starts at the new time, so no timeline jumps and the words after the gap are kept",
        .timeLimit(.minutes(1))
    )
    func longGapStartsAFreshAnalyzer() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let session = try await startedSpeechSession(factory)
        let before = try #require(factory.analyzer(.mic))
        before.setFinishBehavior(.completes([finalResult([word("Okay.", 0.2, 0.6)], from: 0, to: 1)]))
        var updates = session.updates.makeAsyncIterator()
        await session.append(chunks(.mic, from: 0, to: 1))
        before.send(volatileResult("Okay", from: 0, to: 1))

        var afterGap = chunks(.mic, from: 100, to: 101)
        afterGap[0].isDiscontinuity = true
        await session.append(afterGap)
        let after = try #require(factory.analyzer(.mic))
        after.send(finalResult(
            [word("Twenty", 100.1, 100.4), word("five", 100.4, 100.6), word("people", 100.6, 101.0), word("joined.", 101.0, 101.4), word("Thanks", 101.5, 101.8)],
            from: 100,
            to: 101.9
        ))
        let seen = await updates.next { latestRows($0).contains { $0.settledText.hasSuffix("Thanks") } }

        #expect(factory.analyzers(.mic).count == 2)
        #expect(factory.analyzers(.mic).allSatisfy { $0.timelineJumps == 0 })
        #expect(before.finishCalls == 1)
        #expect(before.inputs.map(\.startTime) == [0, nil, nil, nil])
        #expect(after.inputs.map(\.startTime) == [100, nil, nil, nil])
        let rows = latestRows(seen)
        #expect(rows.map(\.settledText) == ["Okay.", "Twenty five people joined. Thanks"])
        #expect(rows.first?.isClosed == true, "the text before the gap settled before the fresh analyzer started")
        #expect(seen.flatMap(\.gaps) == [LiveGap(track: .mic, startTime: 1, duration: 99, reason: .captureGap)])
        await session.cancel()
    }

    @Test("the fake analyzer, like SpeechAnalyzer, returns the first phrase after a jump in its timeline as one punctuation-only word")
    func fakeAnalyzerGarblesAfterAJump() async throws {
        let analyzer = FakeSpeechAnalyzer()
        _ = analyzer.enqueue(SpeechInput(samples: [0], startTime: 0))
        _ = analyzer.enqueue(SpeechInput(samples: [0], startTime: 100))
        analyzer.send(finalResult([word("Twenty", 100.1, 100.4), word("joined.", 100.4, 100.9), word("Thanks", 101, 101.3)], from: 100, to: 101.4))

        var events = analyzer.events.makeAsyncIterator()
        let event = try await events.next()

        guard case let .result(result) = event else {
            Issue.record("expected a result, got \(String(describing: event))")
            return
        }
        #expect(result.words.map(\.text) == ["...", " Thanks"])
        #expect(analyzer.timelineJumps == 1)
    }

    @Test("the analyzer's progress moves transcribedThrough; only delivered finalization moves settledThrough")
    func watermarksFollowTheAnalyzer() {
        var transcript = SpeechTrackTranscript(track: .mic, startTime: 10)

        _ = transcript.apply(.received(through: 12))
        #expect(transcript.watermarks == .init(transcribedThrough: 12, settledThrough: 10))

        _ = transcript.apply(volatileResult(" so", from: 10, to: 12))
        #expect(transcript.settledThrough == 10)

        _ = transcript.apply(finalResult([word("so", 10.2, 10.5)], from: 10, to: 11))
        #expect(transcript.watermarks == .init(transcribedThrough: 12, settledThrough: 11))

        _ = transcript.apply(.result(SpeechResult(words: [], start: 11, end: 11.5, isFinal: true, finalizedThrough: 14)))
        #expect(transcript.settledThrough == 12, "never past the audio the analyzer has taken")
    }

    @Test("an incomplete finish settles the tail and marks the rows")
    func incompleteFinishSettlesTheTail() {
        var transcript = SpeechTrackTranscript(track: .mic, startTime: 0)
        _ = transcript.apply(finalResult([word("We", 0.0, 0.3)], from: 0, to: 0.4))
        _ = transcript.apply(volatileResult(" agreed on", from: 0.4, to: 2))

        let rows = transcript.close(incomplete: true, through: 3)

        #expect(rows.map(\.settledText) == ["We agreed on"])
        #expect(rows.allSatisfy { $0.isClosed && $0.isIncomplete && $0.tailText.isEmpty })
        #expect(transcript.watermarks == .init(transcribedThrough: 2, settledThrough: 2), "an incomplete finish resolves nothing further")
    }
}
