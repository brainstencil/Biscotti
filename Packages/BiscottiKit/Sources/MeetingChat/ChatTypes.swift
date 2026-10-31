import DataStore
import Foundation
import LiveTranscriptModel
import LocalLLM

/// The transcript a question is answered from.
public enum ChatTranscript: Sendable {
    /// A recording in progress: its live transcript, with the unsettled tail.
    case live(LiveTranscriptSnapshot)
    /// A stopped recording whose final transcript is not ready yet.
    case draft(LiveTranscriptSnapshot)
    /// The meeting's preferred transcript.
    case saved(TranscriptData)

    var isLive: Bool {
        if case .live = self { true } else { false }
    }

    /// What an answer from this transcript is based on.
    public var basis: ChatBasis {
        switch self {
        case let .live(snapshot): .live(through: snapshot.transcribedThrough)
        case .draft: .draft
        case let .saved(data): .transcript(id: data.id)
        }
    }
}

/// Everything about a meeting that the model is given.
public struct ChatMeetingRecord: Sendable {
    public var title: String
    public var date: Date?
    /// Display names from the calendar snapshot.
    public var invitees: [String]
    public var notes: String
    public var transcript: ChatTranscript

    public init(title: String, date: Date?, invitees: [String] = [], notes: String = "", transcript: ChatTranscript) {
        self.title = title
        self.date = date
        self.invitees = invitees
        self.notes = notes
        self.transcript = transcript
    }
}

/// An earlier question in the thread and its answer.
public struct ChatTurn: Sendable, Equatable {
    public var question: String
    /// Complete or stopped answers only.
    public var answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// One timestamped line of transcript evidence.
public struct ChatEvidenceLine: Sendable, Equatable {
    /// Seconds on the recording timeline.
    public var start: TimeInterval
    /// Empty for a live row from the one-track fallback, which names no speaker.
    public var speaker: String
    /// Settled text.
    public var text: String
    /// The live tail, which may still change. May be empty.
    public var unsettled: String

    public init(start: TimeInterval, speaker: String, text: String, unsettled: String = "") {
        self.start = start
        self.speaker = speaker
        self.text = text
        self.unsettled = unsettled
    }
}

/// The messages for one answer, and what the answer is checked against.
public struct ChatPrompt: Sendable {
    public let messages: [LLMMessage]
    public let contextSize: Int
    /// The messages' size in tokens, as the model's tokenizer counted it.
    public let promptTokens: Int
    public let options: GenerationOptions
    /// Starts of the lines given, ascending.
    public let evidenceTimes: [TimeInterval]
    /// True when selection left parts of the transcript out.
    public let isPartial: Bool
    public let basis: ChatBasis
}

public enum ChatPromptError: Error, Equatable, Sendable {
    /// Even the smallest selection of the transcript does not fit the context.
    case tooLong
}
