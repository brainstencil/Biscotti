import Foundation
import LiveTranscriptModel
import Testing
@testable import LiveTranscription

@Suite("SpeechAnalyzerLiveSession")
struct SpeechAnalyzerLiveSessionTests {
    @Test("start refuses configs the engine cannot run, and passes English as en-US with the vocabulary")
    func startValidatesConfig() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        var whisper = speechConfig()
        whisper.engine = .whisper
        var badInterval = speechConfig()
        badInterval.updateInterval = 0

        await #expect(throws: LiveSessionError.unsupportedEngine(.whisper)) { try await SpeechAnalyzerLiveSession(factory: factory).start(whisper) }
        await #expect(throws: LiveSessionError.unsupportedTracks([.mic])) {
            try await SpeechAnalyzerLiveSession(factory: factory).start(speechConfig(tracks: [.mic]))
        }
        await #expect(throws: LiveSessionError.invalidUpdateInterval) { try await SpeechAnalyzerLiveSession(factory: factory).start(badInterval) }
        await #expect(throws: LiveSessionError.languageUnsupported("detect")) {
            try await SpeechAnalyzerLiveSession(factory: factory).start(speechConfig(language: .detect))
        }
        #expect(factory.requests.isEmpty)

        let session = SpeechAnalyzerLiveSession(factory: factory)
        try await session.start(speechConfig(vocabulary: ["Biscotti"]))
        await #expect(throws: LiveSessionError.alreadyStarted) { try await session.start(speechConfig()) }
        let french = SpeechAnalyzerLiveSession(factory: factory)
        try await french.start(speechConfig(tracks: [.mixed], language: .locale("fr-FR")))
        #expect(factory.requests == [
            .init(track: .mic, locale: "en-US", vocabulary: ["Biscotti"]),
            .init(track: .system, locale: "en-US", vocabulary: ["Biscotti"]),
            .init(track: .mixed, locale: "fr-FR", vocabulary: [])
        ])

        let missingAsset = SpeechAnalyzerLiveSession(factory: FakeSpeechAnalyzerFactory(error: .assetNotInstalled("en-US")))
        await #expect(throws: LiveSessionError.assetNotInstalled("en-US")) { try await missingAsset.start(speechConfig()) }
        #expect(await missingAsset.phase == .idle, "a failed start can be retried")
        await session.cancel()
        await french.cancel()
    }

    @Test("audio dropped by a full input queue becomes one overflow gap, and silence takes its place on the analyzer's timeline")
    func fullQueueReportsOneOverflowGap() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let session = try await startedSpeechSession(factory, config: speechConfig(tracks: [.mixed]))
        let analyzer = try #require(factory.analyzer(.mixed))
        var updates = session.updates.makeAsyncIterator()
        let audio = chunks(.mixed, from: 0, to: 2)

        await session.append(Array(audio[0 ..< 2]))
        analyzer.setFull(true)
        await session.append(Array(audio[2 ..< 5]))
        analyzer.setFull(false)
        await session.append(Array(audio[5...]))

        #expect(analyzer.inputs.map(\.startTime) == [0, nil, nil, nil, nil])
        #expect(analyzer.inputs.map(\.samples.count) == [4000, 4000, 16000, 4000, 4000])
        #expect(analyzer.inputStarts == [0, 0.25, 0.5, 1.5, 1.75])
        let update = await updates.next(1)
        #expect(update.flatMap(\.gaps) == [LiveGap(track: .mixed, startTime: 0.5, duration: 0.75, reason: .queueOverflow)])
        await session.cancel()
    }

    @Test("a pause sends no audio and reports one gap; on resume, silence covers it on the analyzer's timeline")
    func pauseEmitsOneGapAndRestartsTimeline() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let session = try await startedSpeechSession(factory)
        let mic = try #require(factory.analyzer(.mic))
        var updates = session.updates.makeAsyncIterator()

        await session.append(chunks(.mic, from: 0, to: 1))
        await session.setPaused(true)
        await session.append(chunks(.mic, from: 1, to: 3))
        await session.setPaused(false)
        await session.append(chunks(.mic, from: 3, to: 3.5))

        #expect(mic.inputs.map(\.startTime) == [0, nil, nil, nil, nil, nil])
        #expect(mic.inputs.map(\.samples.count) == [4000, 4000, 4000, 4000, 36000, 4000])
        #expect(mic.inputStarts.last == 3.25)
        let update = await updates.next(1)
        #expect(update.flatMap(\.gaps) == [LiveGap(track: .mic, startTime: 1, duration: 2, reason: .paused)])
        await session.cancel()
    }

    @Test("finish returns the analyzer's last results, merged per track, and the stream ends without them")
    func finishReturnsFinalRowsOutsideTheStream() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let session = try await startedSpeechSession(factory)
        let mic = try #require(factory.analyzer(.mic))
        mic.setFinishBehavior(.completes([
            finalResult([word("hello", 0.2, 0.6)], from: 0, to: 0.9),
            .received(through: 1)
        ]))
        var updates = session.updates.makeAsyncIterator()
        await session.append(chunks(.mic, from: 0, to: 1))
        mic.send(volatileResult("hel", from: 0, to: 1))
        let streamed = await updates.next(1)

        let finished = await session.finish(timeout: .seconds(10))

        #expect(streamed.flatMap(\.rows).map(\.tailText) == ["hel"])
        #expect(finished.map(\.track) == [.mic])
        #expect(finished.map(\.rows.count) == [1])
        let row = try #require(finished.first?.rows.first)
        #expect(row.settledText == "hello" && row.tailText.isEmpty && row.isClosed && !row.isIncomplete)
        #expect(finished.first?.settledThrough == 1)
        #expect(await updates.next() == nil)
        #expect(mic.finishCalls == 1)
        #expect(await session.hasEnded)
    }

    @Test("a track that never got audio is cancelled at finish, not finished")
    func trackWithoutAudioIsCancelledAtFinish() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let session = try await startedSpeechSession(factory)
        let system = try #require(factory.analyzer(.system))
        await session.append(chunks(.mic, from: 0, to: 0.5))

        let finished = await session.finish(timeout: .seconds(10))

        #expect(finished.map(\.track) == [.mic])
        #expect(system.finishCalls == 0)
        #expect(await eventually { system.cancelCalls == 1 })
    }

    @Test("when finishing runs out of time, the tail is settled as it is and marked incomplete")
    func finishTimeoutMarksTailIncomplete() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let clock = ManualClock()
        let session = try await startedSpeechSession(factory, clock: clock, config: speechConfig(tracks: [.mixed]))
        let analyzer = try #require(factory.analyzer(.mixed))
        analyzer.setFinishBehavior(.hangs)
        var updates = session.updates.makeAsyncIterator()
        await session.append(chunks(.mixed, from: 0, to: 2))
        analyzer.send(finalResult([word("We", 0.1, 0.4)], from: 0, to: 0.5))
        analyzer.send(volatileResult(" agreed on", from: 0.5, to: 2))
        _ = await updates.next(2)

        let finishing = Task { await session.finish(timeout: .seconds(10)) }
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(10))
        let finished = await finishing.value

        let rows = finished.flatMap(\.rows)
        #expect(rows.map(\.settledText) == ["We agreed on"])
        #expect(rows.allSatisfy { $0.isIncomplete && $0.isClosed && $0.tailText.isEmpty })
        #expect(await eventually { analyzer.cancelCalls == 1 })
    }

    @Test("an analyzer replaced after a long gap that does not finish in time is cancelled, and its tail is kept as incomplete")
    func replacedAnalyzerThatHangsIsCancelled() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let clock = ManualClock()
        let session = try await startedSpeechSession(factory, clock: clock, config: speechConfig(tracks: [.mixed]))
        let before = try #require(factory.analyzer(.mixed))
        before.setFinishBehavior(.hangs)
        var updates = session.updates.makeAsyncIterator()
        await session.append(chunks(.mixed, from: 0, to: 1))
        before.send(volatileResult("We agreed", from: 0, to: 1))
        _ = await updates.next(1)

        var afterGap = chunks(.mixed, from: 100, to: 100.25)
        afterGap[0].isDiscontinuity = true
        let appending = Task { await session.append(afterGap) }
        #expect(await eventually { clock.sleeperCount == 1 })
        clock.advance(by: SpeechAnalyzerLiveSession.replacedAnalyzerTimeout)
        await appending.value

        let rows = await latestRows(updates.next { latestRows($0).contains(where: \.isClosed) })
        #expect(rows.map(\.settledText) == ["We agreed"])
        #expect(rows.allSatisfy { $0.isIncomplete && $0.isClosed })
        #expect(before.cancelCalls >= 1)
        #expect(factory.analyzers(.mixed).count == 2)
        #expect(factory.analyzer(.mixed)?.inputs.map(\.startTime) == [100])
        await session.cancel()
    }

    @Test("appends that overlap a replacement wait for the fresh analyzer and reach it in order", .timeLimit(.minutes(1)))
    func overlappingAppendsWaitForTheFreshAnalyzer() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let clock = ManualClock()
        let session = try await startedSpeechSession(factory, clock: clock, config: speechConfig(tracks: [.mixed]))
        let before = try #require(factory.analyzer(.mixed))
        before.setFinishBehavior(.hangs)
        await session.append(chunks(.mixed, from: 0, to: 1))
        var afterGap = chunks(.mixed, from: 100, to: 100.5)
        afterGap[0].isDiscontinuity = true
        let (first, second) = (afterGap[0], afterGap[1])

        let replacing = Task { await session.append(first) }
        #expect(await eventually { clock.sleeperCount == 1 })
        await session.append(second)
        #expect(clock.sleeperCount == 1, "the second chunk does not start another replacement")
        clock.advance(by: SpeechAnalyzerLiveSession.replacedAnalyzerTimeout)
        await replacing.value

        let made = factory.analyzers(.mixed)
        #expect(made.count == 2)
        #expect(before.finishCalls == 1)
        #expect(made.last?.inputs.map(\.startTime) == [100, nil])
        #expect(made.last?.inputStarts == [100, 100.25])
        await session.cancel()
        #expect(await eventually { made.allSatisfy { $0.cancelCalls >= 1 } }, "no analyzer is left running")
    }

    @Test("finishing while a track is between analyzers reports the audio that never reached one as a gap", .timeLimit(.minutes(1)))
    func finishingDuringAReplacementReportsTheHeldAudio() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let clock = ManualClock()
        let session = try await startedSpeechSession(factory, clock: clock, config: speechConfig(tracks: [.mixed]))
        let before = try #require(factory.analyzer(.mixed))
        before.setFinishBehavior(.hangs)
        await session.append(chunks(.mixed, from: 0, to: 1))
        var afterGap = chunks(.mixed, from: 100, to: 100.5)
        afterGap[0].isDiscontinuity = true
        let (first, second) = (afterGap[0], afterGap[1])

        let replacing = Task { await session.append(first) }
        #expect(await eventually { clock.sleeperCount == 1 })
        await session.append(second)
        let finishing = Task { await session.finish(timeout: .seconds(10)) }
        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: SpeechAnalyzerLiveSession.replacedAnalyzerTimeout)
        await replacing.value
        let finished = await finishing.value

        #expect(finished.flatMap(\.gaps) == [LiveGap(track: .mixed, startTime: 100, duration: 0.5, reason: .engineRestart)])
        #expect(factory.analyzers(.mixed).count == 1, "no fresh analyzer starts once finishing has begun")
        #expect(await eventually { before.cancelCalls >= 1 })
    }

    @Test("finishing during a replacement that a long overflow started ends the overflow gap where the held audio starts", .timeLimit(.minutes(1)))
    func finishingDuringAnOverflowReplacementKeepsGapsApart() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let clock = ManualClock()
        let session = try await startedSpeechSession(factory, clock: clock, config: speechConfig(tracks: [.mixed]))
        let before = try #require(factory.analyzer(.mixed))
        await session.append(chunks(.mixed, from: 0, to: 1))
        before.setFull(true)
        before.setFinishBehavior(.hangs)
        await session.append(chunks(.mixed, from: 1, to: 61.25))
        let trigger = chunks(.mixed, from: 61.25, to: 61.5)[0]

        let replacing = Task { await session.append(trigger) }
        #expect(await eventually { clock.sleeperCount == 1 })
        await session.append(chunks(.mixed, from: 61.5, to: 62))
        let finishing = Task { await session.finish(timeout: .seconds(10)) }
        #expect(await eventually { clock.sleeperCount == 2 })
        clock.advance(by: SpeechAnalyzerLiveSession.replacedAnalyzerTimeout)
        await replacing.value
        let finished = await finishing.value

        #expect(finished.flatMap(\.gaps) == [
            LiveGap(track: .mixed, startTime: 1, duration: 60.25, reason: .queueOverflow),
            LiveGap(track: .mixed, startTime: 61.25, duration: 0.75, reason: .engineRestart)
        ])
    }

    @Test("an analyzer that fails while running ends the session")
    func analyzerFailureEndsSession() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let session = try await startedSpeechSession(factory)
        await session.append(chunks(.mic, from: 0, to: 0.5))

        try #require(factory.analyzer(.mic)).fail()

        #expect(await session.collectedUpdates().isEmpty, "the stream ends")
        #expect(await session.hasEnded)
        #expect(await session.finish(timeout: .seconds(1)).isEmpty)
        #expect(await eventually { factory.analyzer(.system)?.cancelCalls == 1 })
    }

    @Test("cancel ends the stream and the analyzers, and later audio is ignored")
    func cancelEndsStreamAndAnalyzers() async throws {
        let factory = FakeSpeechAnalyzerFactory()
        let session = try await startedSpeechSession(factory)
        await session.append(chunks(.mic, from: 0, to: 0.5))

        await session.cancel()
        await session.append(chunks(.mic, from: 0.5, to: 1))

        #expect(await session.collectedUpdates().isEmpty)
        #expect(factory.analyzer(.mic)?.inputs.count == 2)
        #expect(await session.finish(timeout: .seconds(1)).isEmpty)
        #expect(await eventually { factory.analyzer(.mic)?.cancelCalls == 1 && factory.analyzer(.system)?.cancelCalls == 1 })
    }
}

extension SpeechAnalyzerLiveSession {
    func collectedUpdates() async -> [LiveTrackUpdate] {
        var collected: [LiveTrackUpdate] = []
        for await update in updates {
            collected.append(update)
        }
        return collected
    }
}
