import DataStore
import DesignSystem
import MeetingChat
import SwiftUI

/// The open thread, anchored to the bottom so a short thread sits just above
/// the field. It follows new text while it is scrolled to the end; once the
/// user scrolls up, it stays put and a round button jumps back to the end.
struct ChatMessageList: View {
    nonisolated static let sidePadding: CGFloat = Tokens.spacingLG
    /// Within this of the end counts as at the end.
    nonisolated static let bottomTolerance: CGFloat = 12

    let state: MeetingChatState
    let service: MeetingChatService
    let onTime: (TimeInterval) -> Void

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isFollowing = true
    @State private var isAtBottom = true
    @State private var contentWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let messages = state.messages
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Self.rows(messages), id: \.message.rowKey) { row in
                    rowView(row.message)
                        .padding(.top, row.spacingAbove)
                }
            }
            .padding(.horizontal, Self.sidePadding)
            .padding(.top, Tokens.spacingMD)
            .padding(.bottom, Tokens.spacingMD)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Self.sidePadding } action: { contentWidth = $0 }
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .onScrollGeometryChange(for: ScrollPlace.self, of: ScrollPlace.init) { old, new in
            isFollowing = new.follows(after: old, wasFollowing: isFollowing)
            isAtBottom = new.isAtBottom
            if new.needsScrollToEnd(after: old, isFollowing: isFollowing) {
                position.scrollTo(edge: .bottom)
            }
        }
        // Another thread from History opens at its newest message, wherever
        // the last one was scrolled to: the scroll view stays the same one.
        .onChange(of: state.openThreadID) {
            isFollowing = true
            position.scrollTo(edge: .bottom)
        }
        .onChange(of: FollowKey(messages)) { old, new in
            // A question just sent always brings the end back into view.
            if new.count > old.count {
                isFollowing = true
            }
            if isFollowing {
                position.scrollTo(edge: .bottom)
            }
        }
        .overlay(alignment: .bottom) {
            if !isFollowing, !isAtBottom {
                jumpToEndButton
            }
        }
    }

    @ViewBuilder
    private func rowView(_ message: ChatMessageView) -> some View {
        switch message.role {
        case .question:
            ChatQuestionBubble(text: message.text, maxWidth: contentWidth > 0 ? contentWidth * 0.72 : .infinity)
        case .answer:
            ChatAnswerView(message: message, state: state, service: service, onTime: onTime)
        }
    }

    struct Row {
        let message: ChatMessageView
        let spacingAbove: CGFloat
    }

    /// An answer starts 16 pt below its question; turns are 26 pt apart.
    nonisolated static func rows(_ messages: [ChatMessageView]) -> [Row] {
        messages.enumerated().map { index, message in
            let spacing: CGFloat = if index == 0 {
                0
            } else {
                message.role == .answer ? Tokens.chatAnswerSpacing : Tokens.chatTurnSpacing
            }
            return Row(message: message, spacingAbove: spacing)
        }
    }

    private var jumpToEndButton: some View {
        Button {
            isFollowing = true
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                position.scrollTo(edge: .bottom)
            }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.inkSecondary)
                .frame(width: Tokens.chatRoundButton, height: Tokens.chatRoundButton)
                .background { Circle().fill(Tokens.cardFill).shadow(color: Tokens.cardShadow, radius: 6, y: 2) }
                .overlay { Circle().strokeBorder(Tokens.cardStroke, lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, Tokens.spacingSM)
        .help("Jump to the newest text")
        .accessibilityLabel("Jump to the newest text")
    }
}

/// Where the list is scrolled, as far as following new text cares.
struct ScrollPlace: Equatable {
    let offset: CGFloat
    let isAtBottom: Bool
    let contentHeight: CGFloat
    let containerHeight: CGFloat

    /// Following stops when the user scrolls up and starts again at the end.
    /// An offset that moves up is the user's, except in the two cases where
    /// the scroll view moves it itself: the content fitted the card (a first
    /// answer sits at the card's bottom, and the next question makes the
    /// content outgrow it), or the card changed height. New text below the
    /// end does not move the offset of a list that already scrolls.
    func follows(after old: ScrollPlace, wasFollowing: Bool) -> Bool {
        if isAtBottom { return true }
        if old.contentHeight <= old.containerHeight || containerHeight != old.containerHeight {
            return wasFollowing
        }
        return offset < old.offset - 1 ? false : wasFollowing
    }

    /// The content or the card changed height and the end left the view
    /// while the list follows, for example a row measured after the last
    /// scroll to the end: scroll to the end again.
    func needsScrollToEnd(after old: ScrollPlace, isFollowing: Bool) -> Bool {
        isFollowing && !isAtBottom && (contentHeight != old.contentHeight || containerHeight != old.containerHeight)
    }
}

extension ScrollPlace {
    init(_ geometry: ScrollGeometry) {
        self.init(
            offset: geometry.contentOffset.y,
            isAtBottom: geometry.visibleRect.maxY >= geometry.contentSize.height - ChatMessageList.bottomTolerance,
            contentHeight: geometry.contentSize.height,
            containerHeight: geometry.containerSize.height
        )
    }
}

/// What changes as an answer is written: a new message, new text, a new state.
private struct FollowKey: Equatable {
    let count: Int
    let lastTextLength: Int
    let lastState: ChatMessageView.State?

    init(_ messages: [ChatMessageView]) {
        count = messages.count
        lastTextLength = messages.last?.text.count ?? 0
        lastState = messages.last?.state
    }
}

/// A row's identity: a question's own ID, or the ID of the question an answer
/// answers. An answer's view ID changes when it is saved; its row stays.
struct ChatRowKey: Hashable {
    let role: ChatRole
    let questionID: UUID
}

extension ChatMessageView {
    var rowKey: ChatRowKey {
        ChatRowKey(role: role, questionID: questionID)
    }
}

/// A question: a right-aligned bubble at most 72% of the list's width,
/// deliberately neither transcript colour.
struct ChatQuestionBubble: View {
    let text: String
    let maxWidth: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.bubbleRadius, style: .continuous)
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background { shape.fill(Tokens.cardFill) }
            .overlay { shape.strokeBorder(Tokens.cardStroke, lineWidth: 1) }
            .frame(maxWidth: maxWidth, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
