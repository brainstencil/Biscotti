import DataStore
import Foundation

/// The merge dialog's choices (functional spec §3.3). The edited person is
/// the source and is removed; the person it collided with is the target
/// and survives.
public struct MergeDraft: Equatable, Sendable {
    public let source: PersonData
    public let target: PersonData
    /// The normalized name typed in the editor.
    public let typedName: String
    /// The normalized email typed in the editor, or nil.
    public let typedEmail: String?
    public let sourceMeetingCount: Int

    public let nameOptions: [String]
    public var name: String
    /// Email choices; `nil` stands for "None".
    public let emailOptions: [String?]
    public var email: String?

    public var replaceSource = true
    public var replaceTarget = true
    public var sourceCounts = TextReplacementCounts(summaries: 0, titles: 0)
    public var targetCounts = TextReplacementCounts(summaries: 0, titles: 0)
    /// Meetings where the two people are different speakers in one transcript.
    public var sharedMeetings: [PersonMeetingData] = []

    public init(
        source: PersonData, target: PersonData,
        typedName: String, typedEmail: String?,
        sourceMeetingCount: Int
    ) {
        self.source = source
        self.target = target
        self.typedName = typedName
        self.typedEmail = typedEmail
        self.sourceMeetingCount = sourceMeetingCount
        nameOptions = Self.nameOptions(typed: typedName, source: source.name, target: target.name)
        name = typedName
        emailOptions = Self.emailOptions(typed: typedEmail, source: source.email, target: target.email)
        email = Self.defaultEmail(typed: typedEmail, source: source.email, target: target.email)
    }

    /// Typed, target, then source; identical names appear once.
    static func nameOptions(typed: String, source: String, target: String) -> [String] {
        var options: [String] = []
        for name in [typed, target, source] where !options.contains(name) {
            options.append(name)
        }
        return options
    }

    /// Typed, target, then source emails (lowercased, deduplicated), then None.
    static func emailOptions(typed: String?, source: String?, target: String?) -> [String?] {
        var options: [String?] = []
        for email in [typed, target, source].compactMap({ $0?.lowercased() })
            where !options.contains(email)
        {
            options.append(email)
        }
        options.append(nil)
        return options
    }

    /// The typed email if one was entered, else the target's, else the source's.
    static func defaultEmail(typed: String?, source: String?, target: String?) -> String? {
        (typed ?? target ?? source)?.lowercased()
    }

    public var showsSourceReplace: Bool {
        !sourceCounts.isEmpty
    }

    public var showsTargetReplace: Bool {
        !targetCounts.isEmpty
    }

    public var choice: PersonMergeChoice {
        PersonMergeChoice(
            name: name, email: email,
            replaceSourceName: replaceSource && showsSourceReplace,
            replaceTargetName: replaceTarget && showsTargetReplace
        )
    }

    // MARK: - Copy

    public var title: String {
        "\(source.name) \u{2192} \(target.name)"
    }

    public var subtitle: String {
        PeopleCopy.mergeSubtitle(
            source: source.name, target: target.name, meetingCount: sourceMeetingCount
        )
    }

    public func isTypedName(_ option: String) -> Bool {
        option == typedName && option != source.name && option != target.name
    }

    public var sourceReplaceLabel: String {
        PeopleCopy.replaceLabel(old: source.name, new: name, counts: sourceCounts)
    }

    public var targetReplaceLabel: String {
        PeopleCopy.replaceLabel(old: target.name, new: name, counts: targetCounts)
    }

    public var sharedHeading: String {
        PeopleCopy.sharedHeading(sharedMeetings.count)
    }

    public var sharedBody: String {
        PeopleCopy.sharedBody(target: name)
    }

    public var irreversibleNote: String {
        PeopleCopy.mergeIrreversible
    }

    public func replaceOffCaption(old: String) -> String {
        PeopleCopy.replaceOffCaption(old: old)
    }
}
