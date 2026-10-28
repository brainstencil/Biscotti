import Foundation
import SwiftData

// MARK: - ChatRole

/// Who a chat message is from: the user's question or the AI's answer.
public enum ChatRole: String, Sendable, Codable {
    case question
    case answer
}

// MARK: - ChatMessageState

/// How an answer ended. Questions are always `.complete`.
public enum ChatMessageState: String, Sendable, Codable {
    case complete
    case stopped
    case failed
}

// MARK: - ChatMessage

/// One question or answer in a `ChatThread`.
///
/// Enums are stored as raw strings so that a value written by a later version
/// reads back as a default instead of failing; the typed accessors below do
/// both directions of that conversion.
@Model public final class ChatMessage {
    public var id = UUID()
    /// Order within the thread, from 0. Explicit, like `TranscriptSegmentRecord.index`,
    /// because SwiftData does not keep array order.
    public var index: Int = 0
    /// `ChatRole.rawValue`.
    public var roleRaw: String = ChatRole.question.rawValue
    public var text: String = ""
    public var createdAt = Date()
    /// Answers only: `ChatMessageState.rawValue`.
    public var stateRaw: String = ChatMessageState.complete.rawValue
    public var errorMessage: String?
    /// Answers only: what the answer was based on, as a `BasisKind` raw value.
    public var basisKindRaw: String?
    /// For a "live" basis: seconds on the recording timeline.
    public var basisThrough: Double?
    /// For a "transcript" basis: the `TranscriptRecord` used.
    public var basisTranscriptID: UUID?

    public var thread: ChatThread?

    /// An unknown stored value reads as `.question`.
    @Transient public var role: ChatRole {
        get { ChatRole(rawValue: roleRaw) ?? .question }
        set { roleRaw = newValue.rawValue }
    }

    /// An unknown stored value reads as `.complete`.
    @Transient public var state: ChatMessageState {
        get { ChatMessageState(rawValue: stateRaw) ?? .complete }
        set { stateRaw = newValue.rawValue }
    }

    /// `nil` for questions, and for a basis kind this version does not know.
    @Transient public var basis: ChatBasis? {
        get {
            switch basisKindRaw.flatMap(BasisKind.init(rawValue:)) {
            case .live: basisThrough.map { .live(through: $0) }
            case .draft: .draft
            case .transcript: basisTranscriptID.map { .transcript(id: $0) }
            case nil: nil
            }
        }
        set {
            basisThrough = nil
            basisTranscriptID = nil
            switch newValue {
            case let .live(through):
                basisKindRaw = BasisKind.live.rawValue
                basisThrough = through
            case .draft:
                basisKindRaw = BasisKind.draft.rawValue
            case let .transcript(id):
                basisKindRaw = BasisKind.transcript.rawValue
                basisTranscriptID = id
            case nil:
                basisKindRaw = nil
            }
        }
    }

    public init(
        id: UUID = UUID(),
        index: Int,
        role: ChatRole,
        text: String,
        createdAt: Date = Date(),
        state: ChatMessageState = .complete,
        errorMessage: String? = nil,
        basis: ChatBasis? = nil
    ) {
        self.id = id
        self.index = index
        self.text = text
        self.createdAt = createdAt
        self.errorMessage = errorMessage
        self.role = role
        self.state = state
        self.basis = basis
    }

    /// The stored values of `basisKindRaw`.
    private enum BasisKind: String {
        case live
        case draft
        case transcript
    }
}
