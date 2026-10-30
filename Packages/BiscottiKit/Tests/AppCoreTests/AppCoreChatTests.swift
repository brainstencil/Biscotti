import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
import LiveTranscriptionService
import LiveTranscriptModel
import MeetingChat
import Testing
import TranscriptionService
@testable import AppCore

private let gib: UInt64 = 1 << 30

@Suite("AppCore -- meeting chat")
@MainActor
struct AppCoreChatTests {
    @Test(
        "Starting a recording closes a model kept loaded by a summary, on Macs that free it during recordings",
        arguments: [(16 * gib, 1), (32 * gib, 0)]
    )
    func recordingStartClosesKeptModel(memory: UInt64, closes: Int) async throws {
        let fix = try makeCoreFixture(chatPolicy: ChatResourcePolicy(physicalMemory: memory), testName: "AppCoreChatTests")
        defer { fix.cleanup() }
        try await fix.llmBroker.withLease(
            model: URL(fileURLWithPath: "/models/a.gguf"), priority: .background, purpose: BrokeredLLMRunner.defaultPurpose
        ) { _ in }
        #expect(fix.llmOpener.closeCount == 0, "a summary keeps the model loaded for 180 s")

        await fix.core.startRecording()

        #expect(fix.core.recording.state.isRecording)
        #expect(fix.llmOpener.closeCount == closes)
        _ = await fix.core.stopRecording()
        await fix.core.awaitPendingTranscription()
    }

    @Test("Stop answers a question that waited for the recording, from the draft")
    func stopAnswersWaitingQuestionFromDraft() async throws {
        let engines = FakeLiveEngineFactory()
        let live = makeFakeLiveService(
            engines: engines,
            timing: LiveTiming(publishInterval: .zero, stopDeadline: .milliseconds(200), pumpInterval: .milliseconds(5), finishMargin: .milliseconds(50))
        )
        let waits = ChatResourcePolicy(physicalMemory: 8 * gib, waitForStopMaximumMemory: 8 * gib)
        let fix = try makeCoreFixture(modelDownloaded: true, liveTranscription: live, chatPolicy: waits, testName: "AppCoreChatTests")
        defer { fix.cleanup() }
        await fix.core.startRecording()
        let meetingID = try #require(fix.core.recording.state.meetingID)
        try await waitUntil("a live engine") { engines.engines.count == 1 }
        let engine = engines.engines[0]
        try await waitUntil("its config") { await engine.config != nil }
        await engine.emit(liveUpdate(.system, rows: [
            LiveRow(track: .system, startTime: 3, endTime: 8, settledText: "Let's design the remote.")
        ], transcribedThrough: 10, settledThrough: 10))
        try await waitUntil("the live row") { !live.rows.isEmpty }

        let state = fix.chat.state(for: meetingID)
        state.draft = "What did we design?"
        await fix.chat.ask(meetingID: meetingID)
        try await waitUntil("the question to wait") { state.messages.last?.state == .streaming(.waitingForRecordingToEnd) }

        _ = await fix.core.stopRecording()
        #expect(state.isCardOpen, "a question waiting for Stop keeps the card open")
        try await waitUntil("the answer") { !state.isAnswering }

        let threadID = try #require(state.openThreadID)
        let thread = try #require(try await fix.store.chatThread(id: threadID))
        #expect(thread.messages.last?.state == .complete)
        #expect(thread.messages.last?.basis == .draft)
        await fix.core.awaitPendingTranscription()
    }

    @Test("Stop closes the chat card and keeps its thread, unless an answer is being written", arguments: [false, true])
    func stopClosesCardUnlessAnswering(answering: Bool) async throws {
        let clock = TestClock()
        let engines = FakeLiveEngineFactory()
        let live = makeFakeLiveService(
            engines: engines,
            timing: LiveTiming(publishInterval: .zero, stopDeadline: .milliseconds(200), pumpInterval: .milliseconds(5), finishMargin: .milliseconds(50))
        )
        let fix = try makeCoreFixture(modelDownloaded: true, liveTranscription: live, testName: "AppCoreChatTests")
        defer { fix.cleanup() }
        fix.llmOpener.script.streams = [ScriptedStream(["Blue."], tokenDelay: answering ? .seconds(1) : nil, clock: clock)]
        await fix.core.startRecording()
        let meetingID = try #require(fix.core.recording.state.meetingID)
        try await waitUntil("a live engine") { engines.engines.count == 1 }
        let engine = engines.engines[0]
        try await waitUntil("its config") { await engine.config != nil }
        await engine.emit(liveUpdate(.system, rows: [
            LiveRow(track: .system, startTime: 3, endTime: 8, settledText: "Let's design the remote.")
        ], transcribedThrough: 10, settledThrough: 10))
        try await waitUntil("the live row") { !live.rows.isEmpty }

        let state = fix.chat.state(for: meetingID)
        state.draft = "What did we design?"
        await fix.chat.ask(meetingID: meetingID)
        if answering {
            try await waitUntil("the wait for the first token") { clock.pendingSleepCount == 1 }
        } else {
            try await waitUntil("the answer") { !state.isAnswering }
        }
        #expect(state.isCardOpen)

        _ = await fix.core.stopRecording()

        #expect(fix.core.meetingsSelection == [meetingID])
        #expect(state.isCardOpen == answering)
        #expect(state.openThreadID != nil, "the field reads \"Continue chat\"")
        if answering {
            clock.advance(by: .seconds(1))
            try await waitUntil("the answer") { !state.isAnswering }
        }
        await fix.core.awaitPendingTranscription()
    }

    @Test("A transcript saved by any final pass, not only the one after Stop, makes chat available as the job completes")
    func savedTranscriptRefreshesChat() async throws {
        let fix = try makeCoreFixture(modelDownloaded: true, testName: "AppCoreChatTests")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        await fix.chat.load(meetingID: meetingID)
        #expect(fix.chat.state(for: meetingID).availability == .noTranscript)
        // What chat reads in the turn that completes the job, after AppCore's hook.
        let seen = AvailabilitySeen()
        let hook = fix.core.transcription.onTranscriptSaved
        fix.core.transcription.onTranscriptSaved = { id, texts in
            hook?(id, texts)
            seen.job = fix.core.transcription.jobs[id]
            seen.availability = fix.chat.state(for: id).availability
        }

        // As the meeting page's transcription Retry does.
        await fix.core.transcription.transcribe(meetingID: meetingID)

        #expect(seen.job == .completed)
        #expect(seen.availability == .available, "no \"no transcript\" in between")
    }

    @Test("Right after Stop with the live transcript off, chat reads as transcribing, not as transcript-less")
    func stopWithLiveOffReadsTranscribing() async throws {
        let live = makeFakeLiveService(isEnabled: false)
        let fix = try makeCoreFixture(modelDownloaded: true, liveTranscription: live, testName: "AppCoreChatTests")
        defer { fix.cleanup() }
        await fix.core.startRecording()
        let meetingID = try #require(fix.core.recording.recordingMeetingID)

        _ = await fix.core.stopRecording()

        #expect(fix.core.transcription.jobs[meetingID] == nil, "the pass is not queued yet")
        #expect(fix.chat.state(for: meetingID).availability == .transcribing)
        await fix.core.awaitPendingTranscription()
        #expect(fix.chat.state(for: meetingID).availability != .transcribing)
    }

    @Test("Deleting a meeting stops its answer and frees chat for the other meetings")
    func deletingMeetingStopsItsAnswer() async throws {
        let clock = TestClock()
        let fix = try makeCoreFixture(modelDownloaded: true, testName: "AppCoreChatTests")
        defer { fix.cleanup() }
        fix.llmOpener.script.streams = [ScriptedStream(["Partial ", "answer"], tokenDelay: .seconds(1), clock: clock)]
        let meetingID = try await fix.createMeetingWithAudio()
        let otherID = try await fix.createMeetingWithAudio()
        for id in [meetingID, otherID] {
            await fix.core.transcription.transcribe(meetingID: id)
            await fix.chat.load(meetingID: id)
        }
        fix.chat.state(for: meetingID).draft = "What did we decide?"
        await fix.chat.ask(meetingID: meetingID)
        try await waitUntil("the wait for the first token") { clock.pendingSleepCount == 1 }
        #expect(fix.chat.state(for: otherID).availability == .answeringElsewhere)

        await fix.core.deleteMeeting(meetingID: meetingID)

        try await waitUntil("the slot to free") { fix.chat.state(for: otherID).availability == .available }
        #expect(try await fix.store.read { try $0.fetchAllChatThreads().count } == 0)
    }

    @Test("Chat's Turn On saves the live transcript setting and starts live transcription")
    func turnOnLiveTranscriptSavesSetting() async throws {
        let live = makeFakeLiveService(isEnabled: false)
        let fix = try makeCoreFixture(liveTranscription: live, testName: "AppCoreChatTests")
        defer { fix.cleanup() }

        await fix.chat.turnOnLiveTranscript()

        #expect(live.isEnabled)
        #expect(try await fix.store.settings().liveTranscriptEnabled == true)
    }
}

/// What chat read when a pass saved a transcript.
@MainActor
private final class AvailabilitySeen {
    var job: JobStatus?
    var availability: ChatAvailability?
}
