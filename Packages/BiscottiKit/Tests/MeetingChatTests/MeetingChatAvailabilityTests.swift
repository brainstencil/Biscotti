import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import MeetingChat

@Suite("MeetingChatService -- availability")
@MainActor
struct MeetingChatAvailabilityTests {
    @Test("Without a downloaded model, no meeting can ask")
    func noModelWhenNoneDownloaded() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.world.hasModel = false
        let (meetingID, _) = try await chat.meetingWithTranscript()

        #expect(chat.state(meetingID).availability == .noModel)
    }

    @Test("While recording with the live transcript off, the field offers to turn it on")
    func liveOffWhileRecording() async throws {
        let chat = try ChatHarness(liveEnabled: false)
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        chat.world.recordingID = meetingID

        #expect(chat.state(meetingID).availability == .liveTranscriptOff)

        await chat.service.turnOnLiveTranscript()
        #expect(chat.live.isEnabled)
        #expect(chat.state(meetingID).availability == .available)
    }

    @Test("The Turn On action goes through AppCore's handler when it has one")
    func turnOnUsesHandler() async throws {
        let chat = try ChatHarness(liveEnabled: false)
        defer { chat.fix.cleanup() }
        let calls = Counter()
        chat.service.onTurnOnLiveTranscript = { calls.count += 1 }

        await chat.service.turnOnLiveTranscript()

        #expect(calls.count == 1)
        #expect(!chat.live.isEnabled)
    }

    @Test("A meeting still transcribing, with no draft, asks to wait")
    func transcribingWithoutDraft() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        chat.world.transcribing = [meetingID]
        await chat.service.load(meetingID: meetingID)

        #expect(chat.state(meetingID).availability == .transcribing)
    }

    @Test("A meeting whose final pass failed, with no draft, has nothing to ask about")
    func noTranscriptAfterFailedPass() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        await chat.service.load(meetingID: meetingID)

        #expect(chat.state(meetingID).availability == .noTranscript)
    }

    @Test("A saved transcript makes chat available, also once it arrives after loading")
    func availableWithSavedTranscript() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let (savedID, _) = try await chat.meetingWithTranscript()
        #expect(chat.state(savedID).availability == .available)

        let meetingID = try await chat.meeting()
        await chat.service.load(meetingID: meetingID)
        #expect(chat.state(meetingID).availability == .noTranscript)
        let result = FakeTranscriber.defaultResult
        let transcriptID = try await chat.fix.store.addTranscript(result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID)
        try await chat.fix.store.setPreferredTranscript(transcriptID, for: meetingID)

        await chat.service.refreshAvailability()

        #expect(chat.state(meetingID).availability == .available)
    }

    @Test("A stopped recording's draft is enough to ask")
    func availableWithDraftOnly() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)
        await chat.stopRecording(meetingID)
        chat.world.transcribing = [meetingID]
        await chat.service.load(meetingID: meetingID)

        #expect(chat.state(meetingID).availability == .available)
    }

    @Test("While one meeting answers, the others cannot send")
    func answeringElsewhereBlocksOthers() async throws {
        let clock = TestClock()
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["Blue."], tokenDelay: .seconds(1), clock: clock)]
        let (first, _) = try await chat.meetingWithTranscript()
        let (second, _) = try await chat.meetingWithTranscript()

        await chat.ask("What did we decide?", in: first)
        #expect(chat.state(first).availability == .available)
        #expect(chat.state(first).isAnswering)
        #expect(chat.state(second).availability == .answeringElsewhere)
        await chat.ask("Anything else?", in: second)
        #expect(chat.state(second).messages.isEmpty, "the second question was not sent")
        #expect(chat.state(second).draft == "Anything else?")

        try await advanceWhenWaiting(clock)
        try await chat.waitForAnswer(in: first)
        #expect(chat.state(second).availability == .available)
    }
}

@MainActor
private final class Counter {
    var count = 0
}
