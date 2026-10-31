---
status: complete
---

# Component: Chat storage

## Purpose and Scope

Saves each meeting's chat threads and their questions and answers in the existing SwiftData store, and exposes them as Sendable read models, following `DataStore`'s conventions: `@Model` objects never leave the actor, and each feature has its own `public extension DataStore` file.

Not its job: the answer being written (it lives in memory in `MeetingChatService` until it ends), export, search, or the MCP server, which ignore chats in this version.

Files: `DataStore/Models/ChatThread.swift`, `DataStore/Models/ChatMessage.swift`, `DataStore/DataStore+Chat.swift`, and one line each in `Meeting.swift` and `Schema/DataStoreSchemaV1.swift`.

## Models

```swift
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
}

@Model public final class ChatMessage {
    public var id = UUID()
    /// Order within the thread, from 0. Explicit, like TranscriptSegmentRecord.index,
    /// because SwiftData does not keep array order.
    public var index: Int = 0
    public var roleRaw: String = ChatRole.question.rawValue
    public var text: String = ""
    public var createdAt = Date()
    /// Answers only: complete, stopped or failed.
    public var stateRaw: String = ChatMessageState.complete.rawValue
    public var errorMessage: String?
    /// Answers only: what the answer was based on.
    public var basisKindRaw: String?          // "live", "draft" or "transcript"
    public var basisThrough: Double?          // "live": seconds on the recording timeline
    public var basisTranscriptID: UUID?       // "transcript": the TranscriptRecord used
    public var thread: ChatThread?
}
```

In `Meeting`:

```swift
@Relationship(deleteRule: .cascade, inverse: \ChatThread.meeting)
public var chatThreads: [ChatThread] = []
```

`DataStoreSchemaV1.models` gains `ChatThread.self` and `ChatMessage.self`. Per `DataStoreMigrationPlan`'s rule, new models and a new relationship with a default are additive and need no migration stage; a test proves it on a store written by the current release (see the test plan).

## Read Models and Methods

```swift
public enum ChatRole: String, Sendable, Codable { case question, answer }
public enum ChatMessageState: String, Sendable, Codable { case complete, stopped, failed }

public enum ChatBasis: Sendable, Equatable {
    case live(through: TimeInterval)
    case draft
    case transcript(id: UUID)
}

public struct ChatThreadSummary: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let meetingID: UUID
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
}

public struct ChatMessageData: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let index: Int
    public let role: ChatRole
    public let text: String
    public let createdAt: Date
    public let state: ChatMessageState      // .complete for questions
    public let errorMessage: String?
    public let basis: ChatBasis?            // nil for questions
}

public struct ChatThreadData: Sendable, Equatable {
    public let summary: ChatThreadSummary
    public let messages: [ChatMessageData]  // by index
}

public extension DataStore {
    /// Newest first (by updatedAt). Empty for an unknown meeting.
    func chatThreads(meetingID: UUID) throws -> [ChatThreadSummary]
    /// Nil if the thread does not exist.
    func chatThread(id: UUID) throws -> ChatThreadData?

    /// Creates a thread and its first question in one save. Returns (threadID, questionID).
    /// - Throws: `DataStoreError.notFound(meetingID)`.
    func createChatThread(meetingID: UUID, firstQuestion: String) throws -> (thread: UUID, question: UUID)

    /// Appends a question at the next index and bumps updatedAt.
    /// - Throws: `DataStoreError.notFound(threadID)`.
    func appendChatQuestion(threadID: UUID, text: String) throws -> UUID

    /// Saves the answer to the question at `questionID`: inserts it right after the question,
    /// or replaces the answer already there (a retry). Bumps updatedAt.
    /// - Throws: `DataStoreError.notFound` for an unknown question.
    func saveChatAnswer(
        questionID: UUID, text: String, state: ChatMessageState,
        errorMessage: String?, basis: ChatBasis
    ) throws -> UUID

    /// Deletes the thread and its messages.
    /// - Throws: `DataStoreError.notFound(threadID)`.
    func deleteChatThread(id: UUID) throws
}
```

Mapping is in one private `mapChatThread(_:)` that sorts messages by `index` and turns the raw strings into enums; unknown raw values (from a future version) map to `.question`/`.complete`/`nil` rather than failing.

**Titles** are made in `DataStore` from the first question: collapse whitespace, cut at the last word boundary within 60 characters, and add "…" if anything was cut.

**An unanswered question** (the app quit mid-answer) is simply a last message with role `.question`. The chat service shows it as "Interrupted" with Retry; nothing extra is stored.

## Dependencies

- Uses the existing `DataStore` actor, `DataStoreError`, `save()` and `meeting(id:)`.
- Used by `MeetingChatService`.

## Test Plan (`DataStoreTests/ChatStoreTests.swift`, in-memory stores unless noted)

- `createThreadSavesFirstQuestion`: one thread with one question at index 0, title from the question.
- `titleCutsAtWordBoundary`: a 90-character question gives a title of at most 61 characters ending in "…", cut between words; a short one is kept whole.
- `appendKeepsOrder`: questions and answers come back in index order regardless of insertion timing.
- `saveAnswerInsertsAfterQuestion`: answering the newest question gives it the next index; `updatedAt` moves forward.
- `retryReplacesAnswer`: saving an answer to a question that already has one replaces it and keeps the message count.
- `basisRoundTrips`: `.live(through:)`, `.draft` and `.transcript(id:)` each come back unchanged.
- `threadsNewestFirst`: `chatThreads(meetingID:)` orders by `updatedAt`, descending.
- `deleteThreadRemovesMessages`: after `deleteChatThread`, the thread and its messages are gone and other threads remain.
- `deletingMeetingDeletesChats`: `delete(meetingID:)` removes the meeting's threads and messages.
- `unknownIDsThrowNotFound`: each write with an unknown ID throws `DataStoreError.notFound`.
- `unknownRawValuesDegrade`: a message with an unknown `stateRaw` maps to `.complete`.
- `opensPreChatStore` (on disk): opens a copy of `Tests/DataStoreTests/Fixtures/PreChatStore/` — a store written by the code before this change, generated and committed in the first storage phase — reads its meetings and transcripts unchanged, and creates a chat thread in it.
