import AppCore
import Foundation
import MeetingChat
import Observation

/// View > Ask About This Meeting (⌘J). The app delegate owns one and gives
/// it the core once the core is built.
@MainActor @Observable
public final class ChatCommandModel {
    public var core: AppCore?
    /// Brings the main window forward; the app delegate sets it.
    @ObservationIgnored public var showMainWindow: (@MainActor () -> Void)?

    /// Nonisolated so the app delegate can create it as a stored property.
    public nonisolated init() {}

    public init(core: AppCore?) {
        self.core = core
    }

    /// The meeting the window shows: the recording on the recording screen,
    /// the one selected meeting on the Meetings screen. Nil elsewhere.
    public var visibleMeetingID: UUID? {
        guard let core else { return nil }
        switch core.route {
        case .recording:
            return core.recording.recordingMeetingID
        case .meetings:
            let selection = core.meetingsSelection
            return selection.count == 1 ? selection.first : nil
        case .home, .event, .settings, .onboarding:
            return nil
        }
    }

    /// Enabled while the window shows one meeting.
    public var isAvailable: Bool {
        visibleMeetingID != nil
    }

    /// Opens the visible meeting's chat card and asks for the cursor in its
    /// field. On the recording screen the card takes the transcript drawer's
    /// place, so the drawer closes.
    public func perform() {
        guard let core, let meetingID = visibleMeetingID else { return }
        showMainWindow?()
        if core.route == .recording {
            core.liveTranscription.isDrawerExpanded = false
        }
        let state = core.chat.state(for: meetingID)
        state.isCardOpen = true
        state.focusRequest = true
    }
}
