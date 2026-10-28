import DataStore
import Foundation
import Observation

/// Whether a meeting's question field can send.
public enum ChatAvailability: Equatable, Sendable {
    case available
    /// "Download the AI model to ask about meetings"
    case noModel
    /// "Turn on the live transcript to ask during the meeting"
    case liveTranscriptOff
    /// "This meeting has no transcript to ask about"
    case noTranscript
    /// "Ask once the transcript is ready"
    case transcribing
    /// "Answering in another meeting…"
    case answeringElsewhere
}

/// What an answer being written is doing.
public enum ChatAnswerStatus: Equatable, Sendable {
    /// "Loading the AI model…"
    case loadingModel
    /// "Waiting for the summary to finish…"
    case waitingForSummary
    /// "Answers when the recording stops"
    case waitingForRecordingToEnd
    /// "Thinking…"
    case thinking
    /// Words are arriving.
    case streaming
}

/// One question or answer as the chat card shows it.
public struct ChatMessageView: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case complete
        case stopped
        /// A question whose answer never ended: the app quit, or a waiting question was stopped.
        case interrupted
        case failed(String)
        case streaming(ChatAnswerStatus)
    }

    /// The stored message's ID, or a temporary ID while an answer is written.
    public internal(set) var id: UUID
    /// For answers, the question they answer (for Retry); for questions, their own ID.
    public let questionID: UUID
    public let role: ChatRole
    public internal(set) var text: String
    /// Answers only, from `ChatAnswerParser`.
    public internal(set) var blocks: [ChatBlock]
    public internal(set) var state: State
    /// "Based on the transcript through 0:46" or "Based on the draft transcript".
    public internal(set) var footer: String?
    /// The store could not save the answer.
    public internal(set) var isUnsaved: Bool

    public init(
        id: UUID,
        questionID: UUID,
        role: ChatRole,
        text: String,
        blocks: [ChatBlock] = [],
        state: State = .complete,
        footer: String? = nil,
        isUnsaved: Bool = false
    ) {
        self.id = id
        self.questionID = questionID
        self.role = role
        self.text = text
        self.blocks = blocks
        self.state = state
        self.footer = footer
        self.isUnsaved = isUnsaved
    }
}

/// One meeting's chat, observed by its field and card.
@MainActor @Observable
public final class MeetingChatState {
    public let meetingID: UUID
    /// The meeting's threads, newest first.
    public internal(set) var threads: [ChatThreadSummary] = []
    public internal(set) var openThreadID: UUID?
    /// The open thread, oldest first.
    public internal(set) var messages: [ChatMessageView] = []
    /// An answer is being written, or waits, in this meeting.
    public internal(set) var isAnswering = false
    public var isCardOpen = false
    /// The field's text, kept per meeting.
    public var draft = ""

    private let availabilityOf: @MainActor (UUID) -> ChatAvailability

    init(meetingID: UUID, availability: @escaping @MainActor (UUID) -> ChatAvailability) {
        self.meetingID = meetingID
        availabilityOf = availability
    }

    /// Worked out on each read from observable state (the model, the recording,
    /// the live setting, transcription jobs, drafts and the answering meeting),
    /// so a view that reads it redraws when any of them changes.
    public var availability: ChatAvailability {
        availabilityOf(meetingID)
    }
}
