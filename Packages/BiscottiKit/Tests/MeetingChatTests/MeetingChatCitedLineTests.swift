import BiscottiTestSupport
import DataStore
import Foundation
import Testing
@testable import MeetingChat

@Suite("MeetingChatService -- a chip's cited line")
@MainActor
struct MeetingChatCitedLineTests {
    @Test("a chip's time gives the saved transcript's line that starts there, or the one it falls in")
    func savedTranscriptLine() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let (meetingID, _) = try await chat.meetingWithTranscript()

        let line = await chat.service.citedLine(at: 20, meetingID: meetingID)
        #expect(line == ChatEvidenceLine(start: 20, speaker: "Speaker 1", text: "Battery life matters most."))
        #expect(await chat.service.citedLine(at: 22, meetingID: meetingID)?.start == 20, "a time inside the line")
        #expect(await chat.service.citedLine(at: 0, meetingID: meetingID)?.text == "We picked the blue remote.")
    }

    @Test("during the meeting's recording the line comes from the live transcript, with its tail")
    func liveTranscriptLine() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)

        let line = await chat.service.citedLine(at: 21, meetingID: meetingID)
        #expect(line == ChatEvidenceLine(start: 21, speaker: "Others", text: "A magnet on the back", unsettled: "of it"))
    }

    @Test("a meeting with no transcript, or a time before its first line, has no line")
    func noLine() async throws {
        let chat = try ChatHarness()
        defer { chat.fix.cleanup() }
        let meetingID = try await chat.meeting()
        #expect(await chat.service.citedLine(at: 20, meetingID: meetingID) == nil)

        let lines = [ChatEvidenceLine(start: 10, speaker: "Alex", text: "Hi"), ChatEvidenceLine(start: 30, speaker: "Sam", text: "Bye")]
        #expect(MeetingChatService.line(at: 5, in: lines) == nil)
        #expect(MeetingChatService.line(at: 30, in: lines)?.speaker == "Sam")
        #expect(MeetingChatService.line(at: 29.9, in: lines)?.speaker == "Alex")
        #expect(MeetingChatService.line(at: 90, in: lines)?.speaker == "Sam")
    }
}
