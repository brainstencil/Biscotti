import AppKit
import DesignSystem
import MeetingChat
import SwiftUI

/// The question field in every state: a 40 pt pill with the round Send or
/// Stop button, or, while chat is unavailable, the reason and its action.
/// It edits the meeting's draft, sends through the service, and asks its
/// host for everything outside the chat (`onAction`).
public struct ChatQuestionField: View {
    static let buttonInset: CGFloat = 6
    static let leadingPadding: CGFloat = 16

    @Bindable var state: MeetingChatState
    let service: MeetingChatService
    let placement: ChatPlacement
    let focus: FocusState<Bool>.Binding
    let onAction: (ChatFieldAction) -> Void
    @State private var selection: TextSelection?

    public init(
        state: MeetingChatState,
        service: MeetingChatService,
        placement: ChatPlacement,
        focus: FocusState<Bool>.Binding,
        onAction: @escaping (ChatFieldAction) -> Void
    ) {
        _state = Bindable(state)
        self.service = service
        self.placement = placement
        self.focus = focus
        self.onAction = onAction
    }

    public var body: some View {
        let presentation = ChatFieldPresentation.make(state: state)
        Group {
            if presentation.isEnabled {
                editor(presentation)
            } else {
                UnavailableChatField(presentation: presentation, onAction: onAction)
            }
        }
        // On both branches, so a request made while chat is unavailable is
        // used up then, not later when chat becomes available on its own.
        .task(id: FocusTrigger(isRequested: state.focusRequest, isCardOpen: state.isCardOpen)) {
            if Self.takesRequestedFocus(state: state, placement: placement) {
                focus.wrappedValue = true
            }
        }
    }

    // MARK: - Editor

    private func editor(_ presentation: ChatFieldPresentation) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.chatFieldHeight / 2, style: .continuous)
        return HStack(alignment: .bottom, spacing: Tokens.spacingSM) {
            // The count goes under the text, at its right, so the text keeps
            // its width: when a paste brings the count in beside the text,
            // the text field narrows without wrapping its lines again, and
            // their ends are cut off.
            VStack(alignment: .trailing, spacing: 0) {
                textField(presentation)
                if let count = ChatFieldPresentation.characterCount(length: state.draft.count) {
                    Text(count)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.inkTertiary)
                        .fixedSize()
                        .padding(.top, -Tokens.spacingXS)
                        .padding(.bottom, Self.buttonInset)
                }
            }

            ChatRoundButton(kind: presentation.button) {
                presentation.button == .stop ? service.stop() : send()
            }
            .padding(.bottom, Self.buttonInset)
        }
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, Self.buttonInset)
        .frame(minHeight: Tokens.chatFieldHeight)
        .background {
            shape.fill(Tokens.cardFill)
                .shadow(color: placement.isInCard ? .clear : Tokens.cardShadow, radius: 6, y: 2)
        }
        .overlay { shape.strokeBorder(Tokens.cardStroke, lineWidth: 1) }
        .onChange(of: state.draft) { _, draft in
            // Typing stops at the limit; a paste is cut to it.
            if draft.count > ChatFieldPresentation.maxLength {
                state.draft = String(draft.prefix(ChatFieldPresentation.maxLength))
            }
        }
    }

    private func textField(_ presentation: ChatFieldPresentation) -> some View {
        TextField(
            "Ask about this meeting",
            text: $state.draft,
            selection: $selection,
            prompt: Text(presentation.placeholder),
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(.ink)
        .lineLimit(1 ... 5)
        .focused(focus)
        // The model loads while the question is typed (`questionFieldDidTakeFocus`).
        .onChange(of: focus.wrappedValue, initial: true) { _, isFocused in
            if isFocused {
                service.questionFieldDidTakeFocus(meetingID: state.meetingID)
            }
        }
        .padding(.vertical, 11)
        .overlay { continueChatTarget }
        .onKeyPress(.return, phases: .down) { press in
            handleReturn(press)
        }
        // In case the text field keeps Return for itself. A second send is
        // a no-op: the first clears the draft and takes the answer slot.
        .onSubmit(send)
        .onKeyPress(.escape, phases: .down) { _ in
            handleEscape()
        }
        .accessibilityLabel("Ask about this meeting")
    }

    /// Over the text of a "Continue chat" field outside the card: a click
    /// reopens the card on its thread, where the field takes the cursor.
    @ViewBuilder
    private var continueChatTarget: some View {
        if !placement.isInCard, state.openThreadID != nil, !state.isCardOpen {
            Color.clear
                .contentShape(Rectangle())
                .pointerStyle(.horizontalText)
                .onTapGesture {
                    onAction(.openCard)
                    state.focusRequest = true
                }
                .accessibilityHidden(true)
        }
    }

    // MARK: - Focus

    /// Uses up a `focusRequest` meant for this field, the one the user sees:
    /// the card's while the card is open, the one in its place while it is
    /// closed. Every change that swaps one field for the other asks this way,
    /// because the field that had the cursor goes, and its focus goes with it.
    /// Runs once the field is shown, and again when the request or the card
    /// changes.
    ///
    /// Returns whether the field takes the cursor: only while it can be typed
    /// in. A request made while chat is unavailable is used up all the same,
    /// so the cursor never jumps here later, when chat becomes available with
    /// no action of the user's (a model download ending, another meeting's
    /// answer ending) and the user may be typing notes. After Turn On, the
    /// user clicks the field.
    static func takesRequestedFocus(state: MeetingChatState, placement: ChatPlacement) -> Bool {
        let trigger = FocusTrigger(isRequested: state.focusRequest, isCardOpen: state.isCardOpen)
        guard trigger.isMeant(for: placement) else { return false }
        state.focusRequest = false
        return ChatFieldPresentation.make(state: state).isEnabled
    }

    // MARK: - Keys

    /// Return sends; Shift-Return (or Option-Return) adds a line. While an
    /// input method composes (Chinese, Japanese), Return is the input
    /// method's: it confirms the composition.
    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        switch ChatReturnKey.action(modifiers: press.modifiers, isComposing: ChatReturnKey.isComposingInKeyWindow) {
        case .send:
            send()
        case .lineBreak:
            insertLineBreak()
        case .compose:
            return .ignored
        }
        return .handled
    }

    /// Esc stops an answer being written; with none, it closes the card.
    private func handleEscape() -> KeyPress.Result {
        if state.isAnswering {
            service.stop()
            return .handled
        }
        if state.isCardOpen {
            state.isCardOpen = false
            return .handled
        }
        return .ignored
    }

    private func send() {
        guard ChatFieldPresentation.make(state: state).button == .send else { return }
        let meetingID = state.meetingID
        let opensCard = !placement.isInCard
        Task {
            await service.ask(meetingID: meetingID)
            // Sent from outside the card: the card opened in this field's
            // place, and its field takes the cursor for a follow-up.
            if opensCard, state.isCardOpen {
                state.focusRequest = true
            }
        }
    }

    /// Replaces the selection with a line break and puts the cursor after it.
    private func insertLineBreak() {
        var text = state.draft
        var range = text.endIndex ..< text.endIndex
        if case let .selection(selected)? = selection?.indices, selected.upperBound <= text.endIndex {
            range = selected
        }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        text.replaceSubrange(range, with: "\n")
        guard text.count <= ChatFieldPresentation.maxLength else { return }
        state.draft = text
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: offset + 1))
    }
}

/// What Return does in the question field.
enum ChatReturnKey: Equatable {
    case send
    case lineBreak
    /// Left to the input method, which confirms its composition.
    case compose

    static func action(modifiers: EventModifiers, isComposing: Bool) -> Self {
        if isComposing { return .compose }
        return modifiers.contains(.shift) || modifiers.contains(.option) ? .lineBreak : .send
    }

    /// Whether the text view being edited in the key window holds marked
    /// text: an input method's composition, not yet confirmed.
    @MainActor static var isComposingInKeyWindow: Bool {
        isComposing(NSApp.keyWindow?.firstResponder)
    }

    @MainActor static func isComposing(_ responder: NSResponder?) -> Bool {
        (responder as? any NSTextInputClient)?.hasMarkedText() ?? false
    }
}

/// What decides which field takes a requested cursor.
struct FocusTrigger: Equatable {
    let isRequested: Bool
    let isCardOpen: Bool

    /// The card's field while the card is open; the row's or page's while it is closed.
    func isMeant(for placement: ChatPlacement) -> Bool {
        isRequested && placement.isInCard == isCardOpen
    }
}

// MARK: - Unavailable

/// The field's shape with a light gray fill and no shadow: the reason in
/// place of the placeholder and, when there is one, the action that fixes it.
private struct UnavailableChatField: View {
    let presentation: ChatFieldPresentation
    let onAction: (ChatFieldAction) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.chatFieldHeight / 2, style: .continuous)
        HStack(spacing: Tokens.spacingSM) {
            // inkSecondary reaches only 3.8:1 at this size; the text carries
            // the reason chat is off, as the drawer's status text does.
            Text(presentation.placeholder)
                .font(.system(size: 13.5))
                .foregroundStyle(.inkSecondaryLegible)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action = presentation.action {
                Button(action.title) { onAction(action.action) }
                    .buttonStyle(ChatInlineButtonStyle())
            }
        }
        .padding(.leading, ChatQuestionField.leadingPadding)
        .padding(.trailing, ChatQuestionField.buttonInset)
        .padding(.vertical, ChatQuestionField.buttonInset)
        .frame(minHeight: Tokens.chatFieldHeight)
        .background { shape.fill(Tokens.neutralChip) }
        .overlay { shape.strokeBorder(Tokens.cardStroke, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}
