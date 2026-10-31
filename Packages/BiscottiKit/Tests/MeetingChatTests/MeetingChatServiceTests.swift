import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
import LocalLLM
import Testing
@testable import MeetingChat

@Suite("MeetingChatService -- asking")
@MainActor
struct MeetingChatServiceTests {
    @Test("The first question creates a thread and is stored before the model answers")
    func firstQuestionCreatesThread() async throws {
        let clock = TestClock()
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.opener.clock = clock
        chat.opener.openDelay = .seconds(1)
        let (meetingID, _) = try await chat.meetingWithTranscript()

        await chat.ask("  What did we decide?\n", in: meetingID)

        let state = chat.state(meetingID)
        let thread = try await chat.storedThread(in: meetingID)
        #expect(thread.messages.map(\.text) == ["What did we decide?"])
        #expect(thread.messages.map(\.role) == [.question])
        #expect(state.threads.map(\.id) == [thread.summary.id])
        #expect(state.draft.isEmpty)
        #expect(state.isCardOpen)
        #expect(state.isAnswering)
        #expect(state.messages.map(\.role) == [.question, .answer])
        #expect(state.messages.first?.id == thread.messages.first?.id)
        #expect(chat.opener.openCount == 0, "the model is still loading")

        try await advanceWhenWaiting(clock)
        try await chat.waitForAnswer(in: meetingID)
    }

    @Test("A streamed answer is saved once, complete, with the transcript as its basis")
    func streamedAnswerIsSavedComplete() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["They picked ", "the blue remote ", "[0:21]."])]
        let (meetingID, transcriptID) = try await chat.meetingWithTranscript()

        try await chat.askAndWait("What did we decide?", in: meetingID)

        let thread = try await chat.storedThread(in: meetingID)
        let stored = try #require(thread.messages.last)
        #expect(thread.messages.count == 2)
        #expect(stored.role == .answer)
        #expect(stored.text == "They picked the blue remote [0:21].")
        #expect(stored.state == .complete)
        #expect(stored.basis == .transcript(id: transcriptID))
        #expect(stored.citedTimes == [20])

        let answer = try chat.lastAnswer(in: meetingID)
        #expect(answer.id == stored.id)
        #expect(answer.state == .complete)
        #expect(answer.footer == nil)
        #expect(ChatAnswerParser.citedTimes(in: answer.blocks) == [20])
        #expect(chat.opener.openCount == 1)
        #expect(chat.opener.closeCount == 0, "the model stays loaded for the next question")
        let session = try #require(chat.opener.sessions.first)
        #expect(session.reconfigureCalls == [ChatPromptBuilder.contextSize(promptTokens: 100)])
    }

    @Test("During a recording the prompt holds the live snapshot and the basis is how far it reached")
    func liveAnswerUsesSnapshot() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)

        try await chat.askAndWait("What is on the back?", in: meetingID)

        let system = try #require(chat.lastPrompt.first?.content)
        #expect(system.contains("[0:03] Others: Let's design the remote."))
        #expect(system.contains("[0:21] Others: A magnet on the back {of it}"))
        #expect(try await chat.storedThread(in: meetingID).messages.last?.basis == .live(through: 46))
        #expect(try chat.lastAnswer(in: meetingID).footer == "Based on the transcript through 0:46")
    }

    @Test("After Stop and before the final pass, the answer uses the draft")
    func draftAnswerUsesDraft() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)
        await chat.stopRecording(meetingID)

        try await chat.askAndWait("What is on the back?", in: meetingID)

        let system = try #require(chat.lastPrompt.first?.content)
        #expect(system.contains("draft, made during the recording"))
        #expect(try await chat.storedThread(in: meetingID).messages.last?.basis == .draft)
        #expect(try chat.lastAnswer(in: meetingID).footer == "Based on the draft transcript")
    }

    @Test("200 tokens in 100 ms update the answer at most 3 times, and the text is complete")
    func flushThrottlesUpdates() async throws {
        let clock = FastForwardClock()
        let chat = try ChatHarness(clock: clock)
        defer { chat.fix.cleanup() }
        let tokens = (0 ..< 200).map { "w\($0) " }
        chat.script.streams = [ScriptedStream(tokens, tokenDelay: .microseconds(500), clock: clock)]
        let (meetingID, _) = try await chat.meetingWithTranscript()

        try await chat.askAndWait("Say it all.", in: meetingID)

        #expect((1 ... 3).contains(chat.service.answerFlushCount))
        #expect(try chat.lastAnswer(in: meetingID).text == tokens.joined())
    }

    @Test("A slow load shows Loading, then Thinking, then the streaming text")
    func statusShowsLoadingThenThinking() async throws {
        let clock = TestClock()
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.opener.clock = clock
        chat.opener.openDelay = .seconds(1)
        chat.script.streams = [ScriptedStream(["First", " second"], tokenDelay: .seconds(1), clock: clock)]
        let (meetingID, _) = try await chat.meetingWithTranscript()

        await chat.ask("What did we decide?", in: meetingID)
        try await waitUntil("loading") { chat.status(in: meetingID) == .loadingModel }

        try await advanceWhenWaiting(clock)
        try await waitUntil("thinking until the first token") {
            chat.status(in: meetingID) == .thinking && clock.pendingSleepCount == 1
        }

        try await advanceWhenWaiting(clock)
        try await waitUntil("streaming") { chat.status(in: meetingID) == .streaming }
        #expect(try chat.lastAnswer(in: meetingID).text == "First")

        try await advanceWhenWaiting(clock)
        try await chat.waitForAnswer(in: meetingID)
        #expect(try chat.lastAnswer(in: meetingID).state == .complete)
    }

    @Test("A question waits behind a running summary and says so")
    func waitsBehindSummary() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let (meetingID, _) = try await chat.meetingWithTranscript()
        let summary = SummaryLease(chat.fix.llmBroker)
        await summary.entered.wait()

        await chat.ask("What did we decide?", in: meetingID)
        try await waitUntil("waiting for the summary") { chat.status(in: meetingID) == .waitingForSummary }

        summary.release.open()
        try await chat.waitForAnswer(in: meetingID)
        #expect(try chat.lastAnswer(in: meetingID).state == .complete)
        #expect(chat.opener.openCount == 1, "chat reuses the summary's model")
    }

    @Test("Stop mid-stream saves the text so far as stopped, and the model stays loaded")
    func stopSavesStopped() async throws {
        let clock = TestClock()
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["Partial ", "answer"], tokenDelay: .seconds(1), clock: clock)]
        let (meetingID, transcriptID) = try await chat.meetingWithTranscript()
        await chat.ask("What did we decide?", in: meetingID)
        try await advanceWhenWaiting(clock)
        try await waitUntil("the first token, then the wait for the next") {
            (try? chat.lastAnswer(in: meetingID).text) == "Partial " && clock.pendingSleepCount == 1
        }

        chat.service.stop()
        try await chat.waitForAnswer(in: meetingID)

        let stored = try #require(try await chat.storedThread(in: meetingID).messages.last)
        #expect(stored.text == "Partial ")
        #expect(stored.state == .stopped)
        #expect(stored.basis == .transcript(id: transcriptID))
        #expect(try chat.lastAnswer(in: meetingID).state == .stopped)

        try await chat.askAndWait("And then?", in: meetingID)
        #expect(try chat.lastAnswer(in: meetingID).state == .complete)
        #expect(chat.opener.openCount == 1, "Stop kept the connection, so the model did not reload")
        #expect(chat.opener.closeCount == 0)
    }

    @Test("Stop while waiting for the model saves a stopped answer with no basis")
    func stopWhileQueuedSavesStoppedWithoutBasis() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let (meetingID, _) = try await chat.meetingWithTranscript()
        let summary = SummaryLease(chat.fix.llmBroker)
        await summary.entered.wait()
        await chat.ask("What did we decide?", in: meetingID)
        try await waitUntil("waiting for the summary") { chat.status(in: meetingID) == .waitingForSummary }

        chat.service.stop()
        try await chat.waitForAnswer(in: meetingID)

        let stored = try #require(try await chat.storedThread(in: meetingID).messages.last)
        #expect(stored.role == .answer)
        #expect(stored.state == .stopped)
        #expect(stored.basis == nil)
        #expect(try chat.lastAnswer(in: meetingID).footer == nil)
        summary.release.open()
    }

    @Test("The second question's prompt holds the first turn; failed turns are left out")
    func earlierTurnsInPrompt() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [
            ScriptedStream(["A1"]),
            ScriptedStream(["Half of A2"], ending: .error(ScriptedLLMFailure.generationFailed)),
            ScriptedStream(["A3"])
        ]
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("Q1", in: meetingID)
        try await chat.askAndWait("Q2", in: meetingID)
        #expect(chat.lastPrompt.dropFirst().map(\.summary) == ["user: Q1", "assistant: A1", "user: Q2"])

        try await chat.askAndWait("Q3", in: meetingID)

        #expect(chat.lastPrompt.dropFirst().map(\.summary) == ["user: Q1", "assistant: A1", "user: Q3"])
    }

    @Test("A stopped answer counts as an earlier turn")
    func stoppedAnswerIsAnEarlierTurn() {
        let questionID = UUID()
        let messages = [
            ChatMessageView(id: questionID, questionID: questionID, role: .question, text: "Q1"),
            ChatMessageView(id: UUID(), questionID: questionID, role: .answer, text: "Part", state: .stopped)
        ]

        #expect(MeetingChatService.earlierTurns(in: messages) == [ChatTurn(question: "Q1", answer: "Part")])
    }
}

/// A background lease named like the summary's, held until `release` opens.
@MainActor
struct SummaryLease {
    let entered = Latch()
    let release = Latch()

    init(_ broker: LLMBroker) {
        let entered = entered
        let release = release
        Task {
            try await broker.withLease(
                model: ChatHarness.model, priority: .background, purpose: BrokeredLLMRunner.defaultPurpose
            ) { _ in
                entered.open()
                await release.wait()
            }
        }
    }
}
