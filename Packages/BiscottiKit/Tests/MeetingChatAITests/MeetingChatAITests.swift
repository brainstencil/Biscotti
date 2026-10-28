import DataStore
import Dispatch
import Foundation
import LocalLLM
import MeetingChat
import Synchronization
import Testing

private let isAITestEnabled =
    ProcessInfo.processInfo.environment["BISCOTTI_RUN_AI_TESTS"] == "1"

/// The real model answers fixed questions about a fixture meeting, with the
/// prompts chat sends, and at least 90% of the times it cites must point at
/// lines it was given.
///
/// Needs the model on disk (`LLM_MODEL_PATH`, or Gemma 4 12B in the app's
/// model folder) and `BISCOTTI_RUN_AI_TESTS=1`. Run via `make test-ai`.
@Suite("Meeting chat AI tests (BISCOTTI_RUN_AI_TESTS=1)", .enabled(if: isAITestEnabled), .serialized)
struct MeetingChatAITests {
    static let modelPath: URL = {
        if let path = ProcessInfo.processInfo.environment["LLM_MODEL_PATH"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Biscotti/llms")
            .appendingPathComponent("gemma-4-12b-it-UD-Q4_K_XL.gguf")
    }()

    static let connection = Mutex<LLMConnection?>(nil)

    /// Closes the model before ggml's Metal destructor runs at exit
    /// (see `IntelligenceAITests`).
    private static let registerAtexitOnce: Void = {
        atexit {
            let done = DispatchSemaphore(value: 0)
            Task {
                if let connection = MeetingChatAITests.connection.withLock({ $0 }) {
                    await connection.close()
                }
                LocalLLMRuntime.shutdown()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 30)
        }
    }()

    static func sharedConnection() async throws -> LLMConnection {
        if let existing = connection.withLock({ $0 }) {
            return existing
        }
        let opened = try await LLMService.openConnection(
            model: modelPath, backend: .inProcess, config: EngineConfig(contextSize: 4096, seed: 42)
        )
        connection.withLock { $0 = opened }
        _ = registerAtexitOnce
        return opened
    }

    static let questions = [
        "What did they decide about the battery?",
        "Who raised a concern about cost, and what was it?",
        "What are the next steps?",
        "When is the prototype due?",
        "Write a short follow-up email to the team."
    ]

    @Test("At least 90% of cited times point at lines the model was given")
    func citedTimesAreValid() async throws {
        let connection = try await Self.sharedConnection()
        let record = ChatMeetingRecord(
            title: "Remote control design",
            date: Date(timeIntervalSince1970: 1_793_124_240),
            invitees: ["Kate", "Bill"],
            notes: "Ask Kate about battery life.",
            transcript: .saved(MeetingChatAIFixture.transcript)
        )

        var cited = 0
        var valid = 0
        for question in Self.questions {
            let prompt = try await ChatPromptBuilder.build(
                record: record, earlierTurns: [], question: question,
                count: { try await connection.countTokens(messages: $0) }
            )
            try await connection.reconfigure(contextSize: prompt.contextSize)
            let answer = try await connection.generate(messages: prompt.messages, options: prompt.options).text
            print("[MeetingChatAITests] \(question)\n\(answer)\n---")

            let blocks = ChatAnswerParser.blocks(answer, evidenceTimes: prompt.evidenceTimes)
            cited += MeetingChatAIFixture.citationCount(in: answer)
            valid += blocks.reduce(0) { count, block in
                count + block.text.runs.count { $0[ChatTimeAttribute.self] != nil }
            }
        }

        print("[MeetingChatAITests] \(valid) of \(cited) cited times are valid")
        #expect(cited > 0, "the answers cite moments")
        #expect(Double(valid) >= 0.9 * Double(cited))
    }
}

/// A short design meeting with times and two speakers.
enum MeetingChatAIFixture {
    static let transcript = TranscriptData(
        id: UUID(),
        createdAt: Date(timeIntervalSince1970: 1_793_124_240),
        speakerCount: 3,
        segments: [
            line(0, 0, "Okay, let's start. Today we settle the remote control's battery and the case."),
            line(12, 1, "I looked at batteries. Two AAA cells last about eight months with normal use."),
            line(31, 0, "What about a rechargeable pack?"),
            line(38, 1, "It adds about four dollars to the cost of every unit, and it needs a charger in the box."),
            line(55, 2, "That is my concern. Four dollars is too much at our price point."),
            line(70, 0, "Agreed. We go with two AAA cells, and we revisit rechargeable for the premium model."),
            line(95, 2, "For the case, I would like the matte finish. It hides fingerprints."),
            line(110, 1, "Matte adds a week to tooling, but the cost is the same."),
            line(128, 0, "Fine, matte it is. Next steps: Bill orders the battery contacts this week."),
            line(145, 2, "And I will send the case drawings to the factory by Friday."),
            line(160, 0, "The first working prototype is due on the twelfth of November."),
            line(175, 1, "I will book the test lab for the week after that."),
            line(190, 0, "Great. Thanks, everyone.")
        ]
    )

    private static func line(_ start: TimeInterval, _ speaker: Int, _ text: String) -> SegmentData {
        SegmentData(id: UUID(), speakerID: speaker, speakerLabel: "Speaker \(speaker + 1)", startTime: start, endTime: start + 8, text: text)
    }

    /// Every time or range cited in brackets, as the parser counts them.
    static func citationCount(in answer: String) -> Int {
        let time = #/\d{1,2}:\d{2}(?::\d{2})?(?:\s*[–—-]\s*\d{1,2}:\d{2}(?::\d{2})?)?/#
        return answer.matches(of: #/\[[^\]\n]*\]/#).reduce(0) { count, bracket in
            count + answer[bracket.range].matches(of: time).count
        }
    }
}
