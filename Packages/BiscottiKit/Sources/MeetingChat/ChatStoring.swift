import DataStore
import Foundation

/// The store calls chat makes. `DataStore` in the app; a test store can wrap it
/// to make a write fail, which an in-memory `DataStore` never does.
public protocol ChatStoring: Sendable {
    func meetingDetail(id: UUID) async throws -> MeetingDetailData?
    func chatThreads(meetingID: UUID) async throws -> [ChatThreadSummary]
    func chatThread(id: UUID) async throws -> ChatThreadData?
    func createChatThread(meetingID: UUID, firstQuestion: String) async throws -> (thread: UUID, question: UUID)
    func appendChatQuestion(threadID: UUID, text: String) async throws -> UUID
    // swiftlint:disable:next function_parameter_count
    func saveChatAnswer(
        questionID: UUID,
        text: String,
        state: ChatMessageState,
        errorMessage: String?,
        basis: ChatBasis?,
        citedTimes: [TimeInterval]
    ) async throws -> UUID
    func deleteChatThread(id: UUID) async throws
}

extension DataStore: ChatStoring {}
