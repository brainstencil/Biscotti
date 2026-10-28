import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
import LiveTranscriptModel
import Testing
@testable import MeetingChat

private let gib: UInt64 = 1 << 30

@Suite("MeetingChatService -- resource policy")
@MainActor
struct MeetingChatPolicyTests {
    @Test("Every Mac answers during a recording until the measurement sets a limit")
    func policyDefaultsToConcurrent() {
        for memory in [8 * gib, 16 * gib, 64 * gib] {
            #expect(ChatResourcePolicy(physicalMemory: memory).mode() == .concurrent)
        }
        #expect(ChatResourcePolicy(physicalMemory: 8 * gib, waitForStopMaximumMemory: 8 * gib).mode() == .waitForStop)
        #expect(ChatResourcePolicy(physicalMemory: 16 * gib, waitForStopMaximumMemory: 8 * gib).mode() == .concurrent)
    }

    @Test("During a recording, Macs under 24 GB close the model after each answer")
    func keepAliveByMemory() {
        let small = ChatResourcePolicy(physicalMemory: 16 * gib)
        let large = ChatResourcePolicy(physicalMemory: 32 * gib)

        #expect(small.keepAlive(isRecording: true) == .close)
        #expect(large.keepAlive(isRecording: true) == .keepOpen(.seconds(180)))
        #expect(small.keepAlive(isRecording: false) == .keepOpen(.seconds(180)))
        #expect(large.keepAlive(isRecording: false) == .keepOpen(.seconds(180)))
    }

    @Test(
        "An answer during a recording closes the model on a 16 GB Mac and keeps it on a 32 GB one",
        arguments: [(16 * gib, 1), (32 * gib, 0)]
    )
    func closeAfterAnswerWhileRecordingOnSmallMac(memory: UInt64, closes: Int) async throws {
        let chat = try ChatHarness(policy: ChatResourcePolicy(physicalMemory: memory))
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)

        try await chat.askAndWait("What is on the back?", in: meetingID)

        #expect(chat.opener.closeCount == closes)
        chat.fix.llmClock.advance(by: .seconds(180))
        try await waitUntil("the idle close") { chat.opener.closeCount == 1 }
    }

    @Test("Outside a recording, a 16 GB Mac keeps the model loaded after an answer")
    func keepsModelOutsideRecordingOnSmallMac() async throws {
        let chat = try ChatHarness(policy: ChatResourcePolicy(physicalMemory: 16 * gib))
        defer { chat.fix.cleanup() }
        let (meetingID, _) = try await chat.meetingWithTranscript()

        try await chat.askAndWait("What did we decide?", in: meetingID)

        #expect(chat.opener.closeCount == 0)
    }

    @Test("A recording that starts closes a kept model only on a Mac that frees it during recordings")
    func recordingStartClosesKeptModel() async throws {
        for (memory, closes) in [(16 * gib, 1), (32 * gib, 0)] {
            let chat = try ChatHarness(policy: ChatResourcePolicy(physicalMemory: memory))
            defer { chat.fix.cleanup() }
            let summary = SummaryLease(chat.fix.llmBroker)
            await summary.entered.wait()
            summary.release.open()
            try await waitUntil("the summary to end") { await chat.fix.llmBroker.runningPurpose == nil }

            await chat.service.recordingDidStart()

            #expect(chat.opener.closeCount == closes)
        }
    }

    @Test("The live transcript keeps receiving audio while an answer streams")
    func liveTranscriptNotPausedWhileAnswering() async throws {
        let clock = TestClock()
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["Partial ", "answer"], tokenDelay: .seconds(1), clock: clock)]
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)
        await chat.ask("What is on the back?", in: meetingID)
        try await advanceWhenWaiting(clock)
        try await waitUntil("streaming") { chat.status(in: meetingID) == .streaming }
        let before = await engine.offered.count

        chat.tap.mic.pushTone(seconds: 1, from: 1)
        try await waitUntil("audio offered to the live engine") { await engine.offered.count > before }

        #expect(chat.status(in: meetingID) == .streaming, "the answer is still being written")
        #expect(await engine.pausedCalls.isEmpty)
        try await advanceWhenWaiting(clock)
        try await chat.waitForAnswer(in: meetingID)
    }

    @Test("In wait mode a question waits for the recording to stop, then answers from the draft")
    func waitForStopParksQuestion() async throws {
        let chat = try ChatHarness(policy: ChatResourcePolicy(physicalMemory: 8 * gib, waitForStopMaximumMemory: 8 * gib))
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)

        await chat.ask("What is on the back?", in: meetingID)
        try await waitUntil("waiting for the recording") { chat.status(in: meetingID) == .waitingForRecordingToEnd }
        #expect(chat.state(meetingID).isAnswering)
        #expect(chat.opener.openCount == 0)

        await chat.stopRecording(meetingID)
        await chat.service.recordingDidStop(meetingID: meetingID)
        try await chat.waitForAnswer(in: meetingID)

        #expect(try await chat.storedThread(in: meetingID).messages.last?.basis == .draft)
        #expect(try chat.lastAnswer(in: meetingID).state == .complete)
    }

    @Test("Deleting the recorded meeting drops its waiting question")
    func deletingMeetingDropsWaitingQuestion() async throws {
        let chat = try ChatHarness(policy: ChatResourcePolicy(physicalMemory: 8 * gib, waitForStopMaximumMemory: 8 * gib))
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)
        await chat.ask("What is on the back?", in: meetingID)
        try await waitUntil("waiting for the recording") { chat.status(in: meetingID) == .waitingForRecordingToEnd }

        chat.service.meetingWasDeleted(meetingID)
        await chat.stopRecording(meetingID)
        await chat.service.recordingDidStop(meetingID: meetingID)

        #expect(chat.opener.openCount == 0, "nothing was answered")
        let otherID = try await chat.meeting()
        #expect(chat.state(otherID).availability != .answeringElsewhere)
    }

    @Test("Stop drops a waiting question back to an interrupted one, saving nothing")
    func stopDropsParkedQuestion() async throws {
        let chat = try ChatHarness(policy: ChatResourcePolicy(physicalMemory: 8 * gib, waitForStopMaximumMemory: 8 * gib))
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)
        await chat.ask("What is on the back?", in: meetingID)
        try await waitUntil("waiting for the recording") { chat.status(in: meetingID) == .waitingForRecordingToEnd }

        chat.service.stop()

        #expect(!chat.state(meetingID).isAnswering)
        #expect(try chat.lastAnswer(in: meetingID).state == .interrupted)
        #expect(try await chat.storedThread(in: meetingID).messages.map(\.role) == [.question])
        await chat.service.recordingDidStop(meetingID: meetingID)
        #expect(!chat.state(meetingID).isAnswering, "nothing waits any more")
    }
}
