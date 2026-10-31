import Foundation
import MeetingChat

/// The row under a finished answer: Copy, what happened to it, what it was
/// based on, and Retry.
struct ChatAnswerFooterPresentation: Equatable {
    static let stoppedText = "Stopped"
    static let interruptedText = "Interrupted"
    static let unsavedText = "Couldn't save this answer"
    /// A stream that ended with no words: its slot would otherwise be blank.
    static let noAnswerText = "The AI gave no answer"

    /// The answer has text to copy.
    var showsCopy = false
    /// "Stopped" or "Interrupted".
    var note: String?
    /// Shown in `signalRedText`.
    var error: String?
    /// "Based on the transcript through 0:46" or "Based on the draft
    /// transcript". Nil for a saved transcript, and for an answer that ended
    /// before its prompt existed, which has no basis.
    var basis: String?
    var showsRetry = false
    var isUnsaved = false

    /// Nil while the answer is being written.
    static func make(_ message: ChatMessageView) -> Self? {
        var footer = Self(
            showsCopy: !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            basis: message.footer,
            isUnsaved: message.isUnsaved
        )
        switch message.state {
        case .streaming:
            return nil
        case .complete:
            if !footer.showsCopy {
                footer.note = noAnswerText
                footer.showsRetry = true
            }
        case .stopped:
            footer.note = stoppedText
        case .interrupted:
            footer.note = interruptedText
            footer.showsRetry = true
        case let .failed(error):
            footer.error = error
            footer.showsRetry = true
        }
        return footer
    }
}

/// What an answer shows in its place under the question.
enum ChatAnswerSlot: Equatable {
    /// "Loading the AI model…" over the estimated bar (`ChatModelLoadPresentation`).
    case loadingModel
    /// A small spinner and what the answer waits for.
    case status(String)
    /// Typing dots alone: the model reads the prompt before its first word.
    case firstWord
    /// The answer's blocks, with typing dots under them while it streams.
    case text(isStreaming: Bool)
}

/// Texts for an answer being written, and for VoiceOver.
enum ChatAnswerPresentation {
    /// VoiceOver's name for the typing dots before the first word.
    static let firstWordLabel = "Thinking"
    /// VoiceOver's name for the typing dots under words being written.
    static let writingLabel = "Writing"

    /// What the answer shows now. Before its first word, the wait: the load's
    /// bar, a status line, or the dots while the model reads the prompt.
    /// Then its text, with the dots under it until it ends. An answer that
    /// ended has no dots, whatever ended it: its footer says how.
    static func slot(for message: ChatMessageView) -> ChatAnswerSlot {
        guard case let .streaming(status) = message.state else { return .text(isStreaming: false) }
        guard message.text.isEmpty else { return .text(isStreaming: true) }
        return switch status {
        case .loadingModel: .loadingModel
        case .waitingForSummary: .status("Waiting for the summary to finish…")
        case .waitingForRecordingToEnd: .status("Answers when the recording stops")
        case .thinking, .streaming: .firstWord
        }
    }

    /// What VoiceOver announces once an answer ends: the answer, not word by word.
    static func finishedAnnouncement(_ message: ChatMessageView) -> String? {
        switch message.state {
        case .streaming: nil
        case .complete: completeAnnouncement(ChatAnswerCopy.plainText(message.blocks))
        case .stopped: "Answer stopped"
        case .interrupted: "Answer interrupted"
        case let .failed(error): error
        }
    }

    private static func completeAnnouncement(_ text: String) -> String {
        text.isEmpty ? ChatAnswerFooterPresentation.noAnswerText : text
    }
}

/// The text the Copy button puts on the pasteboard.
enum ChatAnswerCopy {
    /// Markdown markers removed, times as plain text, bullets as "• "
    /// (indented two spaces a level), numbered items as "N. ", paragraphs
    /// and headings a blank line apart, list items a line apart.
    static func plainText(_ blocks: [ChatBlock]) -> String {
        var text = ""
        var lastWasListItem = false
        for block in blocks {
            let content = String(block.text.characters)
            let line: String
            let isListItem: Bool
            switch block {
            case .paragraph, .heading:
                line = content
                isListItem = false
            case let .bullet(level, _):
                line = String(repeating: "  ", count: max(0, level - 1)) + "• " + content
                isListItem = true
            case let .numbered(number, _):
                line = "\(number). " + content
                isListItem = true
            }
            if !text.isEmpty {
                text += isListItem && lastWasListItem ? "\n" : "\n\n"
            }
            text += line
            lastWasListItem = isListItem
        }
        return text
    }
}
