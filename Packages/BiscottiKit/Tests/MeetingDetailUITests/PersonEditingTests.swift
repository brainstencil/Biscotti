import BiscottiTestSupport
import DataStore
import Foundation
import PeopleUI
import Testing
import Transcription
@testable import AppCore
@testable import MeetingDetailUI

private func oneSpeakerResult() -> TranscriptResult {
    TranscriptResult(
        transcriptionMethodId: "test-v1", language: "en", speakerCount: 1,
        segments: [TranscriptSegment(
            speakerID: 0, speakerLabel: "Speaker 0", startTime: 0, endTime: 5,
            text: "Hello", confidence: 0.9, noSpeechProbability: 0.01, words: nil
        )],
        processingDuration: 1
    )
}

@Suite("Meeting detail -- person editing from the speaker sheet")
@MainActor
struct PersonEditingTests {
    private struct Setup {
        let viewModel: MeetingDetailViewModel
        let meetingID: UUID
        let steven: UUID
    }

    /// A meeting whose speaker 0 is assigned to "Steven", with the view
    /// model loaded and the speaker sheet open.
    private func setUp(
        _ fix: CoreFixture, summary: String = ""
    ) async throws -> Setup {
        let meetingID = try await fix.createMeetingWithAudio(title: "Steven sync")
        let transcriptID = try await fix.store.addTranscript(
            oneSpeakerResult(), vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
        )
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)
        let steven = try await fix.store.findOrCreatePerson(name: "Steven", email: nil)
        try await fix.store.setSpeakerAssignment(speakerID: 0, personID: steven, for: transcriptID)
        if !summary.isEmpty {
            try await fix.store.applyGeneratedSummary(summary, for: meetingID)
        }
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        await viewModel.load()
        await viewModel.openSpeakerSheet(speakerID: 0)
        return Setup(viewModel: viewModel, meetingID: meetingID, steven: steven)
    }

    @Test("Opening the editor saves a pending summary edit first")
    func flushBeforeEdit() async throws {
        let fix = try makeCoreFixture(testName: "PersonEditFlush")
        defer { fix.cleanup() }
        let setup = try await setUp(fix, summary: "Steven agreed.")
        let (viewModel, meetingID, steven) = (setup.viewModel, setup.meetingID, setup.steven)

        viewModel.updateSummary("Steven agreed. Edited.")
        await viewModel.editPerson(PersonData(id: steven, name: "Steven"))

        #expect(viewModel.editingPerson?.id == steven)
        #expect(try await fix.store.meetingDetail(id: meetingID)?.summary == "Steven agreed. Edited.")
    }

    @Test("A rename in the editor reloads names, summary, and title")
    func reloadAfterRename() async throws {
        let fix = try makeCoreFixture(testName: "PersonEditReload")
        defer { fix.cleanup() }
        let setup = try await setUp(fix, summary: "Steven agreed.")
        let (viewModel, steven) = (setup.viewModel, setup.steven)

        await viewModel.editPerson(PersonData(id: steven, name: "Steven"))
        let editor = try #require(viewModel.editingPerson)
        await editor.load()
        editor.nameText = "Stephen"
        #expect(await editor.save())

        await viewModel.reloadAfterPeopleChange()
        #expect(viewModel.displayedTranscript?.speakerAssignments[0]?.name == "Stephen")
        #expect(viewModel.speakerSheetData?.rows.first?.assigned?.name == "Stephen")
        #expect(viewModel.summaryText == "Stephen agreed.")
        #expect(viewModel.editableTitle == "Stephen sync")
    }

    @Test("Opening this meeting from the editor closes the sheets and shows the transcript")
    func openCurrentMeeting() async throws {
        let fix = try makeCoreFixture(testName: "PersonEditOpen")
        defer { fix.cleanup() }
        let setup = try await setUp(fix)
        let (viewModel, meetingID, steven) = (setup.viewModel, setup.meetingID, setup.steven)

        await viewModel.editPerson(PersonData(id: steven, name: "Steven"))
        viewModel.openMeetingFromPersonEditor(meetingID)

        #expect(viewModel.editingPerson == nil)
        #expect(viewModel.speakerSheetTranscriptID == nil)
        #expect(viewModel.selectedTab == .transcript)
    }
}
