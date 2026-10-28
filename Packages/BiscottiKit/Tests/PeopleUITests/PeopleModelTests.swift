import AppCore
import BiscottiTestSupport
import DataStore
import Foundation
import Testing
import Transcription
@testable import PeopleUI

// MARK: - Fixtures

private func makeResult() -> TranscriptResult {
    let segments = [0, 1].map { speakerID in
        TranscriptSegment(
            speakerID: speakerID, speakerLabel: "Speaker \(speakerID)",
            startTime: Double(speakerID), endTime: Double(speakerID + 1),
            text: "Hi", confidence: 0.9, noSpeechProbability: 0.1, words: nil
        )
    }
    return TranscriptResult(
        transcriptionMethodId: "v1", language: "en",
        speakerCount: 2, segments: segments, processingDuration: 1
    )
}

/// Creates a meeting where `speakers` are assigned to speakers 0, 1, ….
@discardableResult
private func makeMeeting(
    _ store: DataStore, title: String, summary: String = "", speakers: [UUID]
) async throws -> UUID {
    let meetingID = try await store.createMeeting(title: title)
    let transcriptID = try await store.addTranscript(
        makeResult(), vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID
    )
    try await store.setPreferredTranscript(transcriptID, for: meetingID)
    for (speakerID, personID) in speakers.enumerated() {
        try await store.setSpeakerAssignment(speakerID: speakerID, personID: personID, for: transcriptID)
    }
    if !summary.isEmpty {
        try await store.applyGeneratedSummary(summary, for: meetingID)
    }
    return meetingID
}

// MARK: - Copy

@Suite("PeopleCopy")
struct PeopleCopyTests {
    @Test("Replace label leaves out zero counts and pluralizes")
    func replaceLabel() {
        let both = PeopleCopy.replaceLabel(
            old: "Steven", new: "Stephen", counts: TextReplacementCounts(summaries: 3, titles: 1)
        )
        #expect(both == "Also change \u{201C}Steven\u{201D} to \u{201C}Stephen\u{201D} in 3 summaries and 1 title")
        let summaryOnly = PeopleCopy.replaceLabel(
            old: "A", new: "B", counts: TextReplacementCounts(summaries: 1, titles: 0)
        )
        #expect(summaryOnly.hasSuffix("in 1 summary"))
        let titlesOnly = PeopleCopy.replaceLabel(
            old: "A", new: "B", counts: TextReplacementCounts(summaries: 0, titles: 2)
        )
        #expect(titlesOnly.hasSuffix("in 2 titles"))
    }

    @Test("Overview meta, delete help, headings, and roles")
    func listCopy() {
        let person = PersonData(id: UUID(), name: "Paul")
        #expect(PeopleCopy.overviewMeta(PersonOverviewData(person: person, meetingCount: 0, lastSeen: nil))
            == "Not in any meetings")
        let one = PeopleCopy.overviewMeta(PersonOverviewData(person: person, meetingCount: 1, lastSeen: Date()))
        #expect(one.hasPrefix("1 meeting \u{00B7} "))
        #expect(PeopleCopy.deleteHelp(meetingCount: 0) == "Delete")
        #expect(PeopleCopy.deleteHelp(meetingCount: 12) == "In use in 12 meetings. Reassign or merge to remove.")
        #expect(PeopleCopy.meetingsHeading(1) == "Changes apply to this meeting")
        #expect(PeopleCopy.meetingsHeading(4) == "Changes apply to these 4 meetings")
        #expect(PeopleCopy.roles([.speaker, .organizer]) == "Speaker \u{00B7} Organizer")
    }
}

// MARK: - Merge draft

@Suite("MergeDraft")
struct MergeDraftTests {
    @Test("Name options: typed, target, source, without duplicates")
    func nameOptions() {
        #expect(MergeDraft.nameOptions(typed: "Stephen", source: "Steven", target: "Stephen") == ["Stephen", "Steven"])
        #expect(MergeDraft.nameOptions(typed: "stephen", source: "Steven", target: "Stephen")
            == ["stephen", "Stephen", "Steven"])
    }

    @Test("Email options end with None; default prefers typed, then target, then source")
    func emailOptions() {
        #expect(MergeDraft.emailOptions(typed: nil, source: "a@x.com", target: "B@x.com") == ["b@x.com", "a@x.com", nil])
        #expect(MergeDraft.emailOptions(typed: "a@x.com", source: "A@x.com", target: nil) == ["a@x.com", nil])
        #expect(MergeDraft.defaultEmail(typed: nil, source: "a@x.com", target: "b@x.com") == "b@x.com")
        #expect(MergeDraft.defaultEmail(typed: nil, source: "a@x.com", target: nil) == "a@x.com")
        #expect(MergeDraft.defaultEmail(typed: "t@x.com", source: "a@x.com", target: "b@x.com") == "t@x.com")
    }

    @Test("Choice only replaces names whose counts are non-empty")
    func choice() {
        var draft = MergeDraft(
            source: PersonData(id: UUID(), name: "Steven"),
            target: PersonData(id: UUID(), name: "Stephen"),
            typedName: "Stephen", typedEmail: nil, sourceMeetingCount: 2
        )
        draft.sourceCounts = TextReplacementCounts(summaries: 1, titles: 0)
        #expect(draft.choice == PersonMergeChoice(
            name: "Stephen", email: nil, replaceSourceName: true, replaceTargetName: false
        ))
        draft.replaceSource = false
        #expect(draft.choice.replaceSourceName == false)
        #expect(draft.subtitle == "Steven\u{2019}s 2 meetings move to Stephen. Steven is removed.")
    }
}

// MARK: - Editor model

@Suite("PersonEditorModel")
@MainActor
struct PersonEditorModelTests {
    @Test("Loads the person and their meetings; save is disabled until something changes")
    func loadAndValidate() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let steven = try await fixture.store.findOrCreatePerson(name: "Steven", email: nil)
        try await makeMeeting(fixture.store, title: "Kickoff", speakers: [steven])

        let model = PersonEditorModel(core: fixture.core, personID: steven, countsDelay: .zero)
        await model.load()
        #expect(model.nameText == "Steven")
        #expect(model.meetings.map(\.title) == ["Kickoff"])
        #expect(!model.canSave)

        model.nameText = "  "
        #expect(model.nameError == "Enter a name.")
        #expect(!model.canSave)
        model.nameText = "Stephen"
        model.emailText = "nope"
        #expect(model.emailError == "Enter a valid email address, or leave it empty.")
        model.emailText = ""
        #expect(model.canSave)
    }

    @Test("Replacement counts show the toggle, and save applies the replacement")
    func replacement() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let steven = try await fixture.store.findOrCreatePerson(name: "Steven", email: nil)
        let meeting = try await makeMeeting(
            fixture.store, title: "Steven sync", summary: "Steven agreed.", speakers: [steven]
        )

        let model = PersonEditorModel(core: fixture.core, personID: steven, countsDelay: .zero)
        await model.load()
        model.nameText = "Stephen"
        await model.refreshReplacementCounts()
        #expect(model.showsReplaceToggle)
        #expect(model.replaceLabel.hasSuffix("in 1 summary and 1 title"))

        let versionBefore = fixture.core.peopleVersion
        #expect(await model.save())
        #expect(model.didChange)
        #expect(fixture.core.peopleVersion == versionBefore + 1)
        let detail = try #require(try await fixture.store.meetingDetail(id: meeting))
        #expect(detail.title == "Stephen sync")
        #expect(detail.summary == "Stephen agreed.")
        #expect(fixture.core.summaries.first?.title == "Stephen sync")
    }

    @Test("Turning the toggle off keeps stored text")
    func replacementOff() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let steven = try await fixture.store.findOrCreatePerson(name: "Steven", email: nil)
        let meeting = try await makeMeeting(
            fixture.store, title: "Steven sync", summary: "Steven agreed.", speakers: [steven]
        )

        let model = PersonEditorModel(core: fixture.core, personID: steven, countsDelay: .zero)
        await model.load()
        model.nameText = "Stephen"
        model.replaceInText = false
        #expect(await model.save())
        let detail = try #require(try await fixture.store.meetingDetail(id: meeting))
        #expect(detail.summary == "Steven agreed.")
    }

    @Test("A name collision shows the banner, clears on edit, and leads to merge")
    func collisionAndMerge() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let steven = try await fixture.store.findOrCreatePerson(name: "Steven", email: nil)
        let stephen = try await fixture.store.findOrCreatePerson(name: "Stephen", email: "s@acme.com")
        try await makeMeeting(fixture.store, title: "Both", summary: "Steven and Stephen.", speakers: [steven, stephen])

        let model = PersonEditorModel(core: fixture.core, personID: steven, countsDelay: .zero)
        await model.load()
        model.nameText = "Stephen"
        #expect(await model.save() == false)
        #expect(model.collision == .name(PersonData(id: stephen, name: "Stephen", email: "s@acme.com")))
        #expect(model.collisionTitle == "\u{201C}Stephen\u{201D} is already a person.")
        #expect(model.mergeButtonTitle == "Merge with Stephen\u{2026}")

        model.keepEditing()
        #expect(model.collision == nil)
        #expect(await model.save() == false)
        await model.beginMerge()
        let draft = try #require(model.mergeDraft)
        #expect(draft.name == "Stephen")
        #expect(draft.email == "s@acme.com")
        #expect(draft.sharedMeetings.map(\.title) == ["Both"])
        #expect(draft.showsSourceReplace)
        #expect(!draft.showsTargetReplace)

        #expect(await model.confirmMerge())
        let people = try await fixture.store.allPersonData()
        #expect(people.map(\.id) == [stephen])
    }

    @Test("Editing the email clears an email collision")
    func emailCollisionClears() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let paul = try await fixture.store.findOrCreatePerson(name: "Paul", email: nil)
        _ = try await fixture.store.findOrCreatePerson(name: "Paul Kowalski", email: "paul@acme.com")

        let model = PersonEditorModel(core: fixture.core, personID: paul, countsDelay: .zero)
        await model.load()
        model.emailText = "PAUL@acme.com"
        #expect(await model.save() == false)
        #expect(model.collisionTitle == "paul@acme.com already belongs to Paul Kowalski.")
        model.emailText = "paul@other.com"
        #expect(model.collision == nil)
    }

    @Test("A person removed elsewhere is reported as missing")
    func missingPerson() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let paul = try await fixture.store.findOrCreatePerson(name: "Paul", email: nil)
        let model = PersonEditorModel(core: fixture.core, personID: paul, countsDelay: .zero)
        await model.load()
        try await fixture.store.deleteUnusedPerson(id: paul)

        model.nameText = "Pablo"
        #expect(await model.save() == false)
        #expect(model.isMissing)
        #expect(model.errorMessage == "This person no longer exists.")
        #expect(!model.canSave)
    }
}

// MARK: - List model

@Suite("PeopleListModel")
@MainActor
struct PeopleListModelTests {
    @Test("Filters by name or email and deletes only unused people")
    func filterAndDelete() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let paul = try await fixture.store.findOrCreatePerson(name: "Paul", email: nil)
        _ = try await fixture.store.findOrCreatePerson(name: "Ann", email: "ann@acme.com")
        _ = try await fixture.store.findOrCreatePerson(name: "Unknown", email: nil)
        try await makeMeeting(fixture.store, title: "M", speakers: [paul])

        let model = PeopleListModel(core: fixture.core)
        await model.load()
        #expect(model.rows.map(\.person.name) == ["Ann", "Paul", "Unknown"])

        model.filter = "ACME"
        #expect(model.filteredRows.map(\.person.name) == ["Ann"])
        model.filter = "zzz"
        #expect(model.filteredRows.isEmpty)
        #expect(model.noMatchText == "No people match \u{201C}zzz\u{201D}.")
        model.filter = ""

        let paulRow = try #require(model.rows.first { $0.person.name == "Paul" })
        await model.delete(paulRow)
        #expect(model.rows.count == 3)

        let unknownRow = try #require(model.rows.first { $0.person.name == "Unknown" })
        await model.delete(unknownRow)
        #expect(model.rows.map(\.person.name) == ["Ann", "Paul"])
    }

    @Test("A stale unused row that gained a use is refused and refreshed")
    func staleDelete() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        let paul = try await fixture.store.findOrCreatePerson(name: "Paul", email: nil)
        let model = PeopleListModel(core: fixture.core)
        await model.load()
        let staleRow = try #require(model.rows.first)

        try await makeMeeting(fixture.store, title: "M", speakers: [paul])
        await model.delete(staleRow)
        #expect(model.rows.first?.meetingCount == 1)
    }

    @Test("Closing a changed editor reloads the list")
    func editorClose() async throws {
        let fixture = try makeCoreFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.store.findOrCreatePerson(name: "Paul", email: nil)
        let model = PeopleListModel(core: fixture.core)
        await model.load()
        try model.edit(#require(model.rows.first))
        let editor = try #require(model.editor)
        await editor.load()
        editor.nameText = "Pablo"
        #expect(await editor.save())

        await model.editorDidClose()
        #expect(model.editor == nil)
        #expect(model.rows.map(\.person.name) == ["Pablo"])
    }
}
