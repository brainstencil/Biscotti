import DataStore
import Formatting
import Foundation

/// User-facing strings for people management (ui_design.md §5), kept in
/// one place so the models and tests share them.
enum PeopleCopy {
    static func quoted(_ text: String) -> String {
        "\u{201C}\(text)\u{201D}"
    }

    static func meetings(_ count: Int) -> String {
        count == 1 ? "1 meeting" : "\(count) meetings"
    }

    static func fieldError(_ error: PersonFieldError) -> String {
        switch error {
        case .emptyName: "Enter a name."
        case .nameTooLong: "Keep names under \(PersonFieldRules.maxNameLength) characters."
        case .invalidEmail: "Enter a valid email address, or leave it empty."
        }
    }

    /// `Also change "Steven" to "Stephen" in 3 summaries and 1 title`.
    /// Parts with a count of 0 are left out.
    static func replaceLabel(old: String, new: String, counts: TextReplacementCounts) -> String {
        var parts: [String] = []
        if counts.summaries > 0 {
            parts.append(counts.summaries == 1 ? "1 summary" : "\(counts.summaries) summaries")
        }
        if counts.titles > 0 {
            parts.append(counts.titles == 1 ? "1 title" : "\(counts.titles) titles")
        }
        return "Also change \(quoted(old)) to \(quoted(new)) in \(parts.joined(separator: " and "))"
    }

    static func replaceOffCaption(old: String) -> String {
        "Summaries and titles that mention \(quoted(old)) will keep the old name."
    }

    static func collisionTitle(_ collision: PersonCollision) -> String {
        switch collision {
        case let .name(person): "\(quoted(person.name)) is already a person."
        case let .email(email, person): "\(email) already belongs to \(person.name)."
        }
    }

    static let collisionHelp =
        "If they\u{2019}re the same person, merge them. Otherwise, choose a different name."

    static func mergeButton(_ collision: PersonCollision) -> String {
        "Merge with \(collision.person.name)\u{2026}"
    }

    static func meetingsHeading(_ count: Int) -> String {
        count == 1 ? "Changes apply to this meeting" : "Changes apply to these \(count) meetings"
    }

    static func roles(_ roles: PersonRoles) -> String {
        var names: [String] = []
        if roles.contains(.speaker) { names.append("Speaker") }
        if roles.contains(.attendee) { names.append("Attendee") }
        if roles.contains(.organizer) { names.append("Organizer") }
        return names.joined(separator: " \u{00B7} ")
    }

    static func overviewMeta(_ row: PersonOverviewData) -> String {
        guard row.meetingCount > 0, let lastSeen = row.lastSeen else {
            return "Not in any meetings"
        }
        return "\(meetings(row.meetingCount)) \u{00B7} \(TimeFormatting.shortDate(lastSeen))"
    }

    static func deleteHelp(meetingCount: Int) -> String {
        meetingCount == 0
            ? "Delete"
            : "In use in \(meetings(meetingCount)). Reassign or merge to remove."
    }

    static func mergeSubtitle(source: String, target: String, meetingCount: Int) -> String {
        "\(source)\u{2019}s \(meetings(meetingCount)) move to \(target). \(source) is removed."
    }

    static func sharedHeading(_ count: Int) -> String {
        count == 1 ? "Both are speakers in 1 meeting" : "Both are speakers in \(count) meetings"
    }

    static func sharedBody(target: String) -> String {
        "Both speakers will show as \(target) in:"
    }

    static let missingPerson = "This person no longer exists."
    static let saveFailed = "Couldn\u{2019}t save the changes. Try again."
    static let mergeIrreversible = "Merging can\u{2019}t be undone."
    static let peopleEmpty =
        "No people yet. Biscotti adds people when it identifies speakers or when a meeting is linked to a calendar event."

    static func noMatch(_ filter: String) -> String {
        "No people match \(quoted(filter))."
    }
}
