import Foundation
import SwiftData

// MARK: - Read Models

/// A chat thread as the History menu lists it.
public struct ChatThreadSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let meetingID: UUID
    public let title: String
    public let createdAt: Date
    /// The time of the newest message.
    public let updatedAt: Date

    public init(id: UUID, meetingID: UUID, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.meetingID = meetingID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One question or answer, mapped from `ChatMessage`.
public struct ChatMessageData: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let index: Int
    public let role: ChatRole
    public let text: String
    public let createdAt: Date
    /// `.complete` for questions.
    public let state: ChatMessageState
    public let errorMessage: String?
    /// `nil` for questions, and for answers that ended before a prompt was built.
    public let basis: ChatBasis?
    /// Answers only: the evidence times its citations linked to, ascending.
    public let citedTimes: [TimeInterval]

    public init(
        id: UUID,
        index: Int,
        role: ChatRole,
        text: String,
        createdAt: Date,
        state: ChatMessageState = .complete,
        errorMessage: String? = nil,
        basis: ChatBasis? = nil,
        citedTimes: [TimeInterval] = []
    ) {
        self.id = id
        self.index = index
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.state = state
        self.errorMessage = errorMessage
        self.basis = basis
        self.citedTimes = citedTimes
    }
}

/// A chat thread with all its messages.
public struct ChatThreadData: Sendable, Equatable {
    public let summary: ChatThreadSummary
    /// In `index` order.
    public let messages: [ChatMessageData]

    public init(summary: ChatThreadSummary, messages: [ChatMessageData]) {
        self.summary = summary
        self.messages = messages
    }
}

// MARK: - Reads

public extension DataStore {
    /// The meeting's chat threads, newest first (by `updatedAt`). Empty for an unknown meeting.
    func chatThreads(meetingID: UUID) throws -> [ChatThreadSummary] {
        guard let meeting = try meeting(id: meetingID) else { return [] }
        return meeting.chatThreads
            .sorted { ($0.updatedAt, $0.createdAt) > ($1.updatedAt, $1.createdAt) }
            .map { mapChatSummary($0, meetingID: meetingID) }
    }

    /// The thread and its messages, or `nil` if the thread does not exist.
    func chatThread(id: UUID) throws -> ChatThreadData? {
        try chatThreadRecord(id: id).flatMap(mapChatThread)
    }
}

// MARK: - Writes

public extension DataStore {
    /// Creates a thread and its first question in one save.
    /// - Throws: `DataStoreError.notFound(meetingID)`.
    func createChatThread(
        meetingID: UUID, firstQuestion: String
    ) throws -> (thread: UUID, question: UUID) {
        guard let meeting = try meeting(id: meetingID) else {
            throw DataStoreError.notFound(meetingID)
        }
        let now = Date()
        let thread = ChatThread(title: Self.chatTitle(for: firstQuestion), createdAt: now)
        let question = ChatMessage(index: 0, role: .question, text: firstQuestion, createdAt: now)
        context.insert(thread)
        context.insert(question)
        thread.messages.append(question)
        meeting.chatThreads.append(thread)
        try save()
        return (thread.id, question.id)
    }

    /// Appends a question at the next index and bumps the thread's `updatedAt`.
    /// - Throws: `DataStoreError.notFound(threadID)`.
    func appendChatQuestion(threadID: UUID, text: String) throws -> UUID {
        guard let thread = try chatThreadRecord(id: threadID) else {
            throw DataStoreError.notFound(threadID)
        }
        let now = Date()
        let nextIndex = (thread.messages.map(\.index).max() ?? -1) + 1
        let question = ChatMessage(index: nextIndex, role: .question, text: text, createdAt: now)
        context.insert(question)
        thread.messages.append(question)
        thread.updatedAt = now
        try save()
        return question.id
    }

    /// Saves the answer to the question at `questionID` and bumps the thread's `updatedAt`.
    ///
    /// If the message right after the question is an answer, it is replaced (a retry) and
    /// keeps its ID. Otherwise the answer is inserted right after the question, and later
    /// messages move up one index: a question interrupted by a quit, then answered after
    /// newer questions, keeps its answer next to it.
    /// - Parameters:
    ///   - basis: The transcript the answer was based on; nil for an answer that
    ///     ended before its prompt was built.
    ///   - citedTimes: The evidence times its citations linked to.
    /// - Returns: The answer's ID.
    /// - Throws: `DataStoreError.notFound(questionID)` when it is not a question in a thread.
    @discardableResult
    func saveChatAnswer(
        questionID: UUID,
        text: String,
        state: ChatMessageState,
        errorMessage: String?,
        basis: ChatBasis?,
        citedTimes: [TimeInterval] = []
    ) throws -> UUID {
        guard let question = try chatMessageRecord(id: questionID),
              question.role == .question,
              let thread = question.thread
        else {
            throw DataStoreError.notFound(questionID)
        }
        let now = Date()
        let answerIndex = question.index + 1
        let answer: ChatMessage
        if let existing = thread.messages.first(where: { $0.index == answerIndex && $0.role == .answer }) {
            answer = existing
            answer.text = text
            answer.createdAt = now
            answer.state = state
            answer.errorMessage = errorMessage
            answer.basis = basis
            answer.citedTimes = citedTimes
        } else {
            for later in thread.messages where later.index >= answerIndex {
                later.index += 1
            }
            answer = ChatMessage(
                index: answerIndex, role: .answer, text: text, createdAt: now,
                state: state, errorMessage: errorMessage, basis: basis, citedTimes: citedTimes
            )
            context.insert(answer)
            thread.messages.append(answer)
        }
        thread.updatedAt = now
        try save()
        return answer.id
    }

    /// Deletes the thread and its messages.
    /// - Throws: `DataStoreError.notFound(id)`.
    func deleteChatThread(id: UUID) throws {
        guard let thread = try chatThreadRecord(id: id) else {
            throw DataStoreError.notFound(id)
        }
        context.delete(thread)
        try save()
    }
}

// MARK: - Titles

extension DataStore {
    /// The longest title kept before "…" is added.
    static let chatTitleLimit = 60

    /// A thread's title from its first question: whitespace collapsed, then cut at the
    /// last word boundary within `chatTitleLimit` characters, with "…" if anything was cut.
    /// A first word longer than the limit is cut mid-word.
    static func chatTitle(for question: String) -> String {
        let words = question.split(whereSeparator: \.isWhitespace)
        let collapsed = words.joined(separator: " ")
        guard collapsed.count > chatTitleLimit else { return collapsed }

        var title = ""
        for word in words {
            let longer = title.isEmpty ? String(word) : "\(title) \(word)"
            guard longer.count <= chatTitleLimit else { break }
            title = longer
        }
        if title.isEmpty {
            title = String(collapsed.prefix(chatTitleLimit))
        }
        return title + "…"
    }
}

// MARK: - Private

private extension DataStore {
    func chatThreadRecord(id: UUID) throws -> ChatThread? {
        let descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    func chatMessageRecord(id: UUID) throws -> ChatMessage? {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    func mapChatSummary(_ thread: ChatThread, meetingID: UUID) -> ChatThreadSummary {
        ChatThreadSummary(
            id: thread.id,
            meetingID: meetingID,
            title: thread.title,
            createdAt: thread.createdAt,
            updatedAt: thread.updatedAt
        )
    }

    /// `nil` for a thread no longer attached to a meeting.
    func mapChatThread(_ thread: ChatThread) -> ChatThreadData? {
        guard let meetingID = thread.meeting?.id else { return nil }
        let messages = thread.messages
            .sorted { $0.index < $1.index }
            .map { message in
                ChatMessageData(
                    id: message.id,
                    index: message.index,
                    role: message.role,
                    text: message.text,
                    createdAt: message.createdAt,
                    state: message.state,
                    errorMessage: message.errorMessage,
                    basis: message.basis,
                    citedTimes: message.citedTimes
                )
            }
        return ChatThreadData(summary: mapChatSummary(thread, meetingID: meetingID), messages: messages)
    }
}

// MARK: - Test Helpers

public extension DataStore {
    /// Fetches all `ChatThread` rows in the store (for verification in tests).
    func fetchAllChatThreads() throws -> [ChatThread] {
        try context.fetch(FetchDescriptor<ChatThread>())
    }

    /// Fetches all `ChatMessage` rows in the store (for verification in tests).
    func fetchAllChatMessages() throws -> [ChatMessage] {
        try context.fetch(FetchDescriptor<ChatMessage>())
    }
}
