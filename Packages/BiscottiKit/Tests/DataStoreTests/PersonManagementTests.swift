import DataStore
import Foundation
import Testing
import Transcription

// MARK: - Fixtures

private func makeStore() throws -> DataStore {
    try DataStore(storage: .inMemory)
}

/// A transcript result with one segment per speaker ID.
private func makeResult(speakers: [Int]) -> TranscriptResult {
    let segments = speakers.enumerated().map { index, speakerID in
        TranscriptSegment(
            speakerID: speakerID, speakerLabel: "Speaker \(speakerID)",
            startTime: Double(index * 5), endTime: Double(index * 5 + 5),
            text: "Line \(index)", confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
    }
    return TranscriptResult(
        transcriptionMethodId: "v1", language: "en",
        speakerCount: speakers.count, segments: segments, processingDuration: 1
    )
}

/// Creates a meeting with one transcript (speakers 0 and 1) and returns
/// (meetingID, transcriptID).
@discardableResult
private func makeMeeting(
    _ store: DataStore, title: String, start: Date? = nil, summary: String = ""
) async throws -> (UUID, UUID) {
    let meetingID = try await store.createMeeting(title: title, start: start)
    let transcriptID = try await store.addTranscript(
        makeResult(speakers: [0, 1]), vocabularyUsed: [],
        mappedEventIdentifier: nil, to: meetingID
    )
    try await store.setPreferredTranscript(transcriptID, for: meetingID)
    if !summary.isEmpty {
        try await store.applyGeneratedSummary(summary, for: meetingID)
    }
    return (meetingID, transcriptID)
}

private func person(_ store: DataStore, _ name: String, email: String? = nil) async throws -> UUID {
    try await store.findOrCreatePerson(name: name, email: email)
}

private func names(_ store: DataStore) async throws -> [String] {
    try await store.allPersonData().map(\.name)
}

private func day(_ offset: Double) -> Date {
    Date(timeIntervalSince1970: 1_800_000_000 + offset * 86400)
}

// MARK: - Queries

@Suite("People management -- queries")
struct PersonQueryTests {
    @Test("Overview counts speaker uses in any version, attendees, and organizers")
    func overviewCounts() async throws {
        let store = try makeStore()
        let paul = try await person(store, "Paul")
        let ann = try await person(store, "ann")
        let unused = try await person(store, "Zed")

        // Paul is a speaker only in a non-preferred version.
        let (first, _) = try await makeMeeting(store, title: "One", start: day(1))
        let older = try await store.addTranscript(
            makeResult(speakers: [0]), vocabularyUsed: [], mappedEventIdentifier: nil, to: first
        )
        try await store.setSpeakerAssignment(speakerID: 0, personID: paul, for: older)

        // Paul attends, Ann organizes.
        let (second, _) = try await makeMeeting(store, title: "Two", start: day(3))
        try await store.setParticipants([paul], organizer: ann, for: second)

        let overview = try await store.peopleOverview()
        #expect(overview.map(\.person.name) == ["ann", "Paul", "Zed"])
        let byID = Dictionary(uniqueKeysWithValues: overview.map { ($0.id, $0) })
        #expect(byID[paul]?.meetingCount == 2)
        #expect(byID[paul]?.lastSeen == day(3))
        #expect(byID[ann]?.meetingCount == 1)
        #expect(byID[unused]?.meetingCount == 0)
        #expect(byID[unused]?.lastSeen == nil)
    }

    @Test("personMeetings lists roles, newest first")
    func personMeetingsRoles() async throws {
        let store = try makeStore()
        let paul = try await person(store, "Paul")
        let (old, oldTx) = try await makeMeeting(store, title: "Old", start: day(1))
        let (new, newTx) = try await makeMeeting(store, title: "New", start: day(5))
        try await store.setSpeakerAssignment(speakerID: 0, personID: paul, for: oldTx)
        try await store.setSpeakerAssignment(speakerID: 1, personID: paul, for: newTx)
        try await store.setParticipants([paul], organizer: paul, for: new)

        let meetings = try await store.personMeetings(id: paul)
        #expect(meetings.map(\.id) == [new, old])
        #expect(meetings[0].roles == [.speaker, .attendee, .organizer])
        #expect(meetings[1].roles == .speaker)
        #expect(meetings[0].title == "New")
        #expect(meetings[0].date == day(5))
    }

    @Test("personMeetings throws notFound for a missing person")
    func personMeetingsNotFound() async throws {
        let store = try makeStore()
        await #expect(throws: PersonEditError.notFound) {
            try await store.personMeetings(id: UUID())
        }
    }

    @Test("sharedTranscriptMeetings lists meetings where both are speakers")
    func sharedTranscripts() async throws {
        let store = try makeStore()
        let steven = try await person(store, "Steven")
        let stephen = try await person(store, "Stephen")
        let (both, bothTx) = try await makeMeeting(store, title: "Both")
        let (_, aloneTx) = try await makeMeeting(store, title: "Alone")
        try await store.setSpeakerAssignments([0: steven, 1: stephen], for: bothTx)
        try await store.setSpeakerAssignments([0: steven], for: aloneTx)

        let shared = try await store.sharedTranscriptMeetings(steven, stephen)
        #expect(shared.map(\.id) == [both])
    }
}

// MARK: - Update

@Suite("People management -- update")
struct PersonUpdateTests {
    @Test("Rename, case-only rename, and email set/clear")
    func renameAndEmail() async throws {
        let store = try makeStore()
        let id = try await person(store, "steven")

        try await store.updatePerson(id: id, name: "  Steven ", email: nil, replaceInText: false)
        #expect(try await names(store) == ["Steven"])

        try await store.updatePerson(id: id, name: "Steven", email: " Steven@ACME.com ", replaceInText: false)
        #expect(try await store.allPersonData().first?.email == "steven@acme.com")

        try await store.updatePerson(id: id, name: "Steven", email: "", replaceInText: false)
        #expect(try await store.allPersonData().first?.email == nil)
    }

    @Test("Invalid fields are refused")
    func invalidFields() async throws {
        let store = try makeStore()
        let id = try await person(store, "Paul")
        await #expect(throws: PersonEditError.invalid(.emptyName)) {
            try await store.updatePerson(id: id, name: "  ", email: nil, replaceInText: false)
        }
        await #expect(throws: PersonEditError.invalid(.invalidEmail)) {
            try await store.updatePerson(id: id, name: "Paul", email: "paul", replaceInText: false)
        }
        #expect(try await names(store) == ["Paul"])
    }

    @Test("A name collision returns the other person and changes nothing")
    func nameCollision() async throws {
        let store = try makeStore()
        let steven = try await person(store, "Steven")
        let stephen = try await person(store, "Stephen", email: "s@acme.com")
        let other = try await person(store, "Other", email: "o@acme.com")

        await #expect(throws: PersonEditError.nameCollision(
            PersonData(id: stephen, name: "Stephen", email: "s@acme.com")
        )) {
            // Both name and email collide (with different people): name first.
            try await store.updatePerson(id: steven, name: "stephen", email: "o@acme.com", replaceInText: true)
        }
        await #expect(throws: PersonEditError.emailCollision(
            PersonData(id: other, name: "Other", email: "o@acme.com")
        )) {
            try await store.updatePerson(id: steven, name: "Steven", email: "O@acme.com", replaceInText: false)
        }
        #expect(try await names(store) == ["Other", "Stephen", "Steven"])
    }

    @Test("An unchanged name does not collide with an existing same-name person")
    func unchangedDuplicateName() async throws {
        let store = try makeStore()
        let first = try await person(store, "Paul", email: "p1@acme.com")
        _ = try await person(store, "Paul", email: "p2@acme.com")
        try await store.updatePerson(id: first, name: "Paul", email: "paul@acme.com", replaceInText: false)
        #expect(try await store.allPersonData().contains { $0.email == "paul@acme.com" })
    }

    @Test("Updating a missing person throws notFound")
    func updateNotFound() async throws {
        let store = try makeStore()
        await #expect(throws: PersonEditError.notFound) {
            try await store.updatePerson(id: UUID(), name: "X", email: nil, replaceInText: false)
        }
    }

    @Test("Replacement changes summaries and titles of the person's meetings only")
    func replacementScope() async throws {
        let store = try makeStore()
        let steven = try await person(store, "Steven")
        let (mine, mineTx) = try await makeMeeting(
            store, title: "Call with Steven", summary: "Steven and Paul agreed."
        )
        try await store.setSpeakerAssignment(speakerID: 0, personID: steven, for: mineTx)
        try await store.setSummary("Steven's edited notes", for: mine)
        let (other, _) = try await makeMeeting(store, title: "Steven sync", summary: "Steven left.")

        let counts = try await store.replacementCounts(personID: steven, oldName: "Steven", newName: "Stephen")
        #expect(counts == TextReplacementCounts(summaries: 1, titles: 1))

        try await store.updatePerson(id: steven, name: "Stephen", email: nil, replaceInText: true)

        let mineDetail = try #require(try await store.meetingDetail(id: mine))
        #expect(mineDetail.title == "Call with Stephen")
        #expect(mineDetail.summary == "Stephen's edited notes")
        #expect(mineDetail.editedSummary == true)
        let otherDetail = try #require(try await store.meetingDetail(id: other))
        #expect(otherDetail.title == "Steven sync")
        #expect(otherDetail.summary == "Steven left.")
    }

    @Test("Without replacement, stored text keeps the old name")
    func noReplacement() async throws {
        let store = try makeStore()
        let steven = try await person(store, "Steven")
        let (meeting, transcript) = try await makeMeeting(store, title: "Steven 1:1", summary: "Steven spoke.")
        try await store.setSpeakerAssignment(speakerID: 0, personID: steven, for: transcript)

        try await store.updatePerson(id: steven, name: "Stephen", email: nil, replaceInText: false)

        let detail = try #require(try await store.meetingDetail(id: meeting))
        #expect(detail.title == "Steven 1:1")
        #expect(detail.summary == "Steven spoke.")
        #expect(detail.editedSummary == false)
        #expect(detail.editedTitle == false)
    }

    @Test("A rename with title replacement is searchable after sync")
    func searchAfterRename() async throws {
        let store = try makeStore()
        let steven = try await person(store, "Steven")
        let (meeting, transcript) = try await makeMeeting(store, title: "Steven roadmap")
        try await store.setSpeakerAssignment(speakerID: 0, personID: steven, for: transcript)
        _ = try await store.searchHits("roadmap", limit: 10)

        try await store.updatePerson(id: steven, name: "Bartholomew", email: nil, replaceInText: true)

        let hits = try await store.searchHits("Bartholomew", limit: 10)
        #expect(hits.map(\.id) == [meeting])
    }
}

// MARK: - Merge

@Suite("People management -- merge")
struct PersonMergeTests {
    @Test("Merge re-points assignments in every version and keeps userSet")
    func mergeAssignments() async throws {
        let store = try makeStore()
        let steven = try await person(store, "Steven")
        let stephen = try await person(store, "Stephen")
        let (meeting, preferred) = try await makeMeeting(store, title: "M")
        let older = try await store.addTranscript(
            makeResult(speakers: [0, 1]), vocabularyUsed: [], mappedEventIdentifier: nil, to: meeting
        )
        try await store.setSpeakerAssignment(speakerID: 0, personID: steven, for: preferred)
        try await store.setSpeakerAssignments([1: steven], for: older)

        try await store.mergePeople(
            sourceID: steven, targetID: stephen,
            choice: PersonMergeChoice(name: "Stephen", email: nil)
        )

        let human = try await store.humanSetSpeakerMappings(for: preferred)
        #expect(human[0]?.id == stephen)
        let olderTranscript = try #require(try await store.transcript(id: older))
        #expect(olderTranscript.speakerAssignments[1]?.id == stephen)
        #expect(try await store.humanSetSpeakerMappings(for: older).isEmpty)
        #expect(try await names(store) == ["Stephen"])
    }

    @Test("Merge moves attendees without duplicates, organizer, and current user")
    func mergeRelationships() async throws {
        let store = try makeStore()
        let paul = try await person(store, "Paul")
        let kowalski = try await person(store, "Paul Kowalski", email: "paul@acme.com")
        let (both, _) = try await makeMeeting(store, title: "Both")
        let (organized, _) = try await makeMeeting(store, title: "Organized")
        try await store.setParticipants([paul, kowalski], organizer: nil, for: both)
        try await store.setSnapshot(
            CalendarSnapshot(compositeKey: "k|1", title: "Organized"), for: organized
        )
        try await store.setParticipants([paul], organizer: paul, currentUser: paul, for: organized)

        try await store.mergePeople(
            sourceID: paul, targetID: kowalski,
            choice: PersonMergeChoice(name: "Paul Kowalski", email: "paul@acme.com")
        )

        try await store.read { store in
            let bothMeeting = try #require(try store.meeting(id: both))
            #expect(bothMeeting.participants.map(\.id) == [kowalski])
            let organizedMeeting = try #require(try store.meeting(id: organized))
            #expect(organizedMeeting.participants.map(\.id) == [kowalski])
            #expect(organizedMeeting.organizer?.id == kowalski)
            #expect(organizedMeeting.calendarSnapshot?.currentUserPersonID == kowalski)
        }
    }

    @Test("Merge applies the chosen name and email and leaves voiceprints alone")
    func mergeChoicesAndVoiceprints() async throws {
        let store = try makeStore()
        let paul = try await person(store, "Paul", email: "p@old.com")
        let kowalski = try await person(store, "Paul Kowalski")
        let (_, transcript) = try await makeMeeting(store, title: "M")
        try await store.setSpeakerAssignment(speakerID: 0, personID: paul, for: transcript)
        try await store.addVoiceprints(
            [NewVoiceprint(speakerID: 0, vector: [0.1, 0.2], speakingDuration: 10)],
            kind: .raw, space: "test", to: transcript
        )

        try await store.mergePeople(
            sourceID: paul, targetID: kowalski,
            choice: PersonMergeChoice(name: "Paul K", email: "P@old.com")
        )

        let people = try await store.allPersonData()
        #expect(people == [PersonData(id: kowalski, name: "Paul K", email: "p@old.com")])
        let voiceprintCount = try await store.read { try $0.fetchAllVoiceprints().count }
        #expect(voiceprintCount == 1)
    }

    @Test("Merge replaces each old name only in its own person's meetings")
    func mergeReplacement() async throws {
        let store = try makeStore()
        let steven = try await person(store, "Steven")
        let stephen = try await person(store, "Stephen")
        let (stevenMeeting, stevenTranscript) = try await makeMeeting(
            store, title: "Steven call", summary: "Steven and Stephen talked."
        )
        let (stephenMeeting, stephenTranscript) = try await makeMeeting(
            store, title: "Stephen call", summary: "Stephen and Steven talked."
        )
        try await store.setSpeakerAssignment(speakerID: 0, personID: steven, for: stevenTranscript)
        try await store.setSpeakerAssignment(speakerID: 0, personID: stephen, for: stephenTranscript)

        try await store.mergePeople(
            sourceID: steven, targetID: stephen,
            choice: PersonMergeChoice(name: "Stephen Lee", email: nil, replaceSourceName: true)
        )

        let first = try #require(try await store.meetingDetail(id: stevenMeeting))
        #expect(first.title == "Stephen Lee call")
        #expect(first.summary == "Stephen Lee and Stephen talked.")
        let second = try #require(try await store.meetingDetail(id: stephenMeeting))
        #expect(second.title == "Stephen call")
        #expect(second.summary == "Stephen and Steven talked.")
    }

    @Test("Merge with a missing person throws notFound")
    func mergeNotFound() async throws {
        let store = try makeStore()
        let paul = try await person(store, "Paul")
        await #expect(throws: PersonEditError.notFound) {
            try await store.mergePeople(
                sourceID: paul, targetID: UUID(),
                choice: PersonMergeChoice(name: "Paul", email: nil)
            )
        }
        #expect(try await names(store) == ["Paul"])
    }
}

// MARK: - Delete

@Suite("People management -- delete")
struct PersonDeleteTests {
    @Test("An unused person is deleted")
    func deleteUnused() async throws {
        let store = try makeStore()
        let id = try await person(store, "Unknown")
        try await store.deleteUnusedPerson(id: id)
        #expect(try await store.allPersonData().isEmpty)
    }

    @Test("A person in use is refused with their meeting count")
    func deleteInUse() async throws {
        let store = try makeStore()
        let paul = try await person(store, "Paul")
        let (_, transcript) = try await makeMeeting(store, title: "A")
        let (second, _) = try await makeMeeting(store, title: "B")
        try await store.setSpeakerAssignment(speakerID: 0, personID: paul, for: transcript)
        try await store.setParticipants([paul], organizer: nil, for: second)

        await #expect(throws: PersonEditError.inUse(meetingCount: 2)) {
            try await store.deleteUnusedPerson(id: paul)
        }
        await #expect(throws: PersonEditError.notFound) {
            try await store.deleteUnusedPerson(id: UUID())
        }
        #expect(try await names(store) == ["Paul"])
    }

    @Test("An organizer-only person cannot be deleted")
    func organizerOnlyInUse() async throws {
        let store = try makeStore()
        let ann = try await person(store, "Ann")
        let (meeting, _) = try await makeMeeting(store, title: "M")
        try await store.setParticipants([], organizer: ann, for: meeting)
        await #expect(throws: PersonEditError.inUse(meetingCount: 1)) {
            try await store.deleteUnusedPerson(id: ann)
        }
    }
}

// MARK: - Name protection and edge cases

@Suite("People management -- name protection and edge cases")
struct PersonEdgeCaseTests {
    @Test("A rename leaves another person's longer name intact")
    func renameProtectsOtherNames() async throws {
        let store = try makeStore()
        let paul = try await person(store, "Paul")
        _ = try await person(store, "Paul Kowalski")
        let (meeting, transcript) = try await makeMeeting(
            store, title: "Paul sync", summary: "Paul and Paul Kowalski agreed."
        )
        try await store.setSpeakerAssignment(speakerID: 0, personID: paul, for: transcript)

        let counts = try await store.replacementCounts(personID: paul, oldName: "Paul", newName: "Pablo")
        #expect(counts == TextReplacementCounts(summaries: 1, titles: 1))
        try await store.updatePerson(id: paul, name: "Pablo", email: nil, replaceInText: true)

        let detail = try #require(try await store.meetingDetail(id: meeting))
        #expect(detail.summary == "Pablo and Paul Kowalski agreed.")
        #expect(detail.title == "Pablo sync")
    }

    @Test("Merging a prefix name into a longer name replaces both cleanly")
    func mergePrefixNames() async throws {
        let store = try makeStore()
        let paul = try await person(store, "Paul")
        let kowalski = try await person(store, "Paul Kowalski")
        let (meeting, transcript) = try await makeMeeting(
            store, title: "M", summary: "Paul Kowalski joined. Paul agreed."
        )
        try await store.setSpeakerAssignments([0: paul, 1: kowalski], for: transcript)

        try await store.mergePeople(
            sourceID: paul, targetID: kowalski,
            choice: PersonMergeChoice(
                name: "Paul K.", email: nil, replaceSourceName: true, replaceTargetName: true
            )
        )

        let detail = try #require(try await store.meetingDetail(id: meeting))
        #expect(detail.summary == "Paul K. joined. Paul K. agreed.")
    }

    @Test("A merge refuses an email that belongs to a third person")
    func mergeEmailCollision() async throws {
        let store = try makeStore()
        let steven = try await person(store, "Steven")
        let stephen = try await person(store, "Stephen")
        let other = try await person(store, "Other", email: "o@acme.com")

        await #expect(throws: PersonEditError.emailCollision(
            PersonData(id: other, name: "Other", email: "o@acme.com")
        )) {
            try await store.mergePeople(
                sourceID: steven, targetID: stephen,
                choice: PersonMergeChoice(name: "Stephen", email: "O@acme.com")
            )
        }
        #expect(try await names(store) == ["Other", "Stephen", "Steven"])
    }

    @Test("Merging a person into themselves applies the choice as an edit")
    func selfMerge() async throws {
        let store = try makeStore()
        let paul = try await person(store, "Paul")
        try await store.mergePeople(
            sourceID: paul, targetID: paul,
            choice: PersonMergeChoice(name: "Pablo", email: "p@x.com")
        )
        #expect(try await store.allPersonData() == [PersonData(id: paul, name: "Pablo", email: "p@x.com")])
    }

    @Test("Collision compares against the other person's normalized name")
    func collisionNormalizesStoredName() async throws {
        let store = try makeStore()
        let paul = try await person(store, "Paul")
        let smith = try await person(store, "Paul  Smith")
        await #expect(throws: PersonEditError.nameCollision(PersonData(id: smith, name: "Paul  Smith"))) {
            try await store.updatePerson(id: paul, name: "paul smith", email: nil, replaceInText: false)
        }
    }

    @Test("Counts normalize the new name, and a case-only rename replaces text")
    func caseOnlyRename() async throws {
        let store = try makeStore()
        let steven = try await person(store, "steven")
        let (meeting, transcript) = try await makeMeeting(store, title: "Sync", summary: "steven said hi.")
        try await store.setSpeakerAssignment(speakerID: 0, personID: steven, for: transcript)

        let counts = try await store.replacementCounts(personID: steven, oldName: "steven", newName: " Steven ")
        #expect(counts == TextReplacementCounts(summaries: 1, titles: 0))
        try await store.updatePerson(id: steven, name: "Steven", email: nil, replaceInText: true)
        #expect(try await store.meetingDetail(id: meeting)?.summary == "Steven said hi.")
    }
}

// MARK: - Incremental search sync (on-disk store with history)

@Suite("People management -- search sync on disk")
struct PersonSearchSyncTests {
    private func makeOnDiskStore() throws -> (DataStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "PeopleSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (DataStore(storage: .onDisk(dir)), dir)
    }

    @Test("Rename and merge are picked up by the incremental search sync")
    func renameAndMergeReindex() async throws {
        let (store, dir) = try makeOnDiskStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let steven = try await person(store, "Steven")
        let stephen = try await person(store, "Stephen")
        let (_, firstTranscript) = try await makeMeeting(store, title: "Steven roadmap")
        let (second, _) = try await makeMeeting(store, title: "Planning")
        try await store.setSpeakerAssignment(speakerID: 0, personID: steven, for: firstTranscript)
        try await store.setParticipants([steven], organizer: nil, for: second)
        _ = try await store.searchHits("roadmap", limit: 10) // full reconcile, sets the token

        try await store.updatePerson(id: steven, name: "Bartholomew", email: nil, replaceInText: true)
        let renamed = try await store.searchHits("Bartholomew", limit: 10).map(\.title)
        #expect(Set(renamed) == ["Bartholomew roadmap", "Planning"])

        try await store.mergePeople(
            sourceID: steven, targetID: stephen, choice: PersonMergeChoice(name: "Stephen", email: nil)
        )
        let merged = try await store.searchHits("Stephen", limit: 10).map(\.title)
        #expect(merged == ["Planning"])
    }
}
