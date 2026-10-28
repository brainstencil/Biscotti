import Foundation
import MeetingChat
import MeetingChatUI
import TranscriptUI

// MARK: - Chat

public extension MeetingDetailViewModel {
    var chatService: MeetingChatService {
        core.chat
    }

    /// A time chip in the chat: the Transcript tab, scrolled to that moment
    /// with the cited bubble highlighted, and the playback position moved
    /// there without playing. The card stays open.
    func showTranscript(at time: TimeInterval) {
        selectedTab = .transcript
        transcriptRevealTime = time
        transcriptHighlight = TranscriptHighlight(time: time, now: currentDate())
        seek(to: time)
    }

    /// The page went, for example because another meeting was selected:
    /// its card closes. The thread stays open, so the field reads "Continue
    /// chat" when the meeting is shown again.
    func pageDidDisappear() {
        chat.isCardOpen = false
    }

    /// The question field's actions outside the chat.
    func chatAction(_ action: ChatFieldAction) {
        switch action {
        case .openSettings:
            openSettings()
        case .turnOnLiveTranscript:
            Task { await core.chat.turnOnLiveTranscript() }
        case .openCard:
            chat.isCardOpen = true
        }
    }
}
