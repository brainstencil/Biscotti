import Foundation
import Testing
@testable import MeetingChat

@Suite("ChatSelection")
struct ChatSelectionTests {
    @Test("query terms are lowercased words of three or more characters that are not stopwords")
    func queryTermsDropStopwordsAndShortWords() {
        #expect(ChatSelection.queryTerms(in: "What did Kate say about the BATTERY life, in Q3's plan-B?") == ["kate", "battery", "life", "plan"])
        #expect(ChatSelection.queryTerms(in: "Was it 2026 or 25?") == ["2026"])
    }

    @Test("windows with equal scores go to the later one")
    func tiesGoToLaterWindow() {
        // Each window is one 24-character line: about 7 tokens. The opening keeps
        // the first two; a budget of 25 leaves room for one more.
        let selection = ChatSelection.select(entries: Self.fiveWindows(), question: "Anything new?", isLive: false, transcriptBudget: 25)

        #expect(selection.kept == [0, 1, 4])
        #expect(selection.evidenceTimes == [0, 60, 240])
        #expect(selection.transcript.contains("[1:00] Speaker 2: Hello.\n[2:00–4:00 not included]\n[4:00] Speaker 1: Hello."))
    }

    @Test("a dropped end of the transcript is marked too")
    func trailingOmissionIsMarked() {
        let selection = ChatSelection.select(entries: Self.fiveWindows(), question: "Anything new?", isLive: false, transcriptBudget: 0)

        #expect(selection.kept == [0, 1])
        #expect(selection.transcript.hasSuffix("[1:00] Speaker 2: Hello.\n[2:00–4:00 not included]"))
    }

    @Test("dropping removes the lowest-scoring optional window first, never the always-kept ones")
    func dropsLowestScoreFirst() {
        let entries = Self.entries([
            (0, "Hello."), (60, "Hello."), (120, "The battery is fine."), (180, "A battery and a magnet."), (240, "Nothing much.")
        ])
        var selection = ChatSelection.select(entries: entries, question: "battery magnet", isLive: false, transcriptBudget: 1000)
        #expect(selection.kept == [0, 1, 2, 3, 4])

        var dropped: [Set<Int>] = []
        while selection.dropLowestScoringOptional() {
            dropped.append(selection.kept)
        }

        #expect(dropped == [[0, 1, 2, 3], [0, 1, 3], [0, 1]])
    }

    @Test("a live transcript keeps every window reaching into its last five minutes")
    func liveKeepsEnd() {
        let entries = Self.entries((0 ..< 20).map { (Double($0) * 60, "Hello.") })

        let selection = ChatSelection.select(entries: entries, question: "Anything?", isLive: true, transcriptBudget: 0)

        // The last line starts at 19:00, so the last five minutes start at 14:00.
        #expect(selection.kept == Set([0, 1] + Array(14 ..< 20)))
    }

    // MARK: - Helpers

    private static func fiveWindows() -> [ChatEvidenceEntry] {
        entries((0 ..< 5).map { (Double($0) * 60, "Hello.") })
    }

    /// One saved line per item, speakers alternating so no lines merge.
    private static func entries(_ lines: [(TimeInterval, String)]) -> [ChatEvidenceEntry] {
        let segments = lines.enumerated().map { index, line in
            ChatFixtures.segment(line.0, line.0 + 2, line.1, speaker: index % 2)
        }
        return ChatEvidence.entries(for: .saved(ChatFixtures.saved(segments)))
    }
}
