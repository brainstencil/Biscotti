import DataStore
import Foundation
import Testing

// MARK: - Helpers

private func makeStoreWithMeeting(
    title: String = "Planning"
) async throws -> (store: DataStore, meetingID: UUID) {
    let store = try DataStore(storage: .inMemory)
    let meetingID = try await store.createMeeting(title: title)
    return (store, meetingID)
}

private func loadThread(_ store: DataStore, _ threadID: UUID) async throws -> ChatThreadData {
    try #require(await store.chatThread(id: threadID))
}

private func threadTitle(for question: String) async throws -> String {
    let (store, meetingID) = try await makeStoreWithMeeting()
    let (threadID, _) = try await store.createChatThread(meetingID: meetingID, firstQuestion: question)
    return try await loadThread(store, threadID).summary.title
}

/// "index role text", for comparing a thread's order at a glance.
private func outline(_ thread: ChatThreadData) -> [String] {
    thread.messages.map { "\($0.index) \($0.role.rawValue) \($0.text)" }
}

// MARK: - Threads and Messages

@Suite("Chat storage")
struct ChatStoreTests {
    @Test("Creating a thread saves its first question at index 0")
    func createThreadSavesFirstQuestion() async throws {
        let (store, meetingID) = try await makeStoreWithMeeting()

        let (threadID, questionID) = try await store.createChatThread(
            meetingID: meetingID, firstQuestion: "What did we decide?"
        )

        let thread = try await loadThread(store, threadID)
        #expect(thread.summary.id == threadID)
        #expect(thread.summary.meetingID == meetingID)
        #expect(thread.summary.title == "What did we decide?")
        #expect(thread.summary.createdAt == thread.summary.updatedAt)
        let question = try #require(thread.messages.first)
        #expect(thread.messages.count == 1)
        #expect(question.id == questionID)
        #expect(question.index == 0)
        #expect(question.role == .question)
        #expect(question.text == "What did we decide?")
        #expect(question.state == .complete)
        #expect(question.errorMessage == nil)
        #expect(question.basis == nil)
        #expect(try await store.chatThreads(meetingID: meetingID) == [thread.summary])
    }

    @Test("A long first question is cut between words, with an ellipsis")
    func titleCutsAtWordBoundary() async throws {
        let long = "Can you list every decision we made about the launch plan and who agreed to own each item?"
        #expect(long.count == 90)
        let title = try await threadTitle(for: long)
        #expect(title == "Can you list every decision we made about the launch plan…")
        #expect(title.count <= 61)

        #expect(try await threadTitle(for: "  What did\n Ada   say?\t") == "What did Ada say?")

        let sixty = "Which risks did the team raise, and who will follow up on it"
        #expect(sixty.count == 60)
        #expect(try await threadTitle(for: sixty) == sixty)
        #expect(try await threadTitle(for: sixty + "?") == "Which risks did the team raise, and who will follow up on…")

        let oneLongWord = String(repeating: "a", count: 70)
        #expect(try await threadTitle(for: oneLongWord) == String(repeating: "a", count: 60) + "…")
    }

    @Test("Questions and answers come back in index order")
    func appendKeepsOrder() async throws {
        let (store, meetingID) = try await makeStoreWithMeeting()
        let (threadID, firstID) = try await store.createChatThread(meetingID: meetingID, firstQuestion: "Q1")
        try await store.saveChatAnswer(
            questionID: firstID, text: "A1", state: .complete, errorMessage: nil, basis: .draft
        )
        let secondID = try await store.appendChatQuestion(threadID: threadID, text: "Q2")
        try await store.saveChatAnswer(
            questionID: secondID, text: "A2", state: .complete, errorMessage: nil, basis: .draft
        )

        let thread = try await loadThread(store, threadID)
        #expect(outline(thread) == ["0 question Q1", "1 answer A1", "2 question Q2", "3 answer A2"])
    }

    @Test("An answer to the newest question takes the next index and moves updatedAt")
    func saveAnswerInsertsAfterQuestion() async throws {
        let (store, meetingID) = try await makeStoreWithMeeting()
        let (threadID, questionID) = try await store.createChatThread(
            meetingID: meetingID, firstQuestion: "Who owns the launch?"
        )
        let before = try await loadThread(store, threadID).summary.updatedAt

        let answerID = try await store.saveChatAnswer(
            questionID: questionID, text: "Ada owns it", state: .stopped,
            errorMessage: nil, basis: .live(through: 754)
        )

        let thread = try await loadThread(store, threadID)
        let answer = try #require(thread.messages.last)
        #expect(thread.messages.count == 2)
        #expect(answer.id == answerID)
        #expect(answer.index == 1)
        #expect(answer.role == .answer)
        #expect(answer.text == "Ada owns it")
        #expect(answer.state == .stopped)
        #expect(thread.summary.updatedAt > before)
    }

    @Test("Answering an interrupted question after newer turns keeps the answer next to it")
    func answerToInterruptedQuestionStaysNextToIt() async throws {
        let (store, meetingID) = try await makeStoreWithMeeting()
        let (threadID, interruptedID) = try await store.createChatThread(meetingID: meetingID, firstQuestion: "Q1")
        _ = try await store.appendChatQuestion(threadID: threadID, text: "Q2")

        try await store.saveChatAnswer(
            questionID: interruptedID, text: "A1", state: .complete, errorMessage: nil, basis: .draft
        )

        let thread = try await loadThread(store, threadID)
        #expect(outline(thread) == ["0 question Q1", "1 answer A1", "2 question Q2"])
    }

    @Test("Retry replaces the answer already saved for the question")
    func retryReplacesAnswer() async throws {
        let (store, meetingID) = try await makeStoreWithMeeting()
        let (threadID, questionID) = try await store.createChatThread(meetingID: meetingID, firstQuestion: "Q1")
        let failedID = try await store.saveChatAnswer(
            questionID: questionID, text: "", state: .failed,
            errorMessage: "The AI model failed to load.", basis: .draft
        )
        let transcriptID = UUID()

        let retriedID = try await store.saveChatAnswer(
            questionID: questionID, text: "A1", state: .complete,
            errorMessage: nil, basis: .transcript(id: transcriptID)
        )

        let thread = try await loadThread(store, threadID)
        let answer = try #require(thread.messages.last)
        #expect(retriedID == failedID)
        #expect(thread.messages.count == 2)
        #expect(answer.index == 1)
        #expect(answer.text == "A1")
        #expect(answer.state == .complete)
        #expect(answer.errorMessage == nil)
        #expect(answer.basis == .transcript(id: transcriptID))
        let messageCount = try await store.read { try $0.fetchAllChatMessages().count }
        #expect(messageCount == 2)
    }

    @Test(
        "Each kind of basis round-trips",
        arguments: [ChatBasis.live(through: 754.5), .draft, .transcript(id: UUID())]
    )
    func basisRoundTrips(basis: ChatBasis) async throws {
        let (store, meetingID) = try await makeStoreWithMeeting()
        let (threadID, questionID) = try await store.createChatThread(meetingID: meetingID, firstQuestion: "Q1")

        try await store.saveChatAnswer(
            questionID: questionID, text: "A1", state: .complete, errorMessage: nil, basis: basis
        )

        let thread = try await loadThread(store, threadID)
        #expect(thread.messages.map(\.basis) == [nil, basis])
    }

    @Test("A meeting's threads are listed newest first")
    func threadsNewestFirst() async throws {
        let (store, meetingID) = try await makeStoreWithMeeting()
        let (olderID, _) = try await store.createChatThread(meetingID: meetingID, firstQuestion: "Older")
        let (newerID, _) = try await store.createChatThread(meetingID: meetingID, firstQuestion: "Newer")

        #expect(try await store.chatThreads(meetingID: meetingID).map(\.id) == [newerID, olderID])

        _ = try await store.appendChatQuestion(threadID: olderID, text: "Follow-up")

        #expect(try await store.chatThreads(meetingID: meetingID).map(\.id) == [olderID, newerID])
        #expect(try await store.chatThreads(meetingID: UUID()).isEmpty)
    }

    @Test("Deleting a thread deletes its messages and leaves other threads")
    func deleteThreadRemovesMessages() async throws {
        let (store, meetingID) = try await makeStoreWithMeeting()
        let (deletedID, deletedQuestionID) = try await store.createChatThread(
            meetingID: meetingID, firstQuestion: "Q1"
        )
        try await store.saveChatAnswer(
            questionID: deletedQuestionID, text: "A1", state: .complete, errorMessage: nil, basis: .draft
        )
        let (keptID, _) = try await store.createChatThread(meetingID: meetingID, firstQuestion: "Kept")

        try await store.deleteChatThread(id: deletedID)

        #expect(try await store.chatThread(id: deletedID) == nil)
        #expect(try await store.chatThreads(meetingID: meetingID).map(\.id) == [keptID])
        let kept = try await loadThread(store, keptID)
        #expect(outline(kept) == ["0 question Kept"])
        let messageCount = try await store.read { try $0.fetchAllChatMessages().count }
        #expect(messageCount == 1)
    }

    @Test("Deleting a meeting deletes its chats and no one else's")
    func deletingMeetingDeletesChats() async throws {
        let (store, deletedMeetingID) = try await makeStoreWithMeeting()
        let keptMeetingID = try await store.createMeeting(title: "Kept")
        let (_, questionID) = try await store.createChatThread(meetingID: deletedMeetingID, firstQuestion: "Q1")
        try await store.saveChatAnswer(
            questionID: questionID, text: "A1", state: .complete, errorMessage: nil, basis: .draft
        )
        _ = try await store.createChatThread(meetingID: deletedMeetingID, firstQuestion: "Q2")
        let (keptThreadID, _) = try await store.createChatThread(meetingID: keptMeetingID, firstQuestion: "Kept")

        try await store.delete(meetingID: deletedMeetingID)

        let counts = try await store.read { store in
            try [store.fetchAllChatThreads().count, store.fetchAllChatMessages().count]
        }
        #expect(counts == [1, 1])
        #expect(try await store.chatThreads(meetingID: keptMeetingID).map(\.id) == [keptThreadID])
    }

    @Test("Writes with an unknown ID throw notFound")
    func unknownIDsThrowNotFound() async throws {
        let (store, meetingID) = try await makeStoreWithMeeting()
        let (threadID, questionID) = try await store.createChatThread(meetingID: meetingID, firstQuestion: "Q1")
        let answerID = try await store.saveChatAnswer(
            questionID: questionID, text: "A1", state: .complete, errorMessage: nil, basis: .draft
        )
        let unknown = UUID()

        await #expect(throws: DataStoreError.notFound(unknown)) {
            try await store.createChatThread(meetingID: unknown, firstQuestion: "Q")
        }
        await #expect(throws: DataStoreError.notFound(unknown)) {
            try await store.appendChatQuestion(threadID: unknown, text: "Q")
        }
        await #expect(throws: DataStoreError.notFound(unknown)) {
            try await store.saveChatAnswer(
                questionID: unknown, text: "A", state: .complete, errorMessage: nil, basis: .draft
            )
        }
        await #expect(throws: DataStoreError.notFound(answerID)) {
            try await store.saveChatAnswer(
                questionID: answerID, text: "A", state: .complete, errorMessage: nil, basis: .draft
            )
        }
        await #expect(throws: DataStoreError.notFound(unknown)) {
            try await store.deleteChatThread(id: unknown)
        }
        #expect(try await store.chatThread(id: unknown) == nil)
        #expect(try await loadThread(store, threadID).messages.count == 2)
    }

    @Test("Raw values from a later version read as defaults")
    func unknownRawValuesDegrade() async throws {
        let (store, meetingID) = try await makeStoreWithMeeting()
        let (threadID, questionID) = try await store.createChatThread(meetingID: meetingID, firstQuestion: "Q1")
        let answerID = try await store.saveChatAnswer(
            questionID: questionID, text: "A1", state: .failed, errorMessage: "Failed", basis: .draft
        )

        let answer = try await store.read { store in
            let record = try #require(store.fetchAllChatMessages().first { $0.id == answerID })
            record.roleRaw = "aside"
            record.stateRaw = "paused"
            record.basisKindRaw = "summary"
            return try #require(store.chatThread(id: threadID)?.messages.last)
        }

        #expect(answer.role == .question)
        #expect(answer.state == .complete)
        #expect(answer.basis == nil)
    }
}

// MARK: - Store Written Before Chat

/// Opens a copy of `Fixtures/PreChatStore`, a store written by the DataStore code at
/// commit ddfa13f, before the chat models existed. Its WAL was checkpointed into
/// `Biscotti.store`, and it has no `SearchIndex.sqlite` (the store rebuilds it on open).
/// Its contents are fixed, so the expected values are literals.
@Suite("Chat storage on a store written before chat")
struct PreChatStoreTests {
    private let roadmapID = UUID(uuidString: "3F012626-B36F-43B1-BC6E-6E7B9CAE48DB") ?? UUID()
    private let hallwayID = UUID(uuidString: "882934CE-45B9-4B5C-9F5E-50917FCFEBC8") ?? UUID()
    private let transcriptID = UUID(uuidString: "6E1C0D5A-2F4B-4C1E-9A7D-3B5F8C2E1A90") ?? UUID()

    @Test("A store written before chat opens unchanged and takes a chat thread")
    func opensPreChatStore() async throws {
        let directory = try copyFixtureStore()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let threadID: UUID
        do {
            let store = try DataStore(storage: .onDisk(directory))
            try await expectFixtureMeetingsUnchanged(store)
            #expect(try await store.chatThreads(meetingID: roadmapID).isEmpty)

            let (createdID, questionID) = try await store.createChatThread(
                meetingID: roadmapID, firstQuestion: "When does chat ship?"
            )
            try await store.saveChatAnswer(
                questionID: questionID, text: "In the third quarter.", state: .complete,
                errorMessage: nil, basis: .transcript(id: transcriptID)
            )
            threadID = createdID
        }

        let reopened = try DataStore(storage: .onDisk(directory))
        try await expectFixtureMeetingsUnchanged(reopened)
        #expect(try await reopened.chatThreads(meetingID: roadmapID).map(\.id) == [threadID])
        let thread = try await loadThread(reopened, threadID)
        #expect(outline(thread) == ["0 question When does chat ship?", "1 answer In the third quarter."])
        #expect(thread.messages.last?.basis == .transcript(id: transcriptID))
    }

    /// Copies the fixture into a fresh temporary directory and returns the copy's URL.
    private func copyFixtureStore() throws -> URL {
        let fixture = try #require(
            Bundle.module.url(forResource: "PreChatStore", withExtension: nil, subdirectory: "Fixtures")
        )
        let copy = FileManager.default.temporaryDirectory
            .appending(path: "PreChatStoreTests-\(UUID().uuidString)")
            .appending(path: "PreChatStore")
        try FileManager.default.createDirectory(
            at: copy.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixture, to: copy)
        return copy
    }

    private func expectFixtureMeetingsUnchanged(_ store: DataStore) async throws {
        #expect(try await Set(store.meetingSummaries().map(\.title)) == ["Roadmap review", "Hallway chat"])

        let roadmap = try #require(await store.meetingDetail(id: roadmapID))
        #expect(roadmap.title == "Roadmap review")
        #expect(roadmap.notes == "Bring the Q3 numbers.")
        #expect(roadmap.summary == "## Decisions\n- Ship chat in Q3.")
        #expect(roadmap.recordingDuration == 1800)
        #expect(roadmap.tags.map(\.name) == ["Planning"])
        #expect(roadmap.versions.map(\.vocabularyUsed) == [["Biscotti"]])

        let transcript = try #require(roadmap.preferredTranscript)
        #expect(transcript.id == transcriptID)
        #expect(transcript.speakerCount == 2)
        #expect(transcript.segments.map(\.text) == [
            "Let's start with the roadmap.", "Chat ships in the third quarter."
        ])
        #expect(transcript.segments.map(\.speakerLabel) == ["Speaker 0", "Speaker 1"])
        #expect(transcript.segments.map(\.startTime) == [0, 75])
        #expect(transcript.segments.map(\.endTime) == [4.5, 81])

        // Ada is the organizer and the only participant; meetingPeople lists her once.
        let people = try await store.meetingPeople(id: roadmapID)
        #expect(people?.organizer?.name == "Ada Lovelace")
        #expect(people?.participants.isEmpty == true)
        let roadmapMeetingID = roadmapID
        let participantNames = try await store.read { store in
            try store.meeting(id: roadmapMeetingID)?.participants.map(\.name)
        }
        #expect(participantNames == ["Ada Lovelace"])

        let rowCounts = try await store.read { store in
            try [store.fetchAllWords().count, store.fetchAllVoiceprints().count]
        }
        #expect(rowCounts == [5, 1])

        let hallway = try #require(await store.meetingDetail(id: hallwayID))
        #expect(hallway.title == "Hallway chat")
        #expect(hallway.preferredTranscript == nil)
        #expect(hallway.versions.isEmpty)
    }
}
