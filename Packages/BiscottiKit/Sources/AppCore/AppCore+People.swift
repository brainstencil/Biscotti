import DataStore
import Foundation

// MARK: - People management

// Thin pass-throughs to `DataStore`, which owns the rules and does each
// mutation in one save. After a change, `peopleVersion` is bumped so open
// views reload names, and the meeting list (which shows participant names
// and titles) is refreshed.

public extension AppCore {
    func peopleOverview() async throws -> [PersonOverviewData] {
        try await store.peopleOverview()
    }

    func personMeetings(id: UUID) async throws -> [PersonMeetingData] {
        try await store.personMeetings(id: id)
    }

    func replacementCounts(
        personID: UUID, oldName: String, newName: String
    ) async throws -> TextReplacementCounts {
        try await store.replacementCounts(personID: personID, oldName: oldName, newName: newName)
    }

    func sharedTranscriptMeetings(_ first: UUID, _ second: UUID) async throws -> [PersonMeetingData] {
        try await store.sharedTranscriptMeetings(first, second)
    }

    func updatePerson(id: UUID, name: String, email: String?, replaceInText: Bool) async throws {
        try await store.updatePerson(id: id, name: name, email: email, replaceInText: replaceInText)
        peopleVersion &+= 1
        // The meeting list shows participant names and titles.
        await reloadSummaries()
    }

    func mergePeople(sourceID: UUID, targetID: UUID, choice: PersonMergeChoice) async throws {
        try await store.mergePeople(sourceID: sourceID, targetID: targetID, choice: choice)
        peopleVersion &+= 1
        await reloadSummaries()
    }

    func deleteUnusedPerson(id: UUID) async throws {
        try await store.deleteUnusedPerson(id: id)
        peopleVersion &+= 1
    }
}
