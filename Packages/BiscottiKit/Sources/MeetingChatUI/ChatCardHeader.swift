import DesignSystem
import MeetingChat
import SwiftUI

/// The card's header, 43.5 pt like the drawer's: History at the left, New
/// chat and close at the right. Deleting the open thread asks first.
struct ChatCardHeader: View {
    static let height: CGFloat = 43.5

    let state: MeetingChatState
    let service: MeetingChatService
    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(spacing: Tokens.spacingSM) {
            ChatHistoryMenu(
                state: state,
                service: service,
                onNewChat: newChat,
                onDelete: { isConfirmingDelete = true }
            )
            Spacer(minLength: Tokens.spacingSM)
            ChatHeaderIconButton(systemImage: "square.and.pencil", label: "New chat", help: "New chat (⌘N)", action: newChat)
                .keyboardShortcut("n")
            ChatHeaderIconButton(systemImage: "minus", label: "Close chat", help: "Close chat (Esc)") {
                state.isCardOpen = false
            }
        }
        .padding(.horizontal, Tokens.spacingMD)
        .alert("Delete this chat?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive, action: deleteOpenThread)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    /// Closes the card; the field in its place reads "Ask about this meeting"
    /// and takes the cursor.
    private func newChat() {
        service.newChat(meetingID: state.meetingID)
        // The field in the card's place takes it once it is shown.
        state.focusRequest = true
    }

    private func deleteOpenThread() {
        guard let threadID = state.openThreadID else { return }
        let meetingID = state.meetingID
        Task { await service.deleteThread(threadID, meetingID: meetingID) }
    }
}

/// The History button: a clock-with-arrow icon and a chevron, with the
/// pressed look while its menu is open. The menu lists the threads, newest
/// first, the open one checked, then New Chat and Delete This Chat….
struct ChatHistoryMenu: View {
    let state: MeetingChatState
    let service: MeetingChatService
    let onNewChat: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let history = ChatHistoryPresentation.make(state: state)
        Menu {
            ForEach(history.items) { item in
                // SwiftUI menus cannot right-align text, so the time is the
                // item's subtitle, as in the live transcript's language menu.
                Toggle(isOn: Binding(
                    get: { item.isOpen },
                    set: { isOn in
                        guard isOn else { return }
                        let meetingID = state.meetingID
                        Task { await service.openThread(item.id, meetingID: meetingID) }
                    }
                )) {
                    Text(item.title)
                    Text(item.time)
                }
            }
            if !history.items.isEmpty {
                Divider()
            }
            Button("New Chat", action: onNewChat)
                .keyboardShortcut("n")
            Button("Delete This Chat…", action: onDelete)
                .disabled(state.openThreadID == nil)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
                // One element for VoiceOver: otherwise the menu gives each
                // image its own "Chat history" menu button.
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.inkSecondary)
            .padding(.horizontal, 6)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(ChatHoverButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Chat history")
        .accessibilityLabel(history.accessibilityLabel)
    }
}
