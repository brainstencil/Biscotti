import Foundation
import LiveTranscriptModel

/// Where the Transcript tab reads a meeting's live draft.
///
/// `MeetingDetailViewModel` reads no drafts unless it is given a source.
/// A source's drafts should be observable, so the view updates when a
/// draft changes.
public struct LiveDraftSource: Sendable {
    public var draft: @MainActor @Sendable (UUID) -> LiveTranscriptSnapshot?

    public init(draft: @escaping @MainActor @Sendable (UUID) -> LiveTranscriptSnapshot?) {
        self.draft = draft
    }

    /// No live transcription: no drafts.
    public static var none: LiveDraftSource {
        LiveDraftSource(draft: { _ in nil })
    }
}
