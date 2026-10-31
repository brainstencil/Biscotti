import AppCore
import BiscottiTestSupport
import Foundation
import LiveTranscriptionService
import MeetingChat
import Testing
@testable import AppShellUI

@Suite("ChatCommandModel")
@MainActor
struct ChatCommandModelTests {
    private func fixture() throws -> (CoreFixture, LiveTranscriptionService) {
        let live = makeFakeLiveService(
            timing: LiveTiming(publishInterval: .zero, stopDeadline: .milliseconds(200), pumpInterval: .milliseconds(5), finishMargin: .milliseconds(50))
        )
        return try (makeCoreFixture(liveTranscription: live, testName: "ChatCommandModel"), live)
    }

    @Test("Ask About This Meeting is enabled on a meeting page and on the recording screen, disabled elsewhere")
    func askCommandAvailability() async throws {
        #expect(!ChatCommandModel().isAvailable, "no core yet")
        let (fix, _) = try fixture()
        let model = ChatCommandModel(core: fix.core)
        #expect(fix.core.route == .home)
        #expect(!model.isAvailable, "Home")

        let first = try await fix.store.createMeeting(title: "One")
        let second = try await fix.store.createMeeting(title: "Two")
        fix.core.select(first)
        #expect(model.visibleMeetingID == first)
        #expect(model.isAvailable)
        fix.core.selectFromList([first, second])
        #expect(!model.isAvailable, "several meetings selected")
        fix.core.selectFromList([])
        #expect(!model.isAvailable, "no meeting selected")
        fix.core.showSettings()
        #expect(!model.isAvailable, "Settings")

        await fix.core.startRecording()
        #expect(fix.core.route == .recording)
        #expect(model.visibleMeetingID == fix.core.recording.recordingMeetingID)
        #expect(model.isAvailable)
        await stop(fix)
    }

    @Test("The command opens the visible meeting's card and asks for the cursor in its field")
    func askCommandOpensCardAndFocuses() async throws {
        let (fix, _) = try fixture()
        let model = ChatCommandModel(core: fix.core)
        let windowShown = ShowCount()
        model.showMainWindow = { windowShown.count += 1 }
        let meetingID = try await fix.store.createMeeting(title: "One")
        fix.core.select(meetingID)

        model.perform()

        let state = fix.chat.state(for: meetingID)
        #expect(state.isCardOpen)
        #expect(state.focusRequest)
        #expect(windowShown.count == 1)
        fix.cleanup()
    }

    @Test("On the recording screen the card takes the open drawer's place")
    func askCommandClosesTheDrawer() async throws {
        let (fix, live) = try fixture()
        let model = ChatCommandModel(core: fix.core)
        await fix.core.startRecording()
        let meetingID = try #require(fix.core.recording.recordingMeetingID)
        live.isDrawerExpanded = true

        model.perform()

        #expect(!live.isDrawerExpanded)
        #expect(fix.chat.state(for: meetingID).isCardOpen)
        await stop(fix)
    }

    @Test("Show Live Transcript closes the recording's chat card, which shares the drawer's place")
    func liveCommandClosesChat() async throws {
        let (fix, live) = try fixture()
        let liveCommand = LiveCommandModel(core: fix.core)
        await fix.core.startRecording()
        let state = try fix.chat.state(for: #require(fix.core.recording.recordingMeetingID))
        state.isCardOpen = true

        liveCommand.toggle()
        #expect(live.isDrawerExpanded)
        #expect(!state.isCardOpen)

        live.isDrawerExpanded = false
        state.isCardOpen = true
        fix.core.showSettings()
        liveCommand.toggle()
        #expect(fix.core.route == .recording)
        #expect(live.isDrawerExpanded)
        #expect(!state.isCardOpen, "also when it brings the recording screen forward")
        await stop(fix)
    }

    private func stop(_ fix: CoreFixture) async {
        _ = await fix.core.stopRecording()
        await fix.core.awaitPendingTranscription()
        fix.cleanup()
    }
}

@MainActor
private final class ShowCount {
    var count = 0
}
