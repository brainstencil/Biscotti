import DesignSystem
import MeetingChat
import MeetingChatUI
import SwiftUI

/// The bottom of the recording screen, one slot (`RecordingBottomSlot`): the
/// live transcript's toggle with the chat's question field beside it, the
/// live transcript drawer growing up from the toggle, or the chat card in
/// the drawer's place. The toggle never moves; the open drawer's footer
/// reserves its slot, and the chat card's footer holds it.
///
/// Chosen in UI review (25 October 2026): the drawer is wider than the notes
/// column, so bubbles are wide and short, and opening it moves the notes up
/// so the note field sits just above it, while the column's top, with Stop &
/// Save, stays in view (see `openLayout`). In the second review the user
/// added a height handle: the drawer's top edge drags to a height that is
/// remembered across meetings. The chat card shares that height.
struct LiveTranscriptOverlay: View {
    /// The notes column's width limit.
    static let columnMaxWidth: CGFloat = 600
    /// The drawer's width limit.
    static let drawerMaxWidth: CGFloat = 880
    /// The space between the drawer and the window's sides and bottom.
    static let gutter: CGFloat = Tokens.spacingMD
    /// The space between the note field and the open drawer.
    static let noteFieldGap: CGFloat = Tokens.spacingMD
    /// The space kept above the column's top while the drawer is open.
    static let headerMargin: CGFloat = Tokens.spacingMD
    static let minimumDrawerHeight: CGFloat = 240
    /// How far one VoiceOver adjustment changes the height.
    static let heightStep: CGFloat = 40
    /// The space between the toggle and the question field beside it.
    static let rowFieldSpacing: CGFloat = 12
    /// The narrowest the question field beside the toggle gets.
    static let minimumRowFieldWidth: CGFloat = 200

    /// The open drawer's height and how far the notes scroll up for it.
    struct OpenLayout: Equatable {
        var drawerHeight: CGFloat
        var notesOffset: CGFloat
    }

    let viewModel: RecordingViewModel
    let drawerWidth: CGFloat
    let drawerHeight: CGFloat
    /// The tallest the drawer may be dragged to.
    let maximumHeight: CGFloat
    /// The notes column's trailing edge, from this overlay's leading edge:
    /// the question field beside the toggle reaches it.
    let notesColumnTrailing: CGFloat
    /// The height while the top edge is being dragged, nil otherwise.
    @Binding var dragHeight: CGFloat?
    /// The toggle's row's height, measured: the notes scroll clear of it.
    @Binding var rowHeight: CGFloat
    /// The focus of the question field beside the toggle.
    let rowFieldFocus: FocusState<Bool>.Binding
    /// The focus of the card's question field.
    let cardFieldFocus: FocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let slot = viewModel.bottomSlot
        let chat = viewModel.chat
        ZStack(alignment: .bottomLeading) {
            if let chat, Self.keepsChatCard(slot: slot, openedFromChat: viewModel.transcriptOpenedFromChat) {
                chatCard(chat, isShown: slot == .chat)
            }
            if slot == .transcript {
                LiveTranscriptDrawer(viewModel: viewModel)
                    .frame(height: drawerHeight)
                    .overlay(alignment: .top) { resizeHandle(label: "Transcript height") }
                    .transition(cardTransition)
            }
            if slot != .chat {
                bottomRow(chat, slot: slot)
            }
        }
        .frame(width: drawerWidth, alignment: .bottomLeading)
        .padding(.bottom, Self.gutter)
        .animation(Self.motion(reduceMotion: reduceMotion), value: slot)
    }

    /// The toggle where the open drawer's footer holds it, and while the
    /// drawer is closed, the question field beside it, centred on it.
    private func bottomRow(_ chat: MeetingChatState?, slot: RecordingBottomSlot) -> some View {
        let showsToggle = viewModel.showsLiveTranscript
        return HStack(alignment: .bottom, spacing: Self.rowFieldSpacing) {
            if showsToggle {
                LiveToggleButton(viewModel: viewModel)
            }
            if slot == .collapsed, let chat {
                ChatQuestionField(
                    state: chat,
                    service: viewModel.chatService,
                    placement: .recordingRow,
                    focus: rowFieldFocus,
                    onAction: { viewModel.chatAction($0) }
                )
                .frame(width: Self.rowFieldWidth(notesColumnTrailing: notesColumnTrailing, showsToggle: showsToggle))
                .padding(.bottom, (LiveToggleButton.size - Tokens.chatFieldHeight) / 2)
            }
        }
        .padding(.leading, LiveTranscriptDrawer.outset)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
    }

    /// The chat card in the drawer's frame, with the bare toggle in its
    /// footer. While the drawer shows after one of the card's times, the card
    /// stays under it, hidden and inert, so "Back to chat" finds its list
    /// scrolled where it was: the list keeps that in its own state.
    private func chatCard(_ chat: MeetingChatState, isShown: Bool) -> some View {
        ChatCard(
            state: chat,
            service: viewModel.chatService,
            placement: .recordingCard,
            focus: cardFieldFocus,
            onTime: { viewModel.showTranscript(at: $0) },
            onAction: { viewModel.chatAction($0) },
            footerLeading: {
                if viewModel.showsLiveTranscript {
                    LiveToggleButton(viewModel: viewModel, isInCard: true)
                }
            }
        )
        .frame(height: drawerHeight)
        .overlay(alignment: .top) {
            if isShown {
                resizeHandle(label: "Chat height")
            }
        }
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .disabled(!isShown)
        .accessibilityHidden(!isShown)
        .transition(cardTransition)
    }

    /// The drawer's and the chat card's shared height.
    private func resizeHandle(label: String) -> some View {
        TopEdgeResizeHandle(
            label: label,
            height: drawerHeight,
            range: Self.minimumDrawerHeight ... max(Self.minimumDrawerHeight, maximumHeight),
            step: Self.heightStep,
            dragHeight: $dragHeight,
            onSave: { viewModel.setLiveDrawerHeight($0) },
            onReset: { viewModel.resetLiveDrawerHeight() }
        )
    }

    /// The card shows in the chat slot, and stays, hidden, under a drawer
    /// that one of its times opened.
    static func keepsChatCard(slot: RecordingBottomSlot, openedFromChat: Bool) -> Bool {
        slot == .chat || (slot == .transcript && openedFromChat)
    }

    /// The question field beside the toggle: from 12 pt right of the toggle
    /// (or from the toggle's place, while there is none) to the notes
    /// column's trailing edge, at least `minimumRowFieldWidth`.
    static func rowFieldWidth(notesColumnTrailing: CGFloat, showsToggle: Bool) -> CGFloat {
        let leading = LiveTranscriptDrawer.outset + (showsToggle ? LiveToggleButton.size + rowFieldSpacing : 0)
        return max(minimumRowFieldWidth, notesColumnTrailing - leading)
    }

    /// Scales and fades from the toggle; a cross-fade with Reduce Motion.
    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.2, anchor: .bottomLeading).combined(with: .opacity)
    }

    /// The drawer's motion, which the notes follow when they move.
    static func motion(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.25)
    }

    /// Most of the window's width, at most 880 pt.
    static func drawerWidth(forAvailableWidth width: CGFloat) -> CGFloat {
        max(0, min(width - 2 * gutter, drawerMaxWidth))
    }

    /// 45% of the detail area, at least 240 pt and at most 520 pt.
    static func drawerHeight(forAvailableHeight height: CGFloat) -> CGFloat {
        min(max(height * 0.45, minimumDrawerHeight), 520)
    }

    /// The open drawer's height and the notes' scroll, so the column's top
    /// (the status row with Stop & Save, or the auto-stop card above it)
    /// stays in view. The drawer shrinks, to no less than 240 pt, until the
    /// column's top, the note field and the drawer fit; if they still do
    /// not, the column's top stays in view and the drawer covers the note field.
    ///
    /// - Parameters:
    ///   - headerTop: The top of the column's first row in the scroll
    ///     content, unscrolled.
    ///   - noteFieldBottom: The note field's bottom edge there.
    ///
    /// A height the user chose (`preferredHeight`) is kept between 240 pt
    /// and `maximumDrawerHeight`, which keeps the column's first rows (the
    /// status row with Stop & Save, and the auto-stop card) in view; a tall
    /// one may cover the note field.
    ///
    /// - Parameters:
    ///   - firstRowsHeight: From the column's top to the status row's bottom.
    static func openLayout(
        viewportHeight: CGFloat,
        headerTop: CGFloat,
        noteFieldBottom: CGFloat,
        firstRowsHeight: CGFloat = 0,
        preferredHeight: CGFloat? = nil
    ) -> OpenLayout {
        let height: CGFloat
        if let preferredHeight {
            height = clampedHeight(preferredHeight, viewportHeight: viewportHeight, firstRowsHeight: firstRowsHeight)
        } else {
            let header = max(0, noteFieldBottom - headerTop)
            let room = viewportHeight - headerMargin - header - noteFieldGap - gutter
            height = max(minimumDrawerHeight, min(drawerHeight(forAvailableHeight: viewportHeight), room))
        }
        let offset = notesOffset(noteFieldBottom: noteFieldBottom, viewportHeight: viewportHeight, drawerHeight: height)
        return OpenLayout(drawerHeight: height, notesOffset: min(offset, max(0, headerTop - headerMargin)))
    }

    /// The tallest drawer that leaves the column's first rows in view, with
    /// the column scrolled up to `headerMargin` from the top: never less
    /// than 240 pt.
    static func maximumDrawerHeight(viewportHeight: CGFloat, firstRowsHeight: CGFloat) -> CGFloat {
        max(minimumDrawerHeight, viewportHeight - gutter - noteFieldGap - firstRowsHeight - headerMargin)
    }

    static func clampedHeight(_ height: CGFloat, viewportHeight: CGFloat, firstRowsHeight: CGFloat) -> CGFloat {
        min(max(height, minimumDrawerHeight), maximumDrawerHeight(viewportHeight: viewportHeight, firstRowsHeight: firstRowsHeight))
    }

    /// The notes' bottom scroll margin, so the last note can scroll clear of
    /// the drawer, the chat card, or the toggle's row, which grows with the
    /// question field beside it. Nil: nothing shows.
    static func notesBottomInset(slot: RecordingBottomSlot?, drawerHeight: CGFloat, rowHeight: CGFloat) -> CGFloat {
        switch slot {
        case nil: 0
        case .collapsed: max(LiveToggleButton.size, rowHeight) + gutter
        case .chat, .transcript: drawerHeight + gutter
        }
    }

    /// How far the notes scroll up while the drawer is open, so the note
    /// field's bottom sits `noteFieldGap` above the drawer; the header
    /// scrolls up with it. Zero when the note field already sits higher.
    ///
    /// - Parameter noteFieldBottom: The note field's bottom edge in the
    ///   scroll content, unscrolled.
    static func notesOffset(noteFieldBottom: CGFloat, viewportHeight: CGFloat, drawerHeight: CGFloat) -> CGFloat {
        let drawerTop = viewportHeight - gutter - drawerHeight
        return max(0, noteFieldBottom - (drawerTop - noteFieldGap))
    }
}
