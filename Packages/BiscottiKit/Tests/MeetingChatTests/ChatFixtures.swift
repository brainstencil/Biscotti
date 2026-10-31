import DataStore
import Foundation
import LiveTranscriptModel
import LocalLLM
@testable import MeetingChat

/// Transcripts, records and token counters for the chat context tests.
enum ChatFixtures {
    static func snapshot(rows: [LiveRow], gaps: [LiveGap] = [], through: TimeInterval = 46) -> LiveTranscriptSnapshot {
        LiveTranscriptSnapshot(
            sessionID: UUID(),
            revision: 1,
            captureWatermark: through,
            transcribedThrough: through,
            settledThrough: through,
            rows: rows,
            gaps: gaps,
            includesTail: true
        )
    }

    static func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String, speaker: Int = 0) -> SegmentData {
        SegmentData(id: UUID(), speakerID: speaker, speakerLabel: "Speaker \(speaker + 1)", startTime: start, endTime: end, text: text)
    }

    static func saved(_ segments: [SegmentData], names: [Int: String] = [:]) -> TranscriptData {
        TranscriptData(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            speakerCount: Set(segments.compactMap(\.speakerID)).count,
            segments: segments,
            speakerAssignments: names.mapValues { PersonData(id: UUID(), name: $0) }
        )
    }

    /// A live transcript with one "Others" row every `spacing` seconds.
    /// Every row says `filler`, except those whose index is in `special`.
    static func longLive(
        duration: TimeInterval,
        spacing: TimeInterval = 10,
        filler: String = "We went over the schedule and the budget again in some detail.",
        special: [Int: String] = [:]
    ) -> LiveTranscriptSnapshot {
        let rows = stride(from: 0, to: duration, by: spacing).enumerated().map { index, start in
            LiveRow(track: .system, startTime: start, endTime: start + spacing - 1, settledText: special[index] ?? filler)
        }
        return snapshot(rows: rows, through: duration)
    }

    static func record(
        _ transcript: ChatTranscript,
        title: String = "Remote control design",
        invitees: [String] = ["Kate", "Bill"],
        notes: String = "1:05 Ask Kate about battery life."
    ) -> ChatMeetingRecord {
        ChatMeetingRecord(
            title: title,
            date: Date(timeIntervalSince1970: 1_793_124_240),
            invitees: invitees,
            notes: notes,
            transcript: transcript
        )
    }

    /// Counts a token for every four characters of message content.
    static let characterCounter: @Sendable ([LLMMessage]) async throws -> Int = { messages in
        tokens(messages)
    }

    static func tokens(_ messages: [LLMMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.count } / 4
    }

    static func build(
        _ record: ChatMeetingRecord,
        turns: [ChatTurn] = [],
        question: String = "What did they decide?",
        count: @Sendable ([LLMMessage]) async throws -> Int = characterCounter
    ) async throws -> ChatPrompt {
        try await ChatPromptBuilder.build(record: record, earlierTurns: turns, question: question, count: count)
    }

    static func systemText(_ prompt: ChatPrompt) -> String {
        prompt.messages.first?.content ?? ""
    }
}

/// Records every message list it counts, so tests can see the attempts.
actor RecordingCounter {
    private(set) var attempts: [[LLMMessage]] = []
    private let tokens: @Sendable ([LLMMessage]) -> Int

    init(tokens: @escaping @Sendable ([LLMMessage]) -> Int = ChatFixtures.tokens) {
        self.tokens = tokens
    }

    func count(_ messages: [LLMMessage]) -> Int {
        attempts.append(messages)
        return tokens(messages)
    }
}
