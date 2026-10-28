import Foundation
import SwiftData

// MARK: - Read Models

/// How a meeting refers to a person. A person can hold several roles in
/// one meeting.
public struct PersonRoles: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A speaker in any transcript version is assigned to the person.
    public static let speaker = PersonRoles(rawValue: 1 << 0)
    /// The person is one of the meeting's participants (calendar invitees).
    public static let attendee = PersonRoles(rawValue: 1 << 1)
    /// The person is the meeting's organizer.
    public static let organizer = PersonRoles(rawValue: 1 << 2)
}

/// One meeting a person appears in, for the person editor's list.
public struct PersonMeetingData: Sendable, Identifiable, Equatable {
    /// The meeting ID.
    public let id: UUID
    public let title: String
    /// The meeting's effective date (`startDate ?? createdAt`).
    public let date: Date
    public let roles: PersonRoles

    public init(id: UUID, title: String, date: Date, roles: PersonRoles) {
        self.id = id
        self.title = title
        self.date = date
        self.roles = roles
    }
}

/// One row of the People sheet.
public struct PersonOverviewData: Sendable, Identifiable, Equatable {
    public let person: PersonData
    /// Distinct meetings with at least one use of the person.
    public let meetingCount: Int
    /// The newest effective date among those meetings. Nil when unused.
    public let lastSeen: Date?

    public var id: UUID {
        person.id
    }

    public init(person: PersonData, meetingCount: Int, lastSeen: Date?) {
        self.person = person
        self.meetingCount = meetingCount
        self.lastSeen = lastSeen
    }
}

/// How many of a person's meetings would change if the old name were
/// replaced in stored text.
public struct TextReplacementCounts: Sendable, Equatable {
    /// Meetings whose summary has at least one replaceable occurrence.
    public let summaries: Int
    /// Meetings whose title has at least one replaceable occurrence.
    public let titles: Int

    public var isEmpty: Bool {
        summaries == 0 && titles == 0
    }

    public init(summaries: Int, titles: Int) {
        self.summaries = summaries
        self.titles = titles
    }
}

/// What the surviving person keeps after a merge, and whether each old
/// name is replaced in its own person's summaries and titles.
public struct PersonMergeChoice: Sendable, Equatable {
    public let name: String
    public let email: String?
    public let replaceSourceName: Bool
    public let replaceTargetName: Bool

    public init(
        name: String, email: String?,
        replaceSourceName: Bool = false, replaceTargetName: Bool = false
    ) {
        self.name = name
        self.email = email
        self.replaceSourceName = replaceSourceName
        self.replaceTargetName = replaceTargetName
    }
}

/// Why a people-management mutation was refused. A refused mutation
/// leaves the store unchanged.
public enum PersonEditError: Error, Equatable, Sendable {
    /// The person no longer exists (merged or deleted elsewhere).
    case notFound
    case invalid(PersonFieldError)
    /// Another person already has this name (case-insensitive).
    case nameCollision(PersonData)
    /// Another person already has this email.
    case emailCollision(PersonData)
    /// Delete refused: the person is still used in this many meetings.
    case inUse(meetingCount: Int)
}

// MARK: - Person Use Index

/// Every use of every person, built from one pass over all meetings.
/// `TranscriptRecord` has no relationship back to its meeting, so this
/// walks `Meeting.transcripts`.
struct PersonUseIndex {
    var meetings: [UUID: Meeting] = [:]
    /// personID → meetingID → roles.
    var uses: [UUID: [UUID: PersonRoles]] = [:]

    mutating func add(_ personID: UUID, _ meetingID: UUID, _ role: PersonRoles) {
        uses[personID, default: [:]][meetingID, default: []].insert(role)
    }

    func meetings(of personID: UUID) -> [Meeting] {
        (uses[personID] ?? [:]).keys.compactMap { meetings[$0] }
    }

    func meetingCount(of personID: UUID) -> Int {
        uses[personID]?.count ?? 0
    }
}

extension Meeting {
    /// `startDate ?? createdAt`, the date used for sorting and display.
    var effectiveDate: Date {
        startDate ?? createdAt
    }
}

extension DataStore {
    func personUseIndex() throws -> PersonUseIndex {
        var index = PersonUseIndex()
        for meeting in try context.fetch(FetchDescriptor<Meeting>()) {
            index.meetings[meeting.id] = meeting
            for transcript in meeting.transcripts {
                for entry in transcript.speakerAssignments.values {
                    index.add(entry.personID, meeting.id, .speaker)
                }
            }
            for participant in meeting.participants {
                index.add(participant.id, meeting.id, .attendee)
            }
            if let organizer = meeting.organizer {
                index.add(organizer.id, meeting.id, .organizer)
            }
        }
        return index
    }

    /// Fetches a person or throws `PersonEditError.notFound`.
    func requirePerson(_ personID: UUID) throws -> Person {
        guard let person = try fetchPerson(id: personID) else {
            throw PersonEditError.notFound
        }
        return person
    }

    /// Other people's names that contain `name`, which a replacement of
    /// `name` must leave intact ("Paul" must not rewrite "Paul Kowalski").
    func protectedNames(containing name: String, excluding ids: Set<UUID>) throws -> [String] {
        try context.fetch(FetchDescriptor<Person>())
            .filter { !ids.contains($0.id) && $0.name != name && $0.name.contains(name) }
            .map(\.name)
    }

    /// Replaces `old` with `new` in the summary and title of each meeting,
    /// leaving occurrences inside any `protecting` name alone. The
    /// `editedSummary` / `editedTitle` flags are left alone: this is a
    /// correction, not new authorship. The caller saves.
    func applyNameReplacement(
        old: String, new: String, in meetings: [Meeting], protecting: [String]
    ) {
        for meeting in meetings {
            let summary = NameReplacement.apply(
                old: old, new: new, to: meeting.summary, protecting: protecting
            )
            if summary != meeting.summary { meeting.summary = summary }
            let title = NameReplacement.apply(
                old: old, new: new, to: meeting.title, protecting: protecting
            )
            if title != meeting.title { meeting.title = title }
        }
    }
}

extension DataStore {
    /// Moves every use of `source` in one meeting to `target`: speaker
    /// assignments in all transcript versions (keeping `userSet`), the
    /// attendee list (without duplicating the target), the organizer, and
    /// the calendar snapshot's current-user mark. The caller saves.
    func repointUses(in meeting: Meeting, from source: Person, to target: Person) {
        for transcript in meeting.transcripts {
            var assignments = transcript.speakerAssignments
            var changed = false
            for (speakerID, entry) in assignments where entry.personID == source.id {
                assignments[speakerID] = SpeakerAssignmentEntry(
                    personID: target.id, userSet: entry.userSet
                )
                changed = true
            }
            if changed { transcript.speakerAssignments = assignments }
        }
        if meeting.participants.contains(where: { $0.id == source.id }) {
            var participants = meeting.participants.filter { $0.id != source.id }
            if !participants.contains(where: { $0.id == target.id }) {
                participants.append(target)
            }
            meeting.participants = participants
        }
        if meeting.organizer?.id == source.id {
            meeting.organizer = target
        }
        if meeting.calendarSnapshot?.currentUserPersonID == source.id {
            meeting.calendarSnapshot?.currentUserPersonID = target.id
        }
    }
}

// MARK: - Queries

public extension DataStore {
    /// Every person with their meeting count and last-seen date, sorted
    /// by name (case-insensitive).
    func peopleOverview() throws -> [PersonOverviewData] {
        let index = try personUseIndex()
        return try context.fetch(FetchDescriptor<Person>())
            .map { person in
                let meetings = index.meetings(of: person.id)
                return PersonOverviewData(
                    person: PersonData(id: person.id, name: person.name, email: person.email),
                    meetingCount: meetings.count,
                    lastSeen: meetings.map(\.effectiveDate).max()
                )
            }
            .sorted {
                $0.person.name.localizedCaseInsensitiveCompare($1.person.name)
                    == .orderedAscending
            }
    }

    /// The meetings a person appears in, newest first.
    func personMeetings(id personID: UUID) throws -> [PersonMeetingData] {
        _ = try requirePerson(personID)
        let index = try personUseIndex()
        return (index.uses[personID] ?? [:])
            .compactMap { meetingID, roles in
                index.meetings[meetingID].map {
                    PersonMeetingData(
                        id: $0.id, title: $0.title, date: $0.effectiveDate, roles: roles
                    )
                }
            }
            .sorted { $0.date > $1.date }
    }

    /// How many of the person's meetings have a summary or title that
    /// `oldName` → `newName` replacement would change. `newName` is
    /// normalized first, as the save does. Other people's names that
    /// contain `oldName` are left intact, matching the save.
    func replacementCounts(
        personID: UUID, oldName: String, newName: String
    ) throws -> TextReplacementCounts {
        _ = try requirePerson(personID)
        let newName = PersonFieldRules.normalizeName(newName)
        let protecting = try protectedNames(containing: oldName, excluding: [personID])
        let meetings = try personUseIndex().meetings(of: personID)
        func changes(_ text: String) -> Bool {
            NameReplacement.count(
                of: oldName, replacingWith: newName, in: text, protecting: protecting
            ) > 0
        }
        return TextReplacementCounts(
            summaries: meetings.count(where: { changes($0.summary) }),
            titles: meetings.count(where: { changes($0.title) })
        )
    }

    /// Meetings with at least one transcript version where the two people
    /// are assigned to *different* speakers (the merge warning), newest first.
    func sharedTranscriptMeetings(_ first: UUID, _ second: UUID) throws -> [PersonMeetingData] {
        try context.fetch(FetchDescriptor<Meeting>())
            .filter { meeting in
                meeting.transcripts.contains { transcript in
                    let assigned = Set(transcript.speakerAssignments.values.map(\.personID))
                    return assigned.contains(first) && assigned.contains(second)
                }
            }
            .map {
                PersonMeetingData(
                    id: $0.id, title: $0.title, date: $0.effectiveDate, roles: .speaker
                )
            }
            .sorted { $0.date > $1.date }
    }
}

// MARK: - Mutations

public extension DataStore {
    /// Renames a person and/or changes their email, in one save.
    ///
    /// The name is checked for collisions only when it changed, so an
    /// existing same-name pair does not block an email edit. A name
    /// collision is reported before an email collision. With
    /// `replaceInText`, the old name is also replaced in the summaries and
    /// titles of the person's meetings.
    func updatePerson(
        id personID: UUID, name: String, email: String?, replaceInText: Bool
    ) throws {
        let person = try requirePerson(personID)
        let newName = PersonFieldRules.normalizeName(name)
        let newEmail = PersonFieldRules.normalizeEmail(email)
        if let error = PersonFieldRules.validateName(newName)
            ?? PersonFieldRules.validateEmail(newEmail)
        {
            throw PersonEditError.invalid(error)
        }

        let nameChanged = newName != person.name
        if nameChanged || newEmail != person.email?.lowercased() {
            let others = try context.fetch(FetchDescriptor<Person>()).filter { $0.id != personID }
            if nameChanged,
               let other = others.first(where: {
                   PersonFieldRules.namesCollide(PersonFieldRules.normalizeName($0.name), newName)
               })
            {
                throw PersonEditError.nameCollision(personData(other))
            }
            if let newEmail, newEmail != person.email?.lowercased(),
               let other = others.first(where: { $0.email?.lowercased() == newEmail })
            {
                throw PersonEditError.emailCollision(personData(other))
            }
        }

        if replaceInText, nameChanged {
            try applyNameReplacement(
                old: person.name, new: newName,
                in: personUseIndex().meetings(of: personID),
                protecting: protectedNames(containing: person.name, excluding: [personID])
            )
        }
        person.name = newName
        person.email = newEmail
        try save()
    }

    /// Merges `source` into `target` in one save: every speaker assignment
    /// (all transcript versions, `userSet` kept), attendee, organizer, and
    /// current-user mark moves to the target, which takes the chosen name
    /// and email; the source is deleted. Voiceprints are not touched: they
    /// get their label from the assignments.
    func mergePeople(sourceID: UUID, targetID: UUID, choice: PersonMergeChoice) throws {
        guard sourceID != targetID else {
            // Nothing to merge: apply the choice as a plain edit.
            return try updatePerson(
                id: sourceID, name: choice.name, email: choice.email,
                replaceInText: choice.replaceSourceName
            )
        }
        let source = try requirePerson(sourceID)
        let target = try requirePerson(targetID)
        let finalName = PersonFieldRules.normalizeName(choice.name)
        let finalEmail = PersonFieldRules.normalizeEmail(choice.email)
        if let error = PersonFieldRules.validateName(finalName)
            ?? PersonFieldRules.validateEmail(finalEmail)
        {
            throw PersonEditError.invalid(error)
        }
        // The chosen email must not belong to a third person (§3.2).
        if let finalEmail,
           let other = try context.fetch(FetchDescriptor<Person>()).first(where: {
               $0.id != sourceID && $0.id != targetID && $0.email?.lowercased() == finalEmail
           })
        {
            throw PersonEditError.emailCollision(personData(other))
        }

        // Taken before the re-pointing so each old name is replaced only in
        // the meetings of the person who had it.
        let index = try personUseIndex()
        if choice.replaceSourceName {
            try applyNameReplacement(
                old: source.name, new: finalName, in: index.meetings(of: sourceID),
                protecting: protectedNames(containing: source.name, excluding: [sourceID])
            )
        }
        if choice.replaceTargetName {
            try applyNameReplacement(
                old: target.name, new: finalName, in: index.meetings(of: targetID),
                protecting: protectedNames(containing: target.name, excluding: [targetID])
            )
        }
        for meeting in index.meetings.values {
            repointUses(in: meeting, from: source, to: target)
        }

        target.name = finalName
        target.email = finalEmail
        context.delete(source)
        try save()
    }

    /// Deletes a person that no meeting uses. Throws
    /// `PersonEditError.inUse` when the person has gained a use since the
    /// caller last looked.
    func deleteUnusedPerson(id personID: UUID) throws {
        let person = try requirePerson(personID)
        let count = try personUseIndex().meetingCount(of: personID)
        guard count == 0 else {
            throw PersonEditError.inUse(meetingCount: count)
        }
        context.delete(person)
        try save()
    }
}

private func personData(_ person: Person) -> PersonData {
    PersonData(id: person.id, name: person.name, email: person.email)
}
