import Foundation

/// The transcript a chat answer was based on.
public enum ChatBasis: Sendable, Equatable {
    /// The live transcript, through this time on the recording timeline, in seconds.
    case live(through: TimeInterval)
    /// The stopped recording's draft transcript.
    case draft
    /// A saved transcript version.
    case transcript(id: UUID)
}
