import Foundation
import MeetingChat

/// What the question field shows: its placeholder, its round button and,
/// when chat is unavailable, the reason and the action that fixes it.
struct ChatFieldPresentation: Equatable {
    enum ButtonKind: Equatable {
        case sendDisabled
        case send
        case stop
        /// Unavailable: the field shows no round button.
        case none
    }

    struct ActionButton: Equatable {
        let title: String
        let action: ChatFieldAction
    }

    /// The placeholder, or the reason chat is unavailable.
    let placeholder: String
    let button: ButtonKind
    /// False while chat is unavailable: the field shows the reason, not a text field.
    let isEnabled: Bool
    let action: ActionButton?

    static let maxLength = MeetingChatService.maxQuestionLength
    /// The character count shows from this length.
    static let countThreshold = 1800

    @MainActor
    static func make(state: MeetingChatState) -> Self {
        make(
            availability: state.availability,
            hasThread: state.openThreadID != nil,
            isCardOpen: state.isCardOpen,
            isAnswering: state.isAnswering,
            hasText: hasText(state.draft)
        )
    }

    static func make(
        availability: ChatAvailability,
        hasThread: Bool,
        isCardOpen: Bool,
        isAnswering: Bool,
        hasText: Bool
    ) -> Self {
        // An answer in this meeting comes first, so Stop stays in reach even if
        // the meeting became unavailable meanwhile (the live transcript turned off).
        if isAnswering {
            return Self(placeholder: "", button: .stop, isEnabled: true, action: nil)
        }
        if let unavailable = unavailable(availability) {
            return Self(placeholder: unavailable.text, button: .none, isEnabled: false, action: unavailable.action)
        }
        let placeholder = switch (hasThread, isCardOpen) {
        case (false, _): "Ask about this meeting"
        case (true, false): "Continue chat"
        case (true, true): "Ask a follow-up"
        }
        return Self(placeholder: placeholder, button: hasText ? .send : .sendDisabled, isEnabled: true, action: nil)
    }

    /// Whether the draft holds a question to send.
    static func hasText(_ draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "1,950 / 2,000" from 1,800 characters, otherwise nil.
    static func characterCount(length: Int, locale: Locale = .current) -> String? {
        guard length >= countThreshold else { return nil }
        let style = IntegerFormatStyle<Int>.number.locale(locale)
        return "\(length.formatted(style)) / \(maxLength.formatted(style))"
    }

    /// The reason and its action. Turn On starts the live transcript from now,
    /// so the text promises nothing about what was said before it (backlog B1).
    private static func unavailable(_ availability: ChatAvailability) -> (text: String, action: ActionButton?)? {
        switch availability {
        case .available:
            nil
        case .noModel:
            ("Download the AI model to ask about meetings", ActionButton(title: "Open Settings", action: .openSettings))
        case .liveTranscriptOff:
            ("Turn on the live transcript to ask during the meeting", ActionButton(title: "Turn On", action: .turnOnLiveTranscript))
        case .noTranscript:
            ("This meeting has no transcript to ask about", nil)
        case .transcribing:
            ("Ask once the transcript is ready", nil)
        case .answeringElsewhere:
            ("Answering in another meeting…", nil)
        }
    }
}
