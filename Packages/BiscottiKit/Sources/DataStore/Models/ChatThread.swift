import Foundation
import SwiftData

// MARK: - ChatThread

/// One conversation about a meeting: its questions and answers, in `index` order.
/// Cascade-deleted with the meeting.
@Model public final class ChatThread {
    public var id = UUID()
    /// The first question, cut to 60 characters at a word boundary with "…".
    public var title: String = ""
    public var createdAt = Date()
    /// The time of the newest message; orders the History menu.
    public var updatedAt = Date()

    public var meeting: Meeting?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.thread)
    public var messages: [ChatMessage] = []

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        updatedAt = createdAt
    }
}
