import BiscottiTestSupport
import DataStore
import Foundation
import LocalLLM
import Testing
@testable import MeetingChat

@Suite("MeetingChatService -- failures and Retry")
@MainActor
struct MeetingChatFailureTests {
    @Test("A stream that ends without done fails and keeps its text")
    func endWithoutDoneFails() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["Partial"], ending: .withoutDone)]
        let (meetingID, _) = try await chat.meetingWithTranscript()

        try await chat.askAndWait("What did we decide?", in: meetingID)

        let stored = try #require(try await chat.storedThread(in: meetingID).messages.last)
        #expect(stored.state == .failed)
        #expect(stored.errorMessage == "The AI stopped before finishing.")
        #expect(stored.text == "Partial")
        #expect(try chat.lastAnswer(in: meetingID).state == .failed("The AI stopped before finishing."))
    }

    @Test("A model that fails to open fails the answer, with no basis")
    func openFailureFails() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.opener.openErrors = [ScriptedLLMFailure.openFailed]
        let (meetingID, _) = try await chat.meetingWithTranscript()

        try await chat.askAndWait("What did we decide?", in: meetingID)

        let stored = try #require(try await chat.storedThread(in: meetingID).messages.last)
        #expect(stored.state == .failed)
        #expect(stored.errorMessage == "The AI model couldn't start.")
        #expect(stored.basis == nil)
    }

    @Test("Stop during a model load that cannot be cancelled saves a stopped answer with no prompt and no basis")
    func stopDuringModelLoad() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let load = Latch()
        chat.opener.openGate = load
        let (meetingID, _) = try await chat.meetingWithTranscript()
        await chat.ask("What did we decide?", in: meetingID)
        try await waitUntil("loading") { chat.status(in: meetingID) == .loadingModel }

        chat.service.stop()
        load.open()
        try await chat.waitForAnswer(in: meetingID)

        let stored = try #require(try await chat.storedThread(in: meetingID).messages.last)
        #expect(stored.state == .stopped)
        #expect(stored.basis == nil)
        let session = try #require(chat.opener.sessions.first)
        #expect(session.countTokensCalls.isEmpty, "no prompt was built")
        #expect(chat.opener.closeCount == 0, "the loaded model stays for the next question")
    }

    @Test("A meeting too long for the context fails the answer")
    func tooLongFails() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.tokenCount = 1_000_000
        let (meetingID, _) = try await chat.meetingWithTranscript()

        try await chat.askAndWait("What did we decide?", in: meetingID)

        let stored = try #require(try await chat.storedThread(in: meetingID).messages.last)
        #expect(stored.errorMessage == "This meeting is too long to answer from.")
        #expect(stored.basis == nil)
        #expect(chat.opener.sessions.first?.streamingCalls.isEmpty == true)
    }

    @Test("A recording with no live text yet fails without loading the model")
    func noEvidenceFails() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        _ = try await chat.startRecording(meetingID)

        try await chat.askAndWait("What did we decide?", in: meetingID)

        #expect(try chat.lastAnswer(in: meetingID).state == .failed("There's no transcript to answer from yet."))
        #expect(chat.opener.openCount == 0)
    }

    @Test("An answer the store cannot save stays shown, marked unsaved")
    func saveFailureMarksUnsaved() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [ScriptedStream(["Blue."])]
        let (meetingID, _) = try await chat.meetingWithTranscript()
        chat.chatStore.failsSaves = true

        try await chat.askAndWait("What did we decide?", in: meetingID)

        let answer = try chat.lastAnswer(in: meetingID)
        #expect(answer.isUnsaved)
        #expect(answer.text == "Blue.")
        #expect(answer.state == .complete)
        #expect(try await chat.storedThread(in: meetingID).messages.map(\.role) == [.question])
    }

    @Test("Retry after a failure stores one complete answer for the question")
    func retryReplacesFailedAnswer() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        chat.script.streams = [
            ScriptedStream(["Half"], ending: .error(ScriptedLLMFailure.generationFailed)),
            ScriptedStream(["Whole answer."])
        ]
        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("What did we decide?", in: meetingID)
        #expect(try chat.lastAnswer(in: meetingID).state == .failed("Something went wrong while answering."))
        let questionID = try #require(chat.state(meetingID).messages.first?.id)

        await chat.service.retry(questionID: questionID, meetingID: meetingID)
        try await chat.waitForAnswer(in: meetingID)

        let thread = try await chat.storedThread(in: meetingID)
        #expect(thread.messages.map(\.text) == ["What did we decide?", "Whole answer."])
        #expect(thread.messages.last?.state == .complete)
        #expect(chat.state(meetingID).messages.map(\.id) == thread.messages.map(\.id))
        #expect(chat.opener.openCount == 2, "the failed stream's connection was dropped")
    }
}
