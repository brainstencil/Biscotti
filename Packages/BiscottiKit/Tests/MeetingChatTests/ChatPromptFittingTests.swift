import Foundation
import LiveTranscriptModel
import LocalLLM
import Testing
@testable import MeetingChat

/// Fitting a meeting too long for the context: selection, its retries and its ratio.
@Suite("ChatPromptBuilder long meetings")
struct ChatPromptFittingTests {
    @Test("selection always keeps the opening and the last five minutes of a live transcript")
    func selectionKeepsStartAndEnd() async throws {
        let snapshot = Self.threeHourLive()

        let prompt = try await ChatFixtures.build(ChatFixtures.record(.live(snapshot)), turns: Self.threeTurns, question: "What about battery life?")

        #expect(prompt.isPartial)
        let starts = snapshot.rows.map(\.startTime)
        let kept = Set(prompt.evidenceTimes)
        #expect(starts.filter { $0 < 120 }.allSatisfy(kept.contains))
        #expect(starts.filter { $0 >= starts[starts.count - 1] - 300 }.allSatisfy(kept.contains))
        #expect(prompt.messages.count == 6) // the system message, two turns, the question
    }

    @Test("selection keeps the window that shares the question's words")
    func selectionPrefersMatchingWindows() async throws {
        let snapshot = Self.threeHourLive()

        let prompt = try await ChatFixtures.build(ChatFixtures.record(.live(snapshot)), question: "What about battery life?")

        #expect(prompt.evidenceTimes.contains(5000))
        #expect(!prompt.evidenceTimes.contains(5040))
        #expect(prompt.evidenceTimes.count < snapshot.rows.count / 2)
    }

    @Test("dropped stretches are marked and the partial rule is added")
    func selectionMarksOmissions() async throws {
        let prompt = try await ChatFixtures.build(ChatFixtures.record(.live(Self.threeHourLive())), question: "What about battery life?")

        let system = ChatFixtures.systemText(prompt)
        #expect(prompt.isPartial)
        #expect(system.contains(ChatPrompts.partialRule))
        #expect(system.contains("[1:55] Others: \(Self.filler)\n[2:00–1:23:00 not included]\n[1:23:00] Others: \(Self.filler)"))
        #expect(system.contains("[1:24:00–"))
    }

    @Test("after selection, evidence times are the starts of the lines given")
    func evidenceTimesMatchLinesGiven() async throws {
        let prompt = try await ChatFixtures.build(ChatFixtures.record(.live(Self.threeHourLive())), question: "What about battery life?")

        let system = ChatFixtures.systemText(prompt)
        let givenTimes = system.split(separator: "\n")
            .filter { $0.contains("] Others: ") }
            .map { String($0.prefix { $0 != "]" }.dropFirst()) }
        #expect(givenTimes == prompt.evidenceTimes.map(ChatEvidence.format))
    }

    @Test("selection drops its least related windows until the real count fits")
    func selectionDropsWindowsUntilItFits() async throws {
        // A selected transcript counts 6,000 tokens more than its characters suggest.
        let counter = RecordingCounter { Self.characterCount($0, extraWhenSelected: 6000) }

        let prompt = try await ChatFixtures.build(ChatFixtures.record(.live(Self.threeHourLive())), count: { await counter.count($0) })

        #expect(prompt.isPartial)
        #expect(prompt.contextSize == ChatPromptBuilder.maxContext)
        #expect(await counter.attempts.count >= 4)
    }

    @Test("selection gives up after five drops")
    func selectionGivesUpAfterFiveDrops() async throws {
        let counter = RecordingCounter { Self.characterCount($0, extraWhenSelected: 20000) }

        await #expect(throws: ChatPromptError.tooLong) {
            try await ChatFixtures.build(ChatFixtures.record(.live(Self.threeHourLive())), count: { await counter.count($0) })
        }
        // The whole prompt, the prompt without a transcript, then the selection and five smaller ones.
        #expect(await counter.attempts.count == 8)
    }

    @Test("selection measures the transcript's characters per token, so dense text still fits")
    func measuredRatioFitsDenseText() async throws {
        // 1.5 characters per token, as in Chinese or Russian text. At the English
        // estimate of 3.5, selection would overshoot more than five drops can fix.
        let counter = RecordingCounter { messages in messages.reduce(0) { $0 + $1.content.count } * 2 / 3 }

        let prompt = try await ChatFixtures.build(ChatFixtures.record(.live(Self.threeHourLive())), question: "What about battery life?", count: { await counter.count($0) })

        #expect(prompt.isPartial)
        #expect(prompt.evidenceTimes.contains(5000))
        // The whole prompt, the prompt without a transcript, and the selection, which fits at once.
        #expect(await counter.attempts.count == 3)
    }

    @Test("the characters-per-token ratio falls back to 3.5 without a measurement")
    func charactersPerTokenFallsBack() {
        #expect(ChatPromptBuilder.charactersPerToken(transcriptCharacters: 3000, transcriptTokens: 2000) == 1.5)
        #expect(ChatPromptBuilder.charactersPerToken(transcriptCharacters: 3000, transcriptTokens: 0) == 3.5)
        #expect(ChatPromptBuilder.charactersPerToken(transcriptCharacters: 3000, transcriptTokens: -40) == 3.5)
        #expect(ChatPromptBuilder.charactersPerToken(transcriptCharacters: 0, transcriptTokens: 100) == 3.5)
    }

    @Test("a prompt that never fits throws tooLong")
    func tooLongThrows() async {
        await #expect(throws: ChatPromptError.tooLong) {
            try await ChatFixtures.build(ChatFixtures.record(.live(Self.threeHourLive())), turns: Self.threeTurns, count: { _ in ChatPromptBuilder.maxContext + 1 })
        }
    }

    // MARK: - Helpers

    private static let filler = "We went over the schedule and the budget again in some detail, and then we went over the "
        + "staffing plan and the hiring timeline for the next two quarters, then the vendor contracts and the travel "
        + "policy, and finally the room bookings for the offsite in the spring, which still needs a decision."

    /// A token per four characters, plus `extraWhenSelected` once selection has left parts out.
    private static func characterCount(_ messages: [LLMMessage], extraWhenSelected: Int) -> Int {
        let isSelected = messages.first?.content.contains("not included]") ?? false
        return ChatFixtures.tokens(messages) + (isSelected ? extraWhenSelected : 0)
    }

    private static let threeTurns = (1 ... 3).map { ChatTurn(question: "Question \($0)", answer: "Answer \($0)") }

    /// Three hours of "Others", a row every 5 s; the row at 5000 s (1:23:20) is about the battery.
    private static func threeHourLive() -> LiveTranscriptSnapshot {
        ChatFixtures.longLive(
            duration: 3 * 3600,
            spacing: 5,
            filler: filler,
            special: [1000: "The battery life should last about a year with normal use."]
        )
    }
}
