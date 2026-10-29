import BiscottiTestSupport
import Foundation
import LiveTranscriptModel
import Testing
@testable import LiveTranscriptionService

private let firstSecond = LiveRow(track: .mic, startTime: 0, endTime: 1, settledText: "Hello", tailText: " wor")

@MainActor
private extension LiveFixture {
    /// Waits until the pump has taken the tap's audio through `time`.
    func waitForCapture(through time: TimeInterval) async throws {
        try await waitUntil("the pump to take the audio") {
            (service.snapshot(includeTail: true)?.captureWatermark ?? 0) >= time - 1e-9
        }
    }

    func hold(_ reason: String = "test", maximum: Duration = .seconds(120)) -> LiveDecodingHold {
        service.holdDecoding(reason: reason, maximum: maximum)
    }
}

/// Lets queued work run, so a chunk that should wait would have been offered.
private func settle() async throws {
    try await Task.sleep(for: .milliseconds(50))
}

@Suite("LiveTranscriptionService -- live hold")
@MainActor
struct LiveDecodingHoldTests {
    @Test("While held, the engine is paused and offered no chunks; the pump keeps taking the audio")
    func holdStopsOffers() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        let hold = fix.hold()
        #expect(fix.service.isDecodingHeld)
        try await waitUntil("the pause") { await engine.pausedCalls == [true] }

        fix.tap.mic.pushTone(seconds: 2, from: 0)
        try await fix.waitForCapture(through: 2)
        try await settle()

        #expect(await engine.offered.isEmpty)
        hold.release()
        #expect(!fix.service.isDecodingHeld)
    }

    @Test("After a release, every held chunk reaches the resumed engine in order, the older ones as backfill, with no gap")
    func releaseCatchesUpWithoutGap() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        let hold = fix.hold()
        try await waitUntil("the pause") { await engine.pausedCalls == [true] }
        fix.tap.mic.pushTone(seconds: 20, from: 0)
        try await fix.waitForCapture(through: 20)
        #expect(await engine.offered.isEmpty)

        hold.release()
        try await waitUntil("all eighty chunks") { await engine.offered.count == 80 }

        let chunks = await engine.offered
        #expect(chunks.first?.startTime == 0)
        #expect(isContiguous(chunks))
        // Captured times add up 100 ms blocks, so the chunk at the boundary itself may go either way.
        let lagLimit = 20 - LiveAudioLimits.backfillLag
        let olderAreBackfill = chunks.filter { $0.endTime < lagLimit - 0.1 }.allSatisfy(\.isBackfill)
        let newestAreLive = chunks.filter { $0.endTime > lagLimit + 0.1 }.allSatisfy { !$0.isBackfill }
        #expect(olderAreBackfill)
        #expect(newestAreLive)
        #expect(await engine.pausedCalls == [true, false])
        #expect(await engine.offeredWhilePaused.isEmpty)
        #expect(fix.service.gaps.isEmpty)
    }

    @Test("No held chunk reaches the engine before it has resumed")
    func releaseWaitsForTheEngineToResume() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        let hold = fix.hold()
        try await waitUntil("the pause") { await engine.pausedCalls == [true] }
        await engine.setPauseDelay(.milliseconds(200))
        fix.tap.mic.pushTone(seconds: 2, from: 0)
        try await fix.waitForCapture(through: 2)

        hold.release()
        try await waitUntil("the held chunks") { await engine.offered.count == 8 }

        #expect(await engine.offeredWhilePaused.isEmpty, "the worker would drop them as paused audio")
        #expect(await engine.pausedCalls == [true, false])
    }

    @Test("A hold's pause waits for the chunk already on its way to the engine")
    func holdWaitsForAnOfferInFlight() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        await engine.setOfferDelay(.milliseconds(300))
        fix.tap.mic.pushTone(seconds: 1, from: 0)
        try await waitUntil("an offer in flight") { await engine.offerAttempts == 1 }

        let hold = fix.hold()
        try await waitUntil("the pause") { await engine.pausedCalls == [true] }
        try await waitUntil("the chunk on its way") { await engine.offered.count == 1 }
        #expect(await engine.offeredWhilePaused.isEmpty, "it reached the engine before the pause; the worker drops audio it gets while paused")

        hold.release()
        try await waitUntil("the held chunks") { await engine.offered.count == 4 }
        #expect(await engine.offeredWhilePaused.isEmpty)
    }

    @Test("A hold released while its pause is still being sent keeps its chunks back until the engine has resumed")
    func releaseDuringThePauseWaitsForTheResume() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        await engine.setPauseDelay(.seconds(1))
        let hold = fix.hold()
        fix.tap.mic.pushTone(seconds: 2, from: 0)
        try await fix.waitForCapture(through: 2)
        #expect(await engine.pendingPauseCalls == 1, "the pause has not returned yet")

        hold.release()
        try await waitUntil("the held chunks") { await engine.offered.count == 8 }

        #expect(await engine.offeredWhilePaused.isEmpty, "the worker would drop them as paused audio")
        #expect(await engine.pausedCalls == [true, false])
    }

    @Test("A hold longer than ten seconds shows Catching up, then Live once the engine reports progress")
    func statusCatchesUpAfterLongHold() async throws {
        let fix = LiveFixture()
        let engine = try await fix.startWithRow(firstSecond)
        #expect(fix.service.status == .live)
        let hold = fix.hold()
        fix.tap.mic.pushTone(seconds: 15, from: 0)

        try await waitUntil("catching up") { fix.service.status == .catchingUp }
        hold.release()
        try await waitUntil("the held chunks") { await engine.offered.count == 60 }
        #expect(fix.service.status == .catchingUp)

        await engine.emit(liveUpdate(.mic, revision: 2, rows: [firstSecond], transcribedThrough: 15, settledThrough: 15))
        try await waitUntil("live") { fix.service.status == .live }
    }

    @Test("Decoding resumes only when the second of two holds is released")
    func twoHoldsNeedTwoReleases() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        let first = fix.hold("first")
        let second = fix.hold("second")
        fix.tap.mic.pushTone(seconds: 1, from: 0)
        try await fix.waitForCapture(through: 1)

        first.release()
        try await settle()
        #expect(fix.service.isDecodingHeld)
        #expect(await engine.offered.isEmpty)

        second.release()
        try await waitUntil("the held chunks") { await engine.offered.count == 4 }
        #expect(!fix.service.isDecodingHeld)
        #expect(await engine.pausedCalls == [true, false])
    }

    @Test("Releasing a hold twice does not release another holder's hold")
    func doubleReleaseIsHarmless() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        let first = fix.hold("first")
        let second = fix.hold("second")
        fix.tap.mic.pushTone(seconds: 1, from: 0)
        try await fix.waitForCapture(through: 1)

        first.release()
        first.release()
        try await settle()
        #expect(fix.service.isDecodingHeld)
        #expect(await engine.offered.isEmpty)

        second.release()
        try await waitUntil("the held chunks") { await engine.offered.count == 4 }
    }

    @Test("A hold kept past its maximum is released by its timeout, and its late release does nothing")
    func maximumReleasesTheHold() async throws {
        let fix = LiveFixture()
        await fix.start()
        let engine = try await fix.engine(0)
        let forgotten = fix.hold("forgotten", maximum: .milliseconds(100))
        fix.tap.mic.pushTone(seconds: 1, from: 0)

        try await waitUntil("the timeout") { !fix.service.isDecodingHeld }
        try await waitUntil("the held chunks") { await engine.offered.count == 4 }

        let later = fix.hold("later")
        forgotten.release()
        #expect(fix.service.isDecodingHeld, "the late release left the new hold alone")
        later.release()
    }

    @Test("With a thermal pause and a hold, audio is handed to the paused engine as before; once the Mac cools, it waits for the release")
    func thermalPauseStillDropsAudio() async throws {
        let fix = LiveFixture()
        let engine = try await fix.startWithRow(firstSecond)
        let hold = fix.hold()
        try await waitUntil("the pause") { await engine.pausedCalls == [true] }

        fix.power.send(PowerState(thermalState: .serious))
        try await waitUntil("paused for heat") { fix.service.status == .paused(.lowPowerHeat) }
        fix.tap.mic.pushTone(seconds: 1, from: 0)
        // The worker drops audio it gets while paused, as one gap.
        try await waitUntil("the paused audio handed over") { await engine.offeredWhilePaused.count == 4 }
        #expect(await engine.pausedCalls == [true], "already paused for the hold")

        fix.power.send(PowerState(thermalState: .nominal))
        try await waitUntil("no longer paused for heat") { fix.service.status == .live }
        fix.tap.mic.pushTone(seconds: 1, from: 1)
        try await fix.waitForCapture(through: 2)
        try await settle()
        #expect(await engine.offered.count == 4, "the hold still applies")
        #expect(await engine.pausedCalls == [true])

        hold.release()
        try await waitUntil("the held chunks") { await engine.offered.count == 8 }
        #expect(await engine.pausedCalls == [true, false])
        #expect(await engine.offeredWhilePaused.count == 4)
    }

    @Test("A hold taken before a recording starts applies to its session from the first chunk")
    func holdCarriesIntoNewSession() async throws {
        let fix = LiveFixture()
        let hold = fix.hold()
        await fix.start()
        let engine = try await fix.engine(0)
        fix.tap.mic.pushTone(seconds: 1, from: 0)
        try await waitUntil("the pause") { await engine.pausedCalls == [true] }
        try await fix.waitForCapture(through: 1)
        try await settle()
        #expect(await engine.offered.isEmpty)

        hold.release()
        try await waitUntil("the held chunks") { await engine.offered.count == 4 }
        #expect(await engine.offered.first?.startTime == 0)
        #expect(await engine.offeredWhilePaused.isEmpty)
    }

    @Test("Stop while held ends the hold, and the finish hands the held audio to the engine with no gap")
    func finishFlushesHeldAudio() async throws {
        let settledAll = liveUpdate(.mic, revision: 2, rows: [firstSecond], transcribedThrough: 2, settledThrough: 2)
        let fix = LiveFixture(finish: .returns([settledAll]))
        let engine = try await fix.startWithRow(firstSecond)
        let hold = fix.hold()
        try await waitUntil("the pause") { await engine.pausedCalls == [true] }
        fix.tap.mic.pushTone(seconds: 2, from: 0)
        try await fix.waitForCapture(through: 2)
        #expect(await engine.offered.isEmpty)

        let finishing = fix.service.stop(fix.meetingID)
        #expect(!fix.service.isDecodingHeld)
        fix.tap.end(at: 2)
        #expect(await finishing.value == .finished)

        let chunks = await engine.offered
        #expect(chunks.count == 8)
        #expect(isContiguous(chunks))
        #expect(await engine.offeredWhilePaused.isEmpty)
        #expect(await engine.finishTimeouts.count == 1)
        #expect(fix.service.draft(for: fix.meetingID)?.gaps.isEmpty == true)
        hold.release()
        #expect(!fix.service.isDecodingHeld)
    }
}
