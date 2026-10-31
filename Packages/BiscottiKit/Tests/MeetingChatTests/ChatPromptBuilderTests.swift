import DataStore
import Foundation
import LiveTranscriptModel
import LocalLLM
import Testing
@testable import MeetingChat

@Suite("ChatPromptBuilder")
struct ChatPromptBuilderTests {
    private let shortLive = ChatFixtures.snapshot(rows: [
        LiveRow(track: .system, startTime: 3, endTime: 8, settledText: "Let's design the remote."),
        LiveRow(track: .system, startTime: 21, endTime: 26, settledText: "What if I had a magnet on the back", tailText: " of it and")
    ])

    private let shortSaved = ChatFixtures.saved([
        ChatFixtures.segment(0, 4, "Battery life matters most."),
        ChatFixtures.segment(9, 12, "Agreed.", speaker: 1)
    ])

    // MARK: - Layout

    @Test("the system message holds the rules, then the meeting, the transcript and the notes")
    func orderIsRulesMeetingTranscriptNotes() async throws {
        let prompt = try await ChatFixtures.build(ChatFixtures.record(.saved(shortSaved)))

        let system = ChatFixtures.systemText(prompt)
        #expect(system.hasPrefix("You answer questions about one meeting, using only the meeting record below."))
        let positions = try ["- Write short Markdown", "<meeting>", "<transcript>", "[0:00] Speaker 1: Battery life", "<notes>", "1:05 Ask Kate"]
            .map { try #require(system.range(of: $0)).lowerBound }
        #expect(positions == positions.sorted())
        #expect(prompt.messages.map(\.role) == [.system, .user])
        #expect(prompt.messages.last?.content == "What did they decide?")
        #expect(!prompt.isPartial)
        #expect(!system.contains(ChatPrompts.partialRule))
    }

    @Test("a live transcript says how far it reaches after the transcript, and keeps the braces rule")
    func liveTranscriptLine() async throws {
        let record = ChatFixtures.record(.live(shortLive))

        let utc = try #require(TimeZone(identifier: "UTC"))

        let prompt = try await ChatFixtures.build(record)

        #expect(ChatPrompts.meetingBlock(record, timeZone: utc) == """
        Title: Remote control design
        Date: Tuesday, 27 October 2026, 6:04 PM
        Invited (not proof of who spoke): Kate, Bill
        Transcript: live, recording in progress
        """)
        let system = ChatFixtures.systemText(prompt)
        #expect(system.contains("{of it and}\n</transcript>\n\nThe live transcript above runs through 0:46. The recording continues.\n\n<notes>"))
        #expect(system.contains(ChatPrompts.unsettledRule))
        #expect(system.contains("[0:21] Others: What if I had a magnet on the back {of it and}"))
        #expect(prompt.basis == .live(through: 46))
    }

    @Test("a saved transcript reads final and a draft reads draft, neither with the braces rule")
    func savedAndDraftTranscriptLines() async throws {
        let saved = try await ChatFixtures.build(ChatFixtures.record(.saved(shortSaved)))
        let draft = try await ChatFixtures.build(ChatFixtures.record(.draft(shortLive)))

        #expect(ChatFixtures.systemText(saved).contains("Transcript: final"))
        #expect(saved.basis == .transcript(id: shortSaved.id))
        #expect(ChatFixtures.systemText(draft).contains("Transcript: draft, made during the recording"))
        #expect(draft.basis == .draft)
        for prompt in [saved, draft] {
            #expect(!ChatFixtures.systemText(prompt).contains("{braces}"))
            #expect(!ChatFixtures.systemText(prompt).contains("{"))
            #expect(!ChatFixtures.systemText(prompt).contains("The recording continues"))
        }
    }

    @Test("a live transcript that has grown keeps the old prompt up to its last stable line")
    func grownLiveTranscriptSharesPrefix() async throws {
        let settled = LiveRow(track: .system, startTime: 3, endTime: 8, settledText: "Let's design the remote.", isClosed: true)
        let openID = UUID()
        let before = ChatFixtures.snapshot(
            rows: [settled, LiveRow(id: openID, track: .mic, startTime: 21, endTime: 24, settledText: "What if", tailText: " I had")],
            through: 30
        )
        let after = ChatFixtures.snapshot(
            rows: [
                settled,
                LiveRow(id: openID, track: .mic, startTime: 21, endTime: 28, settledText: "What if I had a magnet"),
                LiveRow(track: .system, startTime: 40, endTime: 44, settledText: "Sure.")
            ],
            through: 46
        )

        let old = try await ChatFixtures.systemText(ChatFixtures.build(ChatFixtures.record(.live(before))))
        let new = try await ChatFixtures.systemText(ChatFixtures.build(ChatFixtures.record(.live(after))))

        let stableEnd = try #require(old.range(of: "[0:03] Others: Let's design the remote.\n")).upperBound
        #expect(new.hasPrefix(old[..<stableEnd]))
        #expect(old.contains("runs through 0:30"))
        #expect(new.contains("runs through 0:46"))
    }

    @Test("blank notes and no invitees leave their parts out")
    func emptyNotesAndInviteesLeftOut() async throws {
        let prompt = try await ChatFixtures.build(ChatFixtures.record(.saved(shortSaved), invitees: [], notes: " \n "))

        let system = ChatFixtures.systemText(prompt)
        #expect(!system.contains("<notes>"))
        #expect(!system.contains("Invited (not proof of who spoke)"))
        #expect(system.contains("<transcript>"))
    }

    @Test("a blank title and a missing date leave their lines out")
    func missingTitleAndDateLeftOut() {
        var record = ChatFixtures.record(.saved(shortSaved), title: " ")
        record.date = nil

        #expect(ChatPrompts.meetingBlock(record) == "Invited (not proof of who spoke): Kate, Bill\nTranscript: final")
    }

    @Test("earlier turns alternate before the question; blank answers and turns past six are left out")
    func earlierTurnsAlternate() async throws {
        let turns = [
            ChatTurn(question: "Who spoke first?", answer: "Speaker 1 [0:00]."),
            ChatTurn(question: "Why?", answer: " "),
            ChatTurn(question: "Anything about batteries?", answer: "Battery life matters most [0:00].")
        ]

        let prompt = try await ChatFixtures.build(ChatFixtures.record(.saved(shortSaved)), turns: turns)

        #expect(prompt.messages.map(\.role) == [.system, .user, .assistant, .user, .assistant, .user])
        #expect(prompt.messages.dropFirst().map(\.content) == [
            "Who spoke first?", "Speaker 1 [0:00].",
            "Anything about batteries?", "Battery life matters most [0:00].",
            "What did they decide?"
        ])

        let many = (1 ... 8).map { ChatTurn(question: "Question \($0)", answer: "Answer \($0)") }
        let trimmed = try await ChatFixtures.build(ChatFixtures.record(.saved(shortSaved)), turns: many)
        #expect(trimmed.messages.count == 14) // the system message, six turns, the question
        #expect(trimmed.messages[1].content == "Question 3")
    }

    @Test("answers use fixed generation options")
    func optionsAreFixed() async throws {
        let prompt = try await ChatFixtures.build(ChatFixtures.record(.saved(shortSaved)))

        #expect(prompt.options.maxTokens == 1024)
        #expect(prompt.options.temperature == 0.3)
        #expect(prompt.options.thinking == .off)
        #expect(prompt.options.topK == GenerationOptions.default.topK)
    }

    @Test("evidence times are the lines' starts, without gaps")
    func evidenceTimesOfWholeTranscript() async throws {
        let snapshot = ChatFixtures.snapshot(
            rows: [LiveRow(track: .system, startTime: 3, endTime: 5, settledText: "One."), LiveRow(track: .mic, startTime: 30, endTime: 32, settledText: "Two.")],
            gaps: [LiveGap(track: .mic, startTime: 10, duration: 10, reason: .engineRestart)]
        )

        let prompt = try await ChatFixtures.build(ChatFixtures.record(.live(snapshot)))

        #expect(prompt.evidenceTimes == [3, 30])
        #expect(ChatFixtures.systemText(prompt).contains("[0:03] Others: One.\n[0:10–0:20 not transcribed]\n[0:30] You: Two."))
    }

    // MARK: - Context size

    @Test("the context rounds up to a multiple of 4,096 and stays the same across a thread")
    func contextRoundsTo4096() async throws {
        let fixed = try await ChatFixtures.build(ChatFixtures.record(.saved(shortSaved)), count: { _ in 9000 })
        #expect(fixed.contextSize == 12288)
        #expect(ChatPromptBuilder.contextSize(promptTokens: 47616) == ChatPromptBuilder.maxContext)

        let longer = ChatFixtures.saved((0 ..< 120).map {
            ChatFixtures.segment(Double($0) * 10, Double($0) * 10 + 8, String(repeating: "We talked about the plan. ", count: 11), speaker: $0 % 2)
        })
        let record = ChatFixtures.record(.saved(longer))
        let first = try await ChatFixtures.build(record, question: "What was the plan?")
        let second = try await ChatFixtures.build(record, turns: [ChatTurn(question: "What was the plan?", answer: "They talked about the plan [0:00].")], question: "And then?")
        #expect(first.contextSize == second.contextSize)
        #expect(first.contextSize % 4096 == 0)
        #expect(first.contextSize >= ChatFixtures.tokens(first.messages) + ChatPromptBuilder.answerReserve)
    }

    // MARK: - Long meetings

    @Test("a prompt that is too long drops the oldest turns before selecting passages")
    func longMeetingDropsTurnsFirst() async throws {
        let turns = (1 ... 5).map { ChatTurn(question: "Question \($0)", answer: String(repeating: "word ", count: 8000)) }
        let counter = RecordingCounter()

        let prompt = try await ChatFixtures.build(ChatFixtures.record(.saved(shortSaved)), turns: turns, count: { await counter.count($0) })

        #expect(!prompt.isPartial)
        #expect(prompt.messages.count == 10) // the system message, four turns, the question
        #expect(prompt.messages[1].content == "Question 2")
        #expect(await counter.attempts.count == 2)
    }

    @Test("errors from the token counter reach the caller")
    func countErrorsPropagate() async {
        struct CountFailed: Error {}

        await #expect(throws: CountFailed.self) {
            try await ChatFixtures.build(ChatFixtures.record(.saved(shortSaved)), count: { _ in throw CountFailed() })
        }
    }
}
