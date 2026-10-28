import DataStore
import Foundation
import LocalLLM

/// Builds the model's messages for one question, fitted to the context.
public enum ChatPromptBuilder {
    public static let maxContext = 48 * 1024
    public static let answerReserve = 1536
    public static let maxEarlierTurns = 6
    /// Turns kept when a long meeting needs room.
    static let minEarlierTurns = 2
    /// How many times selection drops a window and recounts before giving up.
    static let maxSelectionRetries = 5
    /// Context sizes are multiples of this, so the size stays the same between
    /// turns of a thread and the model keeps its cache.
    static let contextStep = 4096
    static let options = GenerationOptions(maxTokens: 1024, temperature: 0.3, thinking: .off)

    /// Builds the prompt, counting tokens with the model's tokenizer.
    /// - Throws: `ChatPromptError.tooLong` if even the smallest selection does not fit;
    ///   rethrows `count` errors.
    public static func build(
        record: ChatMeetingRecord,
        earlierTurns: [ChatTurn],
        question: String,
        count: @Sendable ([LLMMessage]) async throws -> Int
    ) async throws -> ChatPrompt {
        let parts = PromptParts(record: record, question: question)
        // Callers pass complete or stopped answers only (see `ChatTurn.answer`): the store
        // keeps a failed answer's partial text, so callers filter by its state. An answer
        // stopped before any text is blank; it and its question are left out.
        var turns = Array(earlierTurns.filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.suffix(maxEarlierTurns))

        let entries = ChatEvidence.entries(for: record.transcript)
        let whole = entries.map(\.formatted).joined(separator: "\n")
        let evidenceTimes = entries.compactMap(\.line?.start)
        var wholeTokens = 0
        while true {
            let messages = parts.messages(transcript: whole, isPartial: false, turns: turns)
            wholeTokens = try await count(messages)
            if fits(wholeTokens) {
                return parts.prompt(messages: messages, tokens: wholeTokens, evidenceTimes: evidenceTimes, isPartial: false)
            }
            guard turns.count > minEarlierTurns else { break }
            turns.removeFirst()
        }
        return try await selectPassages(entries, wholeTokens: wholeTokens, parts: parts, turns: turns, count: count)
    }

    /// The transcript's characters per token. The spec estimates 3.5, which
    /// is right for English but 1.5 to 3.5 times too high for other languages,
    /// and every long meeting in them would then fail as too long. So the ratio
    /// is measured from counts already made, and 3.5 is used only when they give none.
    static func charactersPerToken(transcriptCharacters: Int, transcriptTokens: Int) -> Double {
        guard transcriptCharacters > 0, transcriptTokens > 0 else { return ChatSelection.defaultCharactersPerToken }
        return Double(transcriptCharacters) / Double(transcriptTokens)
    }

    static func contextSize(promptTokens: Int) -> Int {
        let rounded = (promptTokens + answerReserve + contextStep - 1) / contextStep * contextStep
        return min(rounded, maxContext)
    }

    // MARK: - Private

    private static func fits(_ promptTokens: Int) -> Bool {
        promptTokens + answerReserve <= maxContext
    }

    /// Keeps the passages that fit, dropping the least related ones until the real count fits.
    /// - Parameter wholeTokens: The count of the prompt with the whole transcript and these turns.
    private static func selectPassages(
        _ entries: [ChatEvidenceEntry],
        wholeTokens: Int,
        parts: PromptParts,
        turns: [ChatTurn],
        count: @Sendable ([LLMMessage]) async throws -> Int
    ) async throws -> ChatPrompt {
        let otherTokens = try await count(parts.messages(transcript: "", isPartial: true, turns: turns))
        // The two prompts differ by the transcript, and by the partial rule's few
        // dozen tokens, which are nothing beside a transcript too long to fit.
        let ratio = charactersPerToken(
            transcriptCharacters: entries.reduce(0) { $0 + $1.formatted.count + 1 },
            transcriptTokens: wholeTokens - otherTokens
        )
        var selection = ChatSelection.select(
            entries: entries,
            question: parts.question,
            isLive: parts.record.transcript.isLive,
            transcriptBudget: maxContext - answerReserve - otherTokens,
            charactersPerToken: ratio
        )
        for retry in 0 ... maxSelectionRetries {
            let messages = parts.messages(transcript: selection.transcript, isPartial: true, turns: turns)
            let tokens = try await count(messages)
            if fits(tokens) {
                return parts.prompt(messages: messages, tokens: tokens, evidenceTimes: selection.evidenceTimes, isPartial: true)
            }
            guard retry < maxSelectionRetries, selection.dropLowestScoringOptional() else { break }
        }
        throw ChatPromptError.tooLong
    }
}

/// The parts of a prompt that stay the same while it is fitted.
private struct PromptParts {
    let record: ChatMeetingRecord
    let question: String
    let meeting: String
    let reach: String?

    init(record: ChatMeetingRecord, question: String) {
        self.record = record
        self.question = question
        meeting = ChatPrompts.meetingBlock(record)
        reach = ChatPrompts.transcriptReach(record.transcript)
    }

    /// The system message, then the earlier turns, then the question.
    func messages(transcript: String, isPartial: Bool, turns: [ChatTurn]) -> [LLMMessage] {
        let system = ChatPrompts.systemMessage(
            rules: ChatPrompts.system(isPartial: isPartial, isLive: record.transcript.isLive),
            meeting: meeting,
            transcript: transcript,
            reach: reach,
            notes: record.notes
        )
        return [.system(system)] + turns.flatMap { [.user($0.question), .assistant($0.answer)] } + [.user(question)]
    }

    func prompt(messages: [LLMMessage], tokens: Int, evidenceTimes: [TimeInterval], isPartial: Bool) -> ChatPrompt {
        ChatPrompt(
            messages: messages,
            contextSize: ChatPromptBuilder.contextSize(promptTokens: tokens),
            promptTokens: tokens,
            options: ChatPromptBuilder.options,
            evidenceTimes: evidenceTimes,
            isPartial: isPartial,
            basis: record.transcript.basis
        )
    }
}
