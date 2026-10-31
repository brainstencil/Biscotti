import AppKit
import Foundation
import Testing
@testable import MeetingChat
@testable import MeetingChatUI

@Suite("Chat question field")
struct ChatFieldPresentationTests {
    private func field(
        _ availability: ChatAvailability = .available,
        hasThread: Bool = false,
        isCardOpen: Bool = false,
        isAnswering: Bool = false,
        hasText: Bool = false
    ) -> ChatFieldPresentation {
        ChatFieldPresentation.make(
            availability: availability,
            hasThread: hasThread,
            isCardOpen: isCardOpen,
            isAnswering: isAnswering,
            hasText: hasText
        )
    }

    @Test("no thread, a thread with the card closed, and the card open give the UI design's placeholders")
    func fieldPlaceholders() {
        #expect(field().placeholder == "Ask about this meeting")
        #expect(field(hasThread: true).placeholder == "Continue chat")
        #expect(field(hasThread: true, isCardOpen: true).placeholder == "Ask a follow-up")
        // A card opened before any question (⌘J) still asks about the meeting.
        #expect(field(isCardOpen: true).placeholder == "Ask about this meeting")
    }

    @Test("empty sends nothing, text sends, an answer shows Stop, unavailable shows no button")
    func fieldButtons() {
        #expect(field().button == .sendDisabled)
        #expect(field(hasThread: true, isCardOpen: true).button == .sendDisabled)
        #expect(field(hasText: true).button == .send)
        #expect(field(hasThread: true, isCardOpen: true, isAnswering: true).button == .stop)
        #expect(field(.noModel, hasText: true).button == .none)
        #expect(field().isEnabled)
        #expect(field(hasText: true).action == nil)
    }

    @Test("an answer in this meeting keeps Stop in reach even if the meeting turned unavailable")
    func answeringWinsOverAvailability() {
        let answering = field(.liveTranscriptOff, hasThread: true, isCardOpen: true, isAnswering: true, hasText: true)
        #expect(answering == ChatFieldPresentation(placeholder: "", button: .stop, isEnabled: true, action: nil))
    }

    @Test("each unavailable reason has the UI design's text and action, and no text field")
    func unavailableFieldTexts() {
        func unavailable(_ text: String, _ action: ChatFieldPresentation.ActionButton? = nil) -> ChatFieldPresentation {
            ChatFieldPresentation(placeholder: text, button: .none, isEnabled: false, action: action)
        }
        let expected: [(ChatAvailability, ChatFieldPresentation)] = [
            (.noModel, unavailable("Download the AI model to ask about meetings", .init(title: "Open Settings", action: .openSettings))),
            (.liveTranscriptOff, unavailable("Turn on the live transcript to ask during the meeting", .init(title: "Turn On", action: .turnOnLiveTranscript))),
            (.noTranscript, unavailable("This meeting has no transcript to ask about")),
            (.transcribing, unavailable("Ask once the transcript is ready")),
            (.answeringElsewhere, unavailable("Answering in another meeting…"))
        ]
        for (availability, presentation) in expected {
            #expect(field(availability, hasThread: true, hasText: true) == presentation, "\(availability)")
        }
    }

    @Test("make(state:) reads availability, the open thread, the card, the answer and the trimmed draft")
    @MainActor
    func fieldFromState() {
        let world = AvailabilityBox()
        let state = MeetingChatState(meetingID: UUID()) { _ in world.availability }
        #expect(ChatFieldPresentation.make(state: state) == field())

        state.draft = "  \n "
        #expect(ChatFieldPresentation.make(state: state).button == .sendDisabled)
        state.draft = " Who owns it? "
        #expect(ChatFieldPresentation.make(state: state).button == .send)

        state.openThreadID = UUID()
        #expect(ChatFieldPresentation.make(state: state).placeholder == "Continue chat")
        state.isCardOpen = true
        #expect(ChatFieldPresentation.make(state: state).placeholder == "Ask a follow-up")
        state.isAnswering = true
        #expect(ChatFieldPresentation.make(state: state).button == .stop)

        state.isAnswering = false
        world.availability = .answeringElsewhere
        #expect(ChatFieldPresentation.make(state: state).placeholder == "Answering in another meeting…")
    }

    @Test("a cursor request is meant for the card's field while the card is open, else for the field in its place")
    func requestedFocusGoesToTheShownField() {
        let opening = FocusTrigger(isRequested: true, isCardOpen: true)
        #expect(opening.isMeant(for: .recordingCard))
        #expect(opening.isMeant(for: .meetingCard))
        // The row field that asked is still there for a moment: it must not keep it.
        #expect(!opening.isMeant(for: .recordingRow))
        #expect(!opening.isMeant(for: .meetingPage))

        let closing = FocusTrigger(isRequested: true, isCardOpen: false)
        #expect(closing.isMeant(for: .recordingRow))
        #expect(closing.isMeant(for: .meetingPage))
        #expect(!closing.isMeant(for: .meetingCard))

        #expect(!FocusTrigger(isRequested: false, isCardOpen: true).isMeant(for: .recordingCard))
    }

    @Test("the field the request is meant for takes the cursor and uses the request up")
    @MainActor
    func requestedFocusIsUsedUp() {
        let state = MeetingChatState(meetingID: UUID()) { _ in .available }
        state.focusRequest = true
        state.isCardOpen = true
        // The row field that asked is still shown for a moment: it leaves the request.
        #expect(!ChatQuestionField.takesRequestedFocus(state: state, placement: .recordingRow))
        #expect(state.focusRequest)
        #expect(ChatQuestionField.takesRequestedFocus(state: state, placement: .recordingCard))
        #expect(!state.focusRequest)
        #expect(!ChatQuestionField.takesRequestedFocus(state: state, placement: .recordingCard))
    }

    @Test("⌘J with no model, then the download ends: the cursor stays in the notes")
    @MainActor
    func focusRequestedWhileUnavailableIsDropped() {
        let world = AvailabilityBox()
        world.availability = .noModel
        let state = MeetingChatState(meetingID: UUID()) { _ in world.availability }
        state.isCardOpen = true
        state.focusRequest = true

        // The card shows the unavailable field, which uses the request up without the cursor.
        #expect(!ChatQuestionField.takesRequestedFocus(state: state, placement: .meetingCard))
        #expect(!state.focusRequest)

        // The download ends while the user types notes: the editor appears and takes nothing.
        world.availability = .available
        #expect(!ChatQuestionField.takesRequestedFocus(state: state, placement: .meetingCard))
    }

    @Test("Return sends, Shift- or Option-Return adds a line, and during an input method's composition Return is the input method's")
    func returnKey() {
        #expect(ChatReturnKey.action(modifiers: [], isComposing: false) == .send)
        #expect(ChatReturnKey.action(modifiers: .shift, isComposing: false) == .lineBreak)
        #expect(ChatReturnKey.action(modifiers: .option, isComposing: false) == .lineBreak)
        #expect(ChatReturnKey.action(modifiers: [], isComposing: true) == .compose)
        #expect(ChatReturnKey.action(modifiers: .shift, isComposing: true) == .compose)
    }

    @Test("a text view with marked text is composing; without it, or with no text view, it is not")
    @MainActor
    func composingReadsMarkedText() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        textView.string = "会議"
        #expect(!ChatReturnKey.isComposing(textView))

        textView.setMarkedText("かいぎ", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 2, length: 0))
        #expect(ChatReturnKey.isComposing(textView))

        textView.unmarkText()
        #expect(!ChatReturnKey.isComposing(textView))
        #expect(!ChatReturnKey.isComposing(nil))
        #expect(!ChatReturnKey.isComposing(NSView()))
    }

    @Test("the count shows from 1,800 characters, against the 2,000 limit")
    func characterCountAppearsAt1800() {
        let english = Locale(identifier: "en_US")
        #expect(ChatFieldPresentation.characterCount(length: 0, locale: english) == nil)
        #expect(ChatFieldPresentation.characterCount(length: 1799, locale: english) == nil)
        #expect(ChatFieldPresentation.characterCount(length: 1800, locale: english) == "1,800 / 2,000")
        #expect(ChatFieldPresentation.characterCount(length: 1950, locale: english) == "1,950 / 2,000")
        #expect(ChatFieldPresentation.characterCount(length: 2000, locale: english) == "2,000 / 2,000")
        #expect(ChatFieldPresentation.maxLength == MeetingChatService.maxQuestionLength)
    }
}

/// What the state's availability reads, set by the test.
@MainActor
private final class AvailabilityBox {
    var availability = ChatAvailability.available
}
