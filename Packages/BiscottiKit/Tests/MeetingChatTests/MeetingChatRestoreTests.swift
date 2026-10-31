import BiscottiTestSupport
import DataStore
import Foundation
import LocalLLM
import Testing
@testable import MeetingChat

@Suite("MeetingChatService -- restore after relaunch")
@MainActor
struct MeetingChatRestoreTests {
    /// A harness whose service keeps its chat in a defaults suite of its own.
    private func harness() throws -> (chat: ChatHarness, cleanup: () -> Void) {
        let suite = "meeting-chat-restore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let chat = try ChatHarness(defaults: defaults)
        return (chat, {
            defaults.removePersistentDomain(forName: suite)
            chat.fix.cleanup()
        })
    }

    @Test("after a relaunch the chat reopens on the thread that was open, with the half-typed question")
    func relaunchRestoresThreadAndDraft() async throws {
        let (chat, cleanup) = try harness()
        defer { cleanup() }
        chat.script.streams = [ScriptedStream(["A1"])]
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("Q1", in: meetingID)
        let threadID = try #require(chat.state(meetingID).openThreadID)
        chat.state(meetingID).draft = "And the batt"

        let service = chat.relaunched()
        let state = service.state(for: meetingID)
        #expect(state.openThreadID == threadID, "the field reads Continue chat at once")
        #expect(state.draft == "And the batt")
        #expect(!state.isCardOpen, "the card stays closed, as after a change of meeting")

        await service.load(meetingID: meetingID)
        #expect(state.openThreadID == threadID)
        #expect(state.messages.map(\.text) == ["Q1", "A1"])
        #expect(state.threads.map(\.id) == [threadID])
    }

    @Test("a sent question clears the kept draft; one that could not be sent stays kept")
    func sendingClearsKeptDraft() async throws {
        let (chat, cleanup) = try harness()
        defer { cleanup() }
        let (meetingID, _) = try await chat.meetingWithTranscript()

        chat.state(meetingID).draft = "Q1"
        #expect(chat.relaunched().state(for: meetingID).draft == "Q1")
        await chat.service.ask(meetingID: meetingID)
        #expect(chat.relaunched().state(for: meetingID).draft.isEmpty)
        try await chat.waitForAnswer(in: meetingID)

        chat.world.hasModel = false
        await chat.ask("Q2", in: meetingID)
        #expect(chat.relaunched().state(for: meetingID).draft == "Q2")
    }

    @Test("each meeting keeps its own thread and draft")
    func meetingsKeepTheirOwn() async throws {
        let (chat, cleanup) = try harness()
        defer { cleanup() }
        let (first, _) = try await chat.meetingWithTranscript()
        let (second, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("About the first", in: first)
        let firstThread = try #require(chat.state(first).openThreadID)
        chat.state(first).draft = "first draft"
        chat.state(second).draft = "second draft"

        let service = chat.relaunched()
        #expect(service.state(for: first).openThreadID == firstThread)
        #expect(service.state(for: first).draft == "first draft")
        #expect(service.state(for: second).openThreadID == nil)
        #expect(service.state(for: second).draft == "second draft")
    }

    @Test("New chat, a deleted thread and a deleted meeting are not restored")
    func closedThreadsAreNotRestored() async throws {
        let (chat, cleanup) = try harness()
        defer { cleanup() }
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("Q1", in: meetingID)
        chat.service.newChat(meetingID: meetingID)
        #expect(chat.relaunched().state(for: meetingID).openThreadID == nil, "New chat")

        try await chat.askAndWait("Q2", in: meetingID)
        let threadID = try #require(chat.state(meetingID).openThreadID)
        await chat.service.deleteThread(threadID, meetingID: meetingID)
        #expect(chat.relaunched().state(for: meetingID).openThreadID == nil, "Delete This Chat…")

        try await chat.askAndWait("Q3", in: meetingID)
        chat.state(meetingID).draft = "unsent"
        chat.service.meetingWasDeleted(meetingID)
        let afterDeletion = chat.relaunched().state(for: meetingID)
        #expect(afterDeletion.openThreadID == nil)
        #expect(afterDeletion.draft.isEmpty)
    }

    @Test("a kept thread that is gone from the store is forgotten when the meeting loads")
    func missingKeptThreadIsForgotten() async throws {
        let (chat, cleanup) = try harness()
        defer { cleanup() }
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("Q1", in: meetingID)
        let threadID = try #require(chat.state(meetingID).openThreadID)
        // Gone behind the service's back, as by another build on the same store.
        try await chat.fix.store.deleteChatThread(id: threadID)

        let service = chat.relaunched()
        await service.load(meetingID: meetingID)
        #expect(service.state(for: meetingID).openThreadID == nil)
        #expect(chat.relaunched().state(for: meetingID).openThreadID == nil)
    }

    @Test("without defaults nothing is kept across launches")
    func noDefaultsKeepsNothing() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("Q1", in: meetingID)
        chat.state(meetingID).draft = "unsent"

        let state = chat.relaunched().state(for: meetingID)
        #expect(state.openThreadID == nil)
        #expect(state.draft.isEmpty)
    }
}
