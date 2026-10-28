---
status: complete
---

# Phase 1: Chat storage

## Overview

Adds chat threads to the existing SwiftData store, per [chat_store](../components/chat_store.md): two new V1 models, a cascade relationship from `Meeting`, Sendable read models, and the write methods `MeetingChatService` will use in phase 4. Nothing outside `DataStore` changes. The phase also commits a store written by the code before this change and proves the new code opens it without losing data.

## Steps

1. **Pre-chat fixture, before any model change.** With the current code, run a throwaway test that writes an on-disk store to `Packages/BiscottiKit/Tests/DataStoreTests/Fixtures/PreChatStore/`: two meetings ("Roadmap review" with notes, a summary, a tag, a two-segment transcript with words set as preferred; "Hallway chat" with no transcript). Checkpoint the WAL with `sqlite3` so the fixture is one `Biscotti.store` file, drop the search index, and delete the throwaway test. In `Package.swift`, give `DataStoreTests` `resources: [.copy("Fixtures")]`.

2. **`DataStore/ChatBasis.swift`** — the shared file, byte for byte as given in the agent environment (phase 3 creates the same file).

3. **`DataStore/Models/ChatMessage.swift`** — `ChatRole` (`question`, `answer`) and `ChatMessageState` (`complete`, `stopped`, `failed`), both `String, Sendable, Codable`; the `@Model ChatMessage` with the stored fields from the component doc, and `@Transient` typed accessors that keep encoding and decoding in one place:

   ```swift
   @Transient public var role: ChatRole { get set }            // unknown raw -> .question
   @Transient public var state: ChatMessageState { get set }   // unknown raw -> .complete
   @Transient public var basis: ChatBasis? { get set }         // unknown kind -> nil
   public init(id: UUID = UUID(), index: Int, role: ChatRole, text: String,
               createdAt: Date = Date(), state: ChatMessageState = .complete,
               errorMessage: String? = nil, basis: ChatBasis? = nil)
   ```

4. **`DataStore/Models/ChatThread.swift`** — the `@Model ChatThread` with `messages` cascading to `ChatMessage.thread`, and `init(id:title:createdAt:)` that sets `updatedAt = createdAt`.

5. **`Meeting.swift`** — `@Relationship(deleteRule: .cascade, inverse: \ChatThread.meeting) public var chatThreads: [ChatThread] = []`. **`DataStoreSchemaV1.models`** — add `ChatThread.self`, `ChatMessage.self`.

6. **`DataStore/DataStore+Chat.swift`** — the read models `ChatThreadSummary`, `ChatMessageData`, `ChatThreadData` (Sendable, Equatable, public memberwise inits for previews and fakes in later phases) and a `public extension DataStore` with:
   - `chatThreads(meetingID:)` — the meeting's threads, `updatedAt` descending, then `createdAt` descending; `[]` for an unknown meeting.
   - `chatThread(id:)` — `nil` for an unknown thread (or one with no meeting).
   - `createChatThread(meetingID:firstQuestion:)` — inserts the thread and the question at index 0 in one save; title from `chatTitle(for:)`.
   - `appendChatQuestion(threadID:text:)` — index = highest index + 1; bumps `updatedAt`.
   - `saveChatAnswer(questionID:text:state:errorMessage:basis:)` — throws `notFound` unless the ID is a question in a thread. If the message right after the question is an answer, updates it in place (text, state, error, basis, `createdAt` = now) and returns its ID. Otherwise moves every later message up one index and inserts the answer at `question.index + 1` (an interrupted question followed by newer turns keeps its answer next to it). Bumps `updatedAt`.
   - `deleteChatThread(id:)` — deletes the thread; messages cascade.
   - `static func chatTitle(for question: String) -> String` (internal): collapse whitespace, keep whole words up to 60 characters, add "…" if anything was cut; a single word longer than 60 is cut at 60.
   - Private `mapChatSummary(_:meetingID:)` and `mapChatThread(_:)` (messages sorted by index).
   - Test helpers `fetchAllChatThreads()` and `fetchAllChatMessages()`, like `fetchAllVoiceprints()`.

## Tests

`Packages/BiscottiKit/Tests/DataStoreTests/ChatStoreTests.swift`, in-memory unless noted:

- `createThreadSavesFirstQuestion`: one thread with one question at index 0, role `.question`, state `.complete`, no basis; title from the question; `createdAt == updatedAt`.
- `titleCutsAtWordBoundary`: a 90-character question gives a title of at most 61 characters, ending in "…", and the part before "…" is a prefix of the question that ends at a word end; a short question with extra whitespace comes back collapsed and whole; a 70-character single word is cut to 60 plus "…".
- `appendKeepsOrder`: question, answer, question, answer come back at indices 0 to 3 in order.
- `saveAnswerInsertsAfterQuestion`: answering the newest question gives it the next index and moves `updatedAt` forward.
- `answerToInterruptedQuestionStaysNextToIt`: Q0 unanswered, Q1 asked, then Q0 answered: order is Q0, A0, Q1 with indices 0, 1, 2.
- `retryReplacesAnswer`: saving a second answer to the same question keeps the message count, returns the same ID, and carries the new text, state, error and basis.
- `basisRoundTrips`: `.live(through:)`, `.draft` and `.transcript(id:)` each come back unchanged; questions have a `nil` basis.
- `threadsNewestFirst`: `chatThreads(meetingID:)` orders by `updatedAt` descending, including after an older thread gets a new question; an unknown meeting gives `[]`.
- `deleteThreadRemovesMessages`: the thread and its messages are gone; the other thread and its messages remain.
- `deletingMeetingDeletesChats`: `delete(meetingID:)` removes that meeting's threads and messages and leaves another meeting's chats alone.
- `unknownIDsThrowNotFound`: `createChatThread`, `appendChatQuestion`, `saveChatAnswer` (unknown ID, and an answer's ID) and `deleteChatThread` each throw `DataStoreError.notFound`; `chatThread(id:)` returns `nil`.
- `unknownRawValuesDegrade`: a message with unknown `stateRaw`, `roleRaw` and `basisKindRaw` maps to `.complete`, `.question` and `nil`.
- `opensPreChatStore` (on disk): copies `Fixtures/PreChatStore/` to a temp directory, opens it, checks both meetings, the notes, summary, tag and preferred transcript (segment text, speakers, times, word count) are unchanged, creates a chat thread and answer, then reopens the store and finds the thread and the meeting data still there.
