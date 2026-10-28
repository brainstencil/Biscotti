import AppCore
import BiscottiTestSupport
import DataStore
import Foundation
import MeetingChat
import Testing
import TranscriptUI
@testable import MeetingDetailUI

@Suite("MeetingDetailViewModel -- chat")
@MainActor
struct MeetingDetailChatTests {
    @Test("A time chip switches to the Transcript tab, highlights the moment and seeks there without playing")
    func chipSwitchesToTranscriptAndSeeks() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailChatTests")
        defer { fix.cleanup() }
        let meetingID = try await fix.createMeetingWithAudio()
        let player = FakeAudioPlayer()
        let now = Date(timeIntervalSinceReferenceDate: 5000)
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID, makePlayer: { player }, currentDate: { now })
        await viewModel.load()
        viewModel.chat.isCardOpen = true

        viewModel.showTranscript(at: 34)

        #expect(viewModel.selectedTab == .transcript)
        #expect(viewModel.transcriptRevealTime == 34)
        #expect(viewModel.transcriptHighlight == TranscriptHighlight(time: 34, now: now))
        #expect(player.currentTime == 34)
        #expect(player.playCalls == 0)
        #expect(!viewModel.isPlaying)
        #expect(viewModel.chat.isCardOpen, "the card stays open")
    }

    @Test("Leaving the meeting closes its card and keeps its thread")
    func changingMeetingClosesCard() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailChatTests")
        defer { fix.cleanup() }
        let meetingID = try await fix.store.createMeeting(title: "One")
        let otherID = try await fix.store.createMeeting(title: "Two")
        let (threadID, _) = try await fix.store.createChatThread(meetingID: meetingID, firstQuestion: "What did we decide?")
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        let other = MeetingDetailViewModel(core: fix.core, meetingID: otherID)
        await viewModel.load()
        await fix.chat.openThread(threadID, meetingID: meetingID)
        viewModel.chat.isCardOpen = true
        other.chat.isCardOpen = true

        viewModel.pageDidDisappear()

        #expect(!viewModel.chat.isCardOpen)
        #expect(viewModel.chat.openThreadID == threadID, "the field reads Continue chat when it comes back")
        #expect(other.chat.isCardOpen, "another meeting's card is its own")
    }

    @Test("Loading the page loads the meeting's chat threads")
    func loadLoadsChatThreads() async throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailChatTests")
        defer { fix.cleanup() }
        let meetingID = try await fix.store.createMeeting(title: "One")
        _ = try await fix.store.createChatThread(meetingID: meetingID, firstQuestion: "What did we decide?")
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: meetingID)
        #expect(viewModel.chat === fix.chat.state(for: meetingID))
        #expect(viewModel.chat.threads.isEmpty)

        await viewModel.load()

        #expect(viewModel.chat.threads.map(\.title) == ["What did we decide?"])
    }

    @Test("The field's actions: reopening the card and Open Settings")
    func chatActions() throws {
        let fix = try makeCoreFixture(testName: "MeetingDetailChatTests")
        defer { fix.cleanup() }
        let viewModel = MeetingDetailViewModel(core: fix.core, meetingID: UUID())

        viewModel.chatAction(.openCard)
        #expect(viewModel.chat.isCardOpen, "opened before the action returns, for the field's focus request")

        viewModel.chatAction(.openSettings)
        #expect(fix.core.route == .settings)
    }

    @Test("The card starts at 60% of the page and stays between 200 pt and the page above the playback bar")
    func cardHeightClamps() {
        #expect(MeetingChatCardLayout.height(stored: nil, pageHeight: 800, transportHeight: 60) == 480)
        #expect(MeetingChatCardLayout.height(stored: 100, pageHeight: 800, transportHeight: 60) == 200)
        #expect(MeetingChatCardLayout.height(stored: 2000, pageHeight: 800, transportHeight: 60) == 733)
        #expect(MeetingChatCardLayout.height(stored: 500, pageHeight: 800, transportHeight: 60) == 500)
        #expect(MeetingChatCardLayout.maximumHeight(pageHeight: 150, transportHeight: 60) == 200, "never below the minimum")
    }

    @Test("While the card is open, the transcript list can scroll its last bubble up to the card's top edge")
    func listMarginClearsTheCard() {
        // A 480 pt card 7 pt above a 60 pt transport bar; the list already
        // ends above the 24 pt fade and the 50 pt band.
        let pinnedBottom: CGFloat = 134
        let cardTop: CGFloat = 60 + 7 + 480
        let margin = MeetingChatCardLayout.listBottomMargin(cardHeight: 480, pinnedBottomHeight: pinnedBottom, transportHeight: 60)
        #expect(margin == 413)
        #expect(pinnedBottom + margin == cardTop, "the list's content ends at the card's top")
        #expect(MeetingChatCardLayout.listBottomMargin(cardHeight: 10, pinnedBottomHeight: 134, transportHeight: 60) == 0)
    }
}
