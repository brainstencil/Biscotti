import Foundation

/// The find highlight a chat time leaves on the bubble it cites: the bubble
/// holding `time` fills with `findHighlightFocused` and shows its time until
/// `until`, then fades back.
public struct TranscriptHighlight: Equatable, Sendable {
    /// How long the highlight stays.
    public static let duration: TimeInterval = 2
    /// How long it takes to fade back.
    public static let fadeDuration: TimeInterval = 0.6

    /// The cited moment, on the transcript's timeline.
    public let time: TimeInterval
    public let until: Date

    public init(time: TimeInterval, now: Date = Date()) {
        self.time = time
        until = now.addingTimeInterval(Self.duration)
    }

    /// The time left before it fades, never negative.
    public func remaining(at now: Date) -> TimeInterval {
        max(0, until.timeIntervalSince(now))
    }
}
