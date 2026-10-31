import DataStore
import Foundation
import MeetingChat
import Synchronization

/// A chat store over a real `DataStore` that a test can make fail an answer
/// save, which an in-memory store never does, or hold a question write.
public final class TestChatStore: ChatStoring {
    public struct SaveFailure: Error {}

    private struct State {
        var failsSaves = false
        var holdsQuestionWrites = false
        var heldQuestionWrites: [CheckedContinuation<Void, Never>] = []
    }

    public let store: DataStore
    private let state = Mutex(State())

    public init(_ store: DataStore) {
        self.store = store
    }

    /// Every `saveChatAnswer` throws `SaveFailure` while this is true.
    public var failsSaves: Bool {
        get { state.withLock { $0.failsSaves } }
        set { state.withLock { $0.failsSaves = newValue } }
    }

    /// While true, `appendChatQuestion` waits for `releaseQuestionWrites()`.
    public var holdsQuestionWrites: Bool {
        get { state.withLock { $0.holdsQuestionWrites } }
        set { state.withLock { $0.holdsQuestionWrites = newValue } }
    }

    /// Whether a question write is waiting.
    public var isHoldingQuestionWrite: Bool {
        state.withLock { !$0.heldQuestionWrites.isEmpty }
    }

    /// Stops holding question writes and lets the waiting ones run.
    public func releaseQuestionWrites() {
        let held = state.withLock { state in
            state.holdsQuestionWrites = false
            defer { state.heldQuestionWrites = [] }
            return state.heldQuestionWrites
        }
        for write in held {
            write.resume()
        }
    }

    public func meetingDetail(id: UUID) async throws -> MeetingDetailData? {
        try await store.meetingDetail(id: id)
    }

    public func chatThreads(meetingID: UUID) async throws -> [ChatThreadSummary] {
        try await store.chatThreads(meetingID: meetingID)
    }

    public func chatThread(id: UUID) async throws -> ChatThreadData? {
        try await store.chatThread(id: id)
    }

    public func createChatThread(meetingID: UUID, firstQuestion: String) async throws -> (thread: UUID, question: UUID) {
        try await store.createChatThread(meetingID: meetingID, firstQuestion: firstQuestion)
    }

    public func appendChatQuestion(threadID: UUID, text: String) async throws -> UUID {
        await withCheckedContinuation { continuation in
            let holds = state.withLock { state in
                if state.holdsQuestionWrites {
                    state.heldQuestionWrites.append(continuation)
                }
                return state.holdsQuestionWrites
            }
            if !holds {
                continuation.resume()
            }
        }
        return try await store.appendChatQuestion(threadID: threadID, text: text)
    }

    // swiftlint:disable:next function_parameter_count
    public func saveChatAnswer(
        questionID: UUID,
        text: String,
        state: ChatMessageState,
        errorMessage: String?,
        basis: ChatBasis?,
        citedTimes: [TimeInterval]
    ) async throws -> UUID {
        if failsSaves {
            throw SaveFailure()
        }
        return try await store.saveChatAnswer(
            questionID: questionID, text: text, state: state,
            errorMessage: errorMessage, basis: basis, citedTimes: citedTimes
        )
    }

    public func deleteChatThread(id: UUID) async throws {
        try await store.deleteChatThread(id: id)
    }
}
