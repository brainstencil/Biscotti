import Foundation
import SwiftUI
import Testing
@testable import TranscriptUI

private func bubble(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptItem {
    TranscriptItem(id: id, kind: .bubble(Bubble(side: .leading, startTime: start, endTime: end, settledText: id)))
}

/// A chat time chip highlights the bubble it cites for 2 s.
@Suite("TranscriptHighlight")
@MainActor
struct TranscriptHighlightTests {
    private let items = [bubble("a", 0, 5), bubble("b", 5, 9), bubble("c", 12, 15)]

    @Test("The highlight falls on the bubble holding its time, else the one before it")
    func highlightResolvesToContainingItem() {
        let now = Date()
        #expect(TranscriptBubbleList<EmptyView>.highlightedItemID(TranscriptHighlight(time: 6, now: now), in: items) == "b")
        #expect(TranscriptBubbleList<EmptyView>.highlightedItemID(TranscriptHighlight(time: 10, now: now), in: items) == "b")
        #expect(TranscriptBubbleList<EmptyView>.highlightedItemID(TranscriptHighlight(time: 12, now: now), in: items) == "c")
        #expect(TranscriptBubbleList<EmptyView>.highlightedItemID(nil, in: items) == nil)
        #expect(TranscriptBubbleList<EmptyView>.highlightedItemID(TranscriptHighlight(time: 6, now: now), in: []) == nil)
    }

    @Test("The highlight lasts 2 s from when it is set, then fades over 0.6 s")
    func highlightClearsAfterTwoSeconds() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let highlight = TranscriptHighlight(time: 34, now: start)

        #expect(highlight.until == start.addingTimeInterval(2))
        #expect(highlight.remaining(at: start) == 2)
        #expect(highlight.remaining(at: start.addingTimeInterval(1.5)) == 0.5)
        #expect(highlight.remaining(at: start.addingTimeInterval(2)) == 0)
        #expect(highlight.remaining(at: start.addingTimeInterval(9)) == 0, "never negative")
        #expect(TranscriptHighlight.fadeDuration == 0.6)
    }

    @Test("A row re-renders when the highlight comes or goes")
    func highlightChangesRowEquality() {
        let item = items[0]
        func row(_ isHighlighted: Bool) -> TranscriptItemRow {
            TranscriptItemRow(
                item: item, highlights: .none, canSeek: true, isHighlighted: isHighlighted,
                onSeek: { _ in }, onSpeaker: { _ in }, onSpeakerDebug: nil
            )
        }

        #expect(row(true) == row(true))
        #expect(row(true) != row(false))
    }
}
