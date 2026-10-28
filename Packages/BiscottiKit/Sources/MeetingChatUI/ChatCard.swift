import DesignSystem
import MeetingChat
import SwiftUI

/// The card footer's space above and below the field and the toggle.
private let footerVerticalPadding: CGFloat = 6
/// The space between the recording card's bottom edge and the footnote under it.
private let footnoteGap: CGFloat = 3

/// The chat card, in the transcript drawer's card style: the header with
/// History, New chat and close; the open thread; and the footer with the
/// question field. The host gives it its frame.
///
/// On the recording screen (`.recordingCard`) the footer holds
/// `footerLeading` (the live transcript's toggle) and then the field, and the
/// footnote sits just under the card. On the meeting page (`.meetingCard`)
/// the footer holds the field with the footnote under it.
public struct ChatCard<Leading: View>: View {
    let state: MeetingChatState
    let service: MeetingChatService
    let placement: ChatPlacement
    let focus: FocusState<Bool>.Binding
    let onTime: (TimeInterval) -> Void
    let onAction: (ChatFieldAction) -> Void
    let footerLeading: Leading

    /// - Parameters:
    ///   - placement: `.recordingCard` or `.meetingCard`.
    ///   - focus: The question field's focus, shared with the field the host
    ///     shows while the card is closed. The cursor moves between the two
    ///     through `MeetingChatState.focusRequest`.
    ///   - onTime: A time chip was clicked: the second it cites.
    ///   - onAction: The field's actions outside the chat.
    ///   - footerLeading: The live transcript's toggle on the recording screen.
    public init(
        state: MeetingChatState,
        service: MeetingChatService,
        placement: ChatPlacement,
        focus: FocusState<Bool>.Binding,
        onTime: @escaping (TimeInterval) -> Void,
        onAction: @escaping (ChatFieldAction) -> Void,
        @ViewBuilder footerLeading: () -> Leading
    ) {
        self.state = state
        self.service = service
        self.placement = placement
        self.focus = focus
        self.onTime = onTime
        self.onAction = onAction
        self.footerLeading = footerLeading()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.drawerRadius, style: .continuous)
        VStack(spacing: 0) {
            ChatCardHeader(state: state, service: service)
                .frame(height: ChatCardHeader.height)
            Tokens.hairline.frame(height: 0.5)
            ChatMessageList(state: state, service: service, onTime: onTime)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(Tokens.cardFill)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Tokens.cardStroke, lineWidth: 0.5) }
        .shadow(color: Tokens.cardShadow, radius: 16, y: 6)
        .shadow(color: Tokens.cardShadow, radius: 2, y: 1)
        .overlay(alignment: .bottom) {
            if placement == .recordingCard {
                // In the window's bottom margin, under the card.
                ChatFootnote()
                    .alignmentGuide(.bottom) { $0[.top] - footnoteGap }
            }
        }
        // Esc with the focus elsewhere in the card; the field handles its own.
        .onExitCommand {
            if state.isAnswering {
                service.stop()
            } else {
                state.isCardOpen = false
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        let field = ChatQuestionField(state: state, service: service, placement: placement, focus: focus, onAction: onAction)
        switch placement {
        case .recordingCard, .recordingRow:
            HStack(spacing: Tokens.spacingSM + Tokens.spacingXS) {
                footerLeading
                field
            }
            // The toggle's inset from the card's leading edge, as in the drawer.
            .padding(.leading, 12)
            .padding(.trailing, Tokens.spacingSM + 2)
            .padding(.vertical, footerVerticalPadding)
        case .meetingCard, .meetingPage:
            VStack(spacing: Tokens.spacingXS + 2) {
                field
                ChatFootnote()
            }
            .padding(.horizontal, Tokens.spacingSM + 2)
            .padding(.top, footerVerticalPadding)
            .padding(.bottom, Tokens.spacingSM)
        }
    }
}

public extension ChatCard where Leading == EmptyView {
    /// A card with nothing before the field: the meeting page's.
    init(
        state: MeetingChatState,
        service: MeetingChatService,
        placement: ChatPlacement,
        focus: FocusState<Bool>.Binding,
        onTime: @escaping (TimeInterval) -> Void,
        onAction: @escaping (ChatFieldAction) -> Void
    ) {
        self.init(state: state, service: service, placement: placement, focus: focus, onTime: onTime, onAction: onAction) {
            EmptyView()
        }
    }
}

/// "Answers come from the on-device AI and can be wrong.", centered under
/// the field whenever the card is open.
public struct ChatFootnote: View {
    public static let text = "Answers come from the on-device AI and can be wrong."

    public init() {}

    public var body: some View {
        Text(Self.text)
            .font(.system(size: 10.5))
            .foregroundStyle(.inkTertiary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }
}
