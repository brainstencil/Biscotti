import BiscottiTestSupport
import DataStore
import Foundation
import LiveTranscriptModel
import Testing
import Transcription
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

    @Test("A saved transcript makes chat available, also once it arrives after loading, with nothing to await")
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

        chat.service.transcriptWasSaved(meetingID: meetingID, hasText: true)

        #expect(chat.state(meetingID).availability == .available)
    }

    @Test("A saved transcript with no text, from a pass over silence, has nothing to ask about")
    func emptyTranscriptReadsAsNone() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        let empty = TranscriptResult(transcriptionMethodId: "v1", language: "en", speakerCount: 0, segments: [], processingDuration: 1)
        let transcriptID = try await chat.fix.store.addTranscript(empty, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID)
        try await chat.fix.store.setPreferredTranscript(transcriptID, for: meetingID)

        await chat.service.load(meetingID: meetingID)

        #expect(chat.state(meetingID).availability == .noTranscript)
    }

    @Test("A pass that saves an empty transcript turns chat off; a later save with text turns it on")
    func savedEmptyTranscriptThenText() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        await chat.service.load(meetingID: meetingID, hasTranscript: false)
        chat.service.finalPassWillStart(meetingID: meetingID)
        #expect(chat.state(meetingID).availability == .transcribing)

        // After Stop on a silent recording: the pass saves no text.
        chat.service.transcriptWasSaved(meetingID: meetingID, hasText: MeetingChatService.hasTranscriptText(["", " \n "]))
        chat.service.finalPassDidEnd(meetingID: meetingID)
        #expect(chat.state(meetingID).availability == .noTranscript)

        // A Retry or re-transcription that finds speech.
        chat.service.transcriptWasSaved(meetingID: meetingID, hasText: MeetingChatService.hasTranscriptText(["We picked the blue remote."]))
        #expect(chat.state(meetingID).availability == .available)

        // And one that comes back empty turns it off again: a save is the newest truth.
        chat.service.transcriptWasSaved(meetingID: meetingID, hasText: false)
        #expect(chat.state(meetingID).availability == .noTranscript)
    }

    @Test("A reading taken before a pass saved an empty transcript does not undo the save")
    func staleReadingKeepsAnEmptySave() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()

        // A re-transcription comes back empty while the page reads the old transcript.
        chat.service.transcriptWasSaved(meetingID: meetingID, hasText: false)
        await chat.service.load(meetingID: meetingID, hasTranscript: true)

        #expect(chat.state(meetingID).availability == .noTranscript)
    }

    @Test("Deleting a meeting forgets its save, so a later reading counts")
    func deletingAMeetingForgetsTheSave() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        chat.service.transcriptWasSaved(meetingID: meetingID, hasText: false)

        chat.service.meetingWasDeleted(meetingID)
        await chat.service.load(meetingID: meetingID, hasTranscript: true)

        #expect(chat.state(meetingID).availability == .available)
    }

    @Test("Only a transcript holding some text counts as one to ask about")
    func transcriptToAskNeedsText() {
        func transcript(_ texts: [String]) -> TranscriptData {
            TranscriptData(
                id: UUID(), createdAt: Date(), speakerCount: 1,
                segments: texts.enumerated().map { index, text in
                    SegmentData(id: UUID(), speakerID: 0, speakerLabel: "Speaker 0", startTime: Double(index), endTime: Double(index) + 1, text: text)
                },
                speakerAssignments: [:]
            )
        }
        #expect(!MeetingChatService.hasTranscriptToAsk(nil))
        #expect(!MeetingChatService.hasTranscriptToAsk(transcript([])))
        #expect(!MeetingChatService.hasTranscriptToAsk(transcript(["  ", "\n"])))
        #expect(MeetingChatService.hasTranscriptToAsk(transcript(["", "We picked the blue remote."])))
    }

    @Test("A page that read the meeting passes whether it has a transcript; a stale reading never undoes a saved one")
    func loadTakesTheTranscriptFlag() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()

        await chat.service.load(meetingID: meetingID, hasTranscript: true)
        #expect(chat.state(meetingID).availability == .available, "taken as given, not read from the store")

        let otherID = try await chat.meeting()
        await chat.service.load(meetingID: otherID, hasTranscript: false)
        #expect(chat.state(otherID).availability == .noTranscript)
        chat.service.transcriptWasSaved(meetingID: otherID, hasText: true)
        // A page that read the meeting just before the pass saved its transcript.
        await chat.service.load(meetingID: otherID, hasTranscript: false)
        #expect(chat.state(otherID).availability == .available)
    }

    @Test("From Stop until the final pass ends, a meeting with no draft reads as transcribing")
    func pendingFinalPassReadsTranscribing() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        await chat.service.load(meetingID: meetingID)
        #expect(chat.state(meetingID).availability == .noTranscript)

        chat.service.finalPassWillStart(meetingID: meetingID)
        #expect(chat.state(meetingID).availability == .transcribing, "no job is queued yet")

        chat.service.finalPassDidEnd(meetingID: meetingID)
        #expect(chat.state(meetingID).availability == .noTranscript, "the pass saved nothing")
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

    @Test("A stopped recording's draft with no text is not enough to ask: it reads as transcribing, then as no transcript")
    func draftWithoutTextIsNotEnough() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        await engine.emit(liveUpdate(.system, rows: [
            LiveRow(track: .system, startTime: 3, endTime: 8, settledText: " ", tailText: "\n")
        ], transcribedThrough: 10, settledThrough: 10))
        try await waitUntil("the live row") { chat.live.rows.count == 1 }
        await chat.stopRecording(meetingID)
        chat.service.finalPassWillStart(meetingID: meetingID)
        await chat.service.load(meetingID: meetingID, hasTranscript: false)

        #expect(chat.live.draft(for: meetingID) != nil, "the draft is held")
        #expect(chat.state(meetingID).availability == .transcribing)

        chat.service.finalPassDidEnd(meetingID: meetingID)
        #expect(chat.state(meetingID).availability == .noTranscript)
    }

    @Test("A save that records no text wins over a held draft with text")
    func savedNoTextWinsOverDraft() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)
        await chat.stopRecording(meetingID)
        chat.service.finalPassWillStart(meetingID: meetingID)
        await chat.service.load(meetingID: meetingID, hasTranscript: false)
        #expect(chat.state(meetingID).availability == .available, "the draft has text")

        // The pass over the recording saves no text; AppCore releases the draft only after the pass ends.
        chat.service.transcriptWasSaved(meetingID: meetingID, hasText: false)
        #expect(chat.state(meetingID).availability == .transcribing)
        chat.service.finalPassDidEnd(meetingID: meetingID)

        #expect(chat.live.draft(for: meetingID) != nil, "the draft is still held")
        #expect(chat.state(meetingID).availability == .noTranscript)
    }

    @Test("A draft has text to ask about exactly when its evidence has a line")
    func draftTextFollowsTheEvidence() {
        let drafts = [
            ChatFixtures.snapshot(rows: []),
            ChatFixtures.snapshot(rows: [LiveRow(track: .mic, startTime: 0, endTime: 2, settledText: "  ", tailText: "\n ")]),
            ChatFixtures.snapshot(rows: [LiveRow(track: .mic, startTime: 0, endTime: 2, settledText: "", tailText: "Blue.")]),
            ChatFixtures.snapshot(rows: [
                LiveRow(track: .mic, startTime: 0, endTime: 2, settledText: " "),
                LiveRow(track: .system, startTime: 3, endTime: 5, settledText: "We picked the blue remote.")
            ])
        ]

        #expect(drafts.map(ChatEvidence.hasText) == [false, false, true, true])
        for draft in drafts {
            #expect(ChatEvidence.hasText(draft) == !ChatEvidence.lines(for: .draft(draft)).isEmpty)
        }
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
