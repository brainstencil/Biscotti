import AppCore
import BiscottiTestSupport
import Foundation
import LiveTranscriptionService
import MeetingChat
import Recording
import Testing
@testable import RecordingUI

/// A recording screen whose core runs a fake live engine, recording.
@MainActor
private struct ChatScreenFixture {
    let fix: CoreFixture
    let live: LiveTranscriptionService
    let viewModel: RecordingViewModel

    init(liveEnabled: Bool = true) async throws {
        // The fake recorder never closes its tap, so a finish after Stop runs
        // into the stop deadline, kept short here.
        live = makeFakeLiveService(
            isEnabled: liveEnabled,
            timing: LiveTiming(publishInterval: .zero, stopDeadline: .milliseconds(200), pumpInterval: .milliseconds(5), finishMargin: .milliseconds(50))
        )
        fix = try makeCoreFixture(modelDownloaded: true, liveTranscription: live, testName: "RecordingViewModelChatTests")
        viewModel = RecordingViewModel(core: fix.core)
        await fix.core.startRecording()
    }

    func chat() throws -> MeetingChatState {
        try #require(viewModel.chat)
    }

    func stop() async {
        _ = await fix.core.stopRecording()
        await fix.core.awaitPendingTranscription()
        fix.cleanup()
    }
}

@Suite("RecordingViewModel -- chat")
@MainActor
struct RecordingViewModelChatTests {
    @Test("The bottom is one slot: the card wins over the drawer, and the drawer needs the live transcript")
    func bottomSlotPrecedence() {
        #expect(RecordingViewModel.bottomSlot(isCardOpen: true, isDrawerExpanded: true, showsLive: true) == .chat)
        #expect(RecordingViewModel.bottomSlot(isCardOpen: true, isDrawerExpanded: false, showsLive: false) == .chat)
        #expect(RecordingViewModel.bottomSlot(isCardOpen: false, isDrawerExpanded: true, showsLive: true) == .transcript)
        #expect(RecordingViewModel.bottomSlot(isCardOpen: false, isDrawerExpanded: true, showsLive: false) == .collapsed)
        #expect(RecordingViewModel.bottomSlot(isCardOpen: false, isDrawerExpanded: false, showsLive: true) == .collapsed)
    }

    @Test("Opening the chat closes the drawer, and opening the drawer closes the chat")
    func bottomSlotRules() async throws {
        let ctx = try await ChatScreenFixture()
        let chat = try ctx.chat()
        #expect(ctx.viewModel.bottomSlot == .collapsed)

        ctx.viewModel.toggleDrawer()
        #expect(ctx.viewModel.bottomSlot == .transcript)

        ctx.viewModel.openChat()
        #expect(chat.isCardOpen)
        #expect(!ctx.viewModel.isDrawerExpanded)
        #expect(ctx.viewModel.bottomSlot == .chat)

        ctx.viewModel.toggleDrawer()
        #expect(!chat.isCardOpen)
        #expect(ctx.viewModel.isDrawerExpanded)
        #expect(ctx.viewModel.bottomSlot == .transcript)

        ctx.viewModel.toggleDrawer()
        #expect(ctx.viewModel.bottomSlot == .collapsed)
        await ctx.stop()
    }

    @Test("A time chip opens the drawer at that moment with Back to chat, which reopens the card")
    func chipOpensDrawerWithBackToChat() async throws {
        let ctx = try await ChatScreenFixture()
        let chat = try ctx.chat()
        ctx.viewModel.openChat()

        ctx.viewModel.showTranscript(at: 42)

        #expect(!chat.isCardOpen)
        #expect(ctx.viewModel.isDrawerExpanded)
        #expect(ctx.viewModel.revealTime == 42)
        #expect(ctx.viewModel.transcriptHighlight?.time == 42)
        #expect(ctx.viewModel.transcriptOpenedFromChat)
        #expect(ctx.viewModel.bottomSlot == .transcript)
        #expect(LiveTranscriptOverlay.keepsChatCard(slot: .transcript, openedFromChat: true), "its list keeps its place")

        ctx.viewModel.backToChat()

        #expect(chat.isCardOpen)
        #expect(!ctx.viewModel.isDrawerExpanded)
        #expect(!ctx.viewModel.transcriptOpenedFromChat)
        #expect(ctx.viewModel.bottomSlot == .chat)
        await ctx.stop()
    }

    @Test("Back to chat goes once the drawer closes or opens some other way")
    func backToChatClears() async throws {
        let ctx = try await ChatScreenFixture()
        ctx.viewModel.showTranscript(at: 10)
        ctx.viewModel.drawerDidCollapse()
        #expect(!ctx.viewModel.transcriptOpenedFromChat, "closed by ⌘T or Esc")

        ctx.viewModel.showTranscript(at: 10)
        ctx.viewModel.collapseDrawer()
        #expect(!ctx.viewModel.transcriptOpenedFromChat)

        ctx.viewModel.showTranscript(at: 10)
        ctx.viewModel.revealNoteInTranscript(MeetingNote(text: "Ship it", timestamp: 5))
        #expect(!ctx.viewModel.transcriptOpenedFromChat, "a note opened it")
        #expect(ctx.viewModel.isDrawerExpanded)
        await ctx.stop()
    }

    @Test("A note's time closes the chat card to show the drawer")
    func noteRevealClosesChat() async throws {
        let ctx = try await ChatScreenFixture()
        let chat = try ctx.chat()
        ctx.viewModel.openChat()

        ctx.viewModel.revealNoteInTranscript(MeetingNote(text: "Ship it", timestamp: 5))

        #expect(!chat.isCardOpen)
        #expect(ctx.viewModel.bottomSlot == .transcript)
        await ctx.stop()
    }

    @Test("The field's actions: Open Settings, Turn On and reopening the card")
    func chatActions() async throws {
        let ctx = try await ChatScreenFixture(liveEnabled: false)
        let chat = try ctx.chat()
        #expect(chat.availability == .liveTranscriptOff)

        ctx.viewModel.chatAction(.turnOnLiveTranscript)
        try await waitUntil("the live transcript to turn on") { ctx.live.isEnabled }
        #expect(chat.availability == .available)

        ctx.viewModel.toggleDrawer()
        ctx.viewModel.chatAction(.openCard)
        #expect(chat.isCardOpen, "opened before the action returns, for the field's focus request")
        #expect(!ctx.viewModel.isDrawerExpanded)

        ctx.viewModel.chatAction(.openSettings)
        #expect(ctx.fix.core.route == .settings)
        await ctx.stop()
    }

    @Test("Without a recording there is no chat")
    func noChatWithoutRecording() throws {
        let fix = try makeCoreFixture(testName: "RecordingViewModelChatTests")
        defer { fix.cleanup() }
        let viewModel = RecordingViewModel(core: fix.core)

        #expect(viewModel.chat == nil)
        #expect(viewModel.bottomSlot == .collapsed)
    }

    @Test("The field beside the toggle reaches the notes column's trailing edge")
    func rowFieldReachesNotesColumn() {
        // 12 pt inset, the 44 pt toggle, 12 pt gap.
        #expect(LiveTranscriptOverlay.rowFieldWidth(notesColumnTrailing: 652, showsToggle: true) == 584)
        #expect(LiveTranscriptOverlay.rowFieldWidth(notesColumnTrailing: 652, showsToggle: false) == 640)
        #expect(LiveTranscriptOverlay.rowFieldWidth(notesColumnTrailing: 0, showsToggle: true) == 200, "before the column is measured")
    }

    @Test("The card stays, hidden, only under a drawer one of its times opened")
    func cardKeptOnlyForBackToChat() {
        #expect(LiveTranscriptOverlay.keepsChatCard(slot: .chat, openedFromChat: false))
        #expect(LiveTranscriptOverlay.keepsChatCard(slot: .transcript, openedFromChat: true))
        #expect(!LiveTranscriptOverlay.keepsChatCard(slot: .transcript, openedFromChat: false))
        #expect(!LiveTranscriptOverlay.keepsChatCard(slot: .collapsed, openedFromChat: true))
    }
}
