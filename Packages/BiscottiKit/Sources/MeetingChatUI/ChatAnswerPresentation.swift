import Foundation
import MeetingChat

/// The row under a finished answer: Copy, what happened to it, what it was
/// based on, and Retry.
struct ChatAnswerFooterPresentation: Equatable {
    static let stoppedText = "Stopped"
    static let interruptedText = "Interrupted"
    static let unsavedText = "Couldn't save this answer"

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
            break
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

/// Texts for an answer being written, and for VoiceOver.
enum ChatAnswerPresentation {
    /// The status line before the first word; nil once words arrive.
    static func statusText(_ status: ChatAnswerStatus) -> String? {
        switch status {
        case .loadingModel: "Loading the AI model…"
        case .waitingForSummary: "Waiting for the summary to finish…"
        case .waitingForRecordingToEnd: "Answers when the recording stops"
        case .thinking: "Thinking…"
        case .streaming: nil
        }
    }

    /// The status line for a message, if it shows one instead of text.
    static func statusText(for message: ChatMessageView) -> String? {
        guard case let .streaming(status) = message.state, message.text.isEmpty else { return nil }
        return statusText(status)
    }

    /// What VoiceOver announces once an answer ends: the answer, not word by word.
    static func finishedAnnouncement(_ message: ChatMessageView) -> String? {
        switch message.state {
        case .streaming: nil
        case .complete: ChatAnswerCopy.plainText(message.blocks)
        case .stopped: "Answer stopped"
        case .interrupted: "Answer interrupted"
        case let .failed(error): error
        }
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
