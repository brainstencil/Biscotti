import Foundation

/// What a meeting's chat keeps across launches: the thread that was open and
/// the half-typed question. The threads themselves are in the store; this
/// keeps only the open thread's ID, which `load(meetingID:)` reopens from
/// there. One key per meeting for each, removed when there is nothing to keep.
struct ChatRestore {
    static let openThreadKeyPrefix = "meetingChat.openThread."
    static let draftKeyPrefix = "meetingChat.draft."

    /// Nil keeps nothing: the chat starts empty on each launch.
    let defaults: UserDefaults?

    func openThreadID(meetingID: UUID) -> UUID? {
        defaults?.string(forKey: Self.openThreadKey(meetingID)).flatMap(UUID.init(uuidString:))
    }

    func keepOpenThreadID(_ threadID: UUID?, meetingID: UUID) {
        let key = Self.openThreadKey(meetingID)
        if let threadID {
            defaults?.set(threadID.uuidString, forKey: key)
        } else {
            defaults?.removeObject(forKey: key)
        }
    }

    func draft(meetingID: UUID) -> String {
        defaults?.string(forKey: Self.draftKey(meetingID)) ?? ""
    }

    func keepDraft(_ draft: String, meetingID: UUID) {
        let key = Self.draftKey(meetingID)
        if draft.isEmpty {
            defaults?.removeObject(forKey: key)
        } else {
            defaults?.set(draft, forKey: key)
        }
    }

    /// A deleted meeting keeps nothing.
    func forget(meetingID: UUID) {
        keepOpenThreadID(nil, meetingID: meetingID)
        keepDraft("", meetingID: meetingID)
    }

    static func openThreadKey(_ meetingID: UUID) -> String {
        openThreadKeyPrefix + meetingID.uuidString
    }

    static func draftKey(_ meetingID: UUID) -> String {
        draftKeyPrefix + meetingID.uuidString
    }
}
