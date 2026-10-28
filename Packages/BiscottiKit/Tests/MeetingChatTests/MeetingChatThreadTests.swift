import BiscottiTestSupport
import DataStore
import Foundation
import LocalLLM
import Testing
@testable import MeetingChat

@Suite("MeetingChatService -- threads")
@MainActor
struct MeetingChatThreadTests {
    @Test("New chat closes the open thread and the card; the next question starts a thread")
    func newChatClearsOpenThread() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("Q1", in: meetingID)
        let state = chat.state(meetingID)

        chat.service.newChat(meetingID: meetingID)

        #expect(state.openThreadID == nil)
        #expect(state.messages.isEmpty)
        #expect(!state.isCardOpen)
        #expect(state.threads.count == 1)
        try await chat.askAndWait("Q2", in: meetingID)
        #expect(state.threads.count == 2)
        #expect(state.messages.map(\.text).first == "Q2")
    }

    @Test("Opening a thread shows its messages")
    func openThreadLoadsMessages() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["A1"]), ScriptedStream(["A2"])]
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("Q1", in: meetingID)
        let firstThreadID = try #require(chat.state(meetingID).openThreadID)
        chat.service.newChat(meetingID: meetingID)
        try await chat.askAndWait("Q2", in: meetingID)

        await chat.service.openThread(firstThreadID, meetingID: meetingID)

        let state = chat.state(meetingID)
        #expect(state.openThreadID == firstThreadID)
        #expect(state.messages.map(\.text) == ["Q1", "A1"])
        #expect(state.messages.map(\.state) == [.complete, .complete])
    }

    @Test("Deleting the open thread acts like New chat")
    func deleteOpenThreadActsLikeNewChat() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("Q1", in: meetingID)
        let threadID = try #require(chat.state(meetingID).openThreadID)

        await chat.service.deleteThread(threadID, meetingID: meetingID)

        let state = chat.state(meetingID)
        #expect(state.openThreadID == nil)
        #expect(state.messages.isEmpty)
        #expect(!state.isCardOpen)
        #expect(state.threads.isEmpty)
        #expect(try await chat.fix.store.chatThread(id: threadID) == nil)
    }

    @Test("Deleting the thread of the answer being written stops it and saves nothing")
    func deleteThreadWhileAnswering() async throws {
        let clock = TestClock()
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["Partial ", "answer"], tokenDelay: .seconds(1), clock: clock)]
        let (meetingID, _) = try await chat.meetingWithTranscript()
        await chat.ask("Q1", in: meetingID)
        let threadID = try #require(chat.state(meetingID).openThreadID)
        try await waitUntil("the wait for the first token") { clock.pendingSleepCount == 1 }

        await chat.service.deleteThread(threadID, meetingID: meetingID)
        try await chat.waitForAnswer(in: meetingID)

        #expect(try await chat.fix.store.chatThreads(meetingID: meetingID).isEmpty)
        #expect(try await chat.fix.store.read { try $0.fetchAllChatMessages().count } == 0)
    }

    @Test("A question written while History opens another thread is answered with its own thread's turns")
    func threadSwitchDuringQuestionWrite() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["A1"]), ScriptedStream(["B1"]), ScriptedStream(["A2"])]
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("Q1", in: meetingID)
        let first = try #require(chat.state(meetingID).openThreadID)
        chat.service.newChat(meetingID: meetingID)
        try await chat.askAndWait("Other question", in: meetingID)
        let second = try #require(chat.state(meetingID).openThreadID)
        await chat.service.openThread(first, meetingID: meetingID)

        chat.chatStore.holdsQuestionWrites = true
        chat.state(meetingID).draft = "Q2"
        let asking = Task { await chat.service.ask(meetingID: meetingID) }
        try await waitUntil("the held question write") { chat.chatStore.isHoldingQuestionWrite }
        await chat.service.openThread(second, meetingID: meetingID)
        chat.chatStore.releaseQuestionWrites()
        await asking.value
        try await chat.waitForAnswer(in: meetingID)

        #expect(chat.lastPrompt.dropFirst().map(\.summary) == ["user: Q1", "assistant: A1", "user: Q2"])
        #expect(chat.state(meetingID).messages.map(\.text) == ["Other question", "B1"], "the shown thread is untouched")
        await chat.service.openThread(first, meetingID: meetingID)
        #expect(chat.state(meetingID).messages.map(\.text) == ["Q1", "A1", "Q2", "A2"])
    }

    @Test("Deleting a meeting stops its answer, saves nothing and frees the other meetings")
    func deletingMeetingStopsItsAnswer() async throws {
        let clock = TestClock()
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["Partial ", "answer"], tokenDelay: .seconds(1), clock: clock)]
        let (meetingID, _) = try await chat.meetingWithTranscript()
        let (otherID, _) = try await chat.meetingWithTranscript()
        await chat.ask("Q1", in: meetingID)
        try await waitUntil("the wait for the first token") { clock.pendingSleepCount == 1 }
        #expect(chat.state(otherID).availability == .answeringElsewhere)

        chat.service.meetingWasDeleted(meetingID)
        try await chat.fix.store.delete(meetingID: meetingID)

        try await waitUntil("the slot to free") { chat.state(otherID).availability == .available }
        try await chat.askAndWait("Q2", in: otherID)
        #expect(try chat.lastAnswer(in: otherID).state == .complete)
        #expect(chat.opener.openCount == 1, "the stopped answer kept the model loaded")
    }

    @Test("Threads are listed newest first, by their last message")
    func threadsNewestFirst() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("First thread", in: meetingID)
        let first = try #require(chat.state(meetingID).openThreadID)
        chat.service.newChat(meetingID: meetingID)
        try await chat.askAndWait("Second thread", in: meetingID)
        let second = try #require(chat.state(meetingID).openThreadID)
        #expect(chat.state(meetingID).threads.map(\.id) == [second, first])

        await chat.service.openThread(first, meetingID: meetingID)
        try await chat.askAndWait("Follow-up", in: meetingID)

        #expect(chat.state(meetingID).threads.map(\.id) == [first, second])
    }

    @Test("A meeting reopens the thread it last showed")
    func lastOpenThreadRemembered() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["A1"])]
        let (meetingID, _) = try await chat.meetingWithTranscript()
        let (otherID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("Q1", in: meetingID)
        let threadID = try #require(chat.state(meetingID).openThreadID)

        await chat.service.load(meetingID: otherID)
        await chat.service.load(meetingID: meetingID)

        #expect(chat.state(meetingID).openThreadID == threadID)
        #expect(chat.state(meetingID).messages.map(\.text) == ["Q1", "A1"])
        #expect(chat.state(otherID).openThreadID == nil)
    }

    // MARK: - Stored answers

    @Test("A thread ending in a question loads with an interrupted answer, and Retry answers it")
    func interruptedAfterRelaunch() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["A1"])]
        let (meetingID, _) = try await chat.meetingWithTranscript()
        let (threadID, questionID) = try await chat.fix.store.createChatThread(meetingID: meetingID, firstQuestion: "Q1")

        await chat.service.openThread(threadID, meetingID: meetingID)

        let state = chat.state(meetingID)
        #expect(state.messages.map(\.role) == [.question, .answer])
        #expect(state.messages.last?.state == .interrupted)
        #expect(state.messages.last?.questionID == questionID)

        await chat.service.retry(questionID: questionID, meetingID: meetingID)
        try await chat.waitForAnswer(in: meetingID)
        #expect(state.messages.map(\.text) == ["Q1", "A1"])
        #expect(try await chat.storedThread(in: meetingID).messages.map(\.text) == ["Q1", "A1"])
    }

    @Test("A question with no answer inside a thread is interrupted and left out of the prompt")
    func interruptedQuestionInsideThread() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let store = chat.fix.store
        let (meetingID, transcriptID) = try await chat.meetingWithTranscript()
        let (threadID, _) = try await store.createChatThread(meetingID: meetingID, firstQuestion: "Q1")
        let secondID = try await store.appendChatQuestion(threadID: threadID, text: "Q2")
        try await store.saveChatAnswer(
            questionID: secondID, text: "A2", state: .complete, errorMessage: nil, basis: .transcript(id: transcriptID)
        )

        await chat.service.openThread(threadID, meetingID: meetingID)
        #expect(chat.state(meetingID).messages.map(\.state) == [.complete, .interrupted, .complete, .complete])

        try await chat.askAndWait("Q3", in: meetingID)
        #expect(chat.lastPrompt.dropFirst().map(\.summary) == ["user: Q2", "assistant: A2", "user: Q3"])
    }

    @Test("A reopened answer shows the same time links")
    func reopenedAnswerKeepsChips() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["Blue [0:21], not [9:00]."])]
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("What did we decide?", in: meetingID)
        let threadID = try #require(chat.state(meetingID).openThreadID)
        let written = try chat.lastAnswer(in: meetingID).blocks

        let relaunched = MeetingChatService(
            store: chat.fix.store, broker: chat.fix.llmBroker, modelURL: { ChatHarness.model },
            live: chat.live, recordingMeetingID: { nil }, isTranscribing: { _ in false }
        )
        await relaunched.openThread(threadID, meetingID: meetingID)

        let reopened = try #require(relaunched.state(for: meetingID).messages.last)
        #expect(reopened.blocks == written)
        #expect(ChatAnswerParser.citedTimes(in: reopened.blocks) == [20])
    }

    @Test("A stored answer without cited times shows its times as plain text")
    func storedAnswerWithoutCitedTimesIsPlain() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let (meetingID, transcriptID) = try await chat.meetingWithTranscript()
        let (threadID, questionID) = try await chat.fix.store.createChatThread(meetingID: meetingID, firstQuestion: "Q1")
        try await chat.fix.store.saveChatAnswer(
            questionID: questionID, text: "Blue [0:21].", state: .complete, errorMessage: nil, basis: .transcript(id: transcriptID)
        )

        await chat.service.openThread(threadID, meetingID: meetingID)

        let answer = try chat.lastAnswer(in: meetingID)
        #expect(ChatAnswerParser.citedTimes(in: answer.blocks).isEmpty)
        #expect(answer.blocks.map { String($0.text.characters) } == ["Blue 0:21."])
    }

    @Test("Stored states map to views, with the error and the basis line")
    func storedStatesMapToViews() {
        let questionID = UUID()
        let thread = ChatThreadData(
            summary: ChatThreadSummary(id: UUID(), meetingID: UUID(), title: "Q", createdAt: .now, updatedAt: .now),
            messages: [
                ChatMessageData(id: questionID, index: 0, role: .question, text: "Q", createdAt: .now),
                ChatMessageData(
                    id: UUID(), index: 1, role: .answer, text: "", createdAt: .now,
                    state: .failed, errorMessage: "The AI model couldn't start.", basis: .live(through: 754)
                )
            ]
        )

        let views = MeetingChatService.views(for: thread)

        #expect(views.map(\.state) == [.complete, .failed("The AI model couldn't start.")])
        #expect(views.last?.questionID == questionID)
        #expect(views.last?.footer == "Based on the transcript through 12:34")
    }
}
