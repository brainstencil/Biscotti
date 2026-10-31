import Foundation
import MeetingChat
import MeetingChatUI
import TranscriptUI

/// What the bottom of the recording screen shows. It is one slot: opening
/// the chat closes the transcript drawer, and opening the drawer closes the chat.
public enum RecordingBottomSlot: Equatable, Sendable {
    /// The toggle and, beside it, the question field.
    case collapsed
    /// The chat card, in the drawer's place.
    case chat
    /// The live transcript drawer.
    case transcript
}

// MARK: - Chat

public extension RecordingViewModel {
    /// The recording meeting's chat, nil while nothing records. Read from
    /// `recordingMeetingID`, which, unlike the recording state, does not
    /// change with every elapsed tick.
    var chat: MeetingChatState? {
        core.recording.recordingMeetingID.map { core.chat.state(for: $0) }
    }

    var chatService: MeetingChatService {
        core.chat
    }

    var bottomSlot: RecordingBottomSlot {
        Self.bottomSlot(
            isCardOpen: chat?.isCardOpen ?? false,
            isDrawerExpanded: isDrawerExpanded,
            showsLive: showsLiveTranscript
        )
    }

    /// The card wins when both are open, for example in the update that
    /// opens one before the other has closed. The drawer exists only while
    /// live transcription runs.
    static func bottomSlot(isCardOpen: Bool, isDrawerExpanded: Bool, showsLive: Bool) -> RecordingBottomSlot {
        if isCardOpen { return .chat }
        return showsLive && isDrawerExpanded ? .transcript : .collapsed
    }

    /// Opens the chat card in the drawer's place.
    func openChat() {
        chat?.isCardOpen = true
        core.liveTranscription.isDrawerExpanded = false
        transcriptOpenedFromChat = false
    }

    /// A time chip in the chat: the drawer opens at that moment, with the
    /// cited bubble highlighted and "Back to chat" in its header. With the
    /// live transcript off there is no drawer to open, so the card stays.
    func showTranscript(at time: TimeInterval) {
        guard showsLiveTranscript else { return }
        chat?.isCardOpen = false
        transcriptOpenedFromChat = true
        transcriptHighlight = TranscriptHighlight(time: time)
        core.liveTranscription.reveal(atRecordingTime: time)
    }

    /// "Back to chat": the card again, where it was scrolled to.
    func backToChat() {
        openChat()
    }

    /// The drawer closed, by any means (its toggle, Esc, ⌘T): the next time
    /// it opens, it was not opened from the chat.
    func drawerDidCollapse() {
        transcriptOpenedFromChat = false
    }

    /// The question field's actions outside the chat.
    func chatAction(_ action: ChatFieldAction) {
        switch action {
        case .openSettings:
            core.showSettings()
        case .turnOnLiveTranscript:
            Task { await core.chat.turnOnLiveTranscript() }
        case .openCard:
            openChat()
        }
    }
}
