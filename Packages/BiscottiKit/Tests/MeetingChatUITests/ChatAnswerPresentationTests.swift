import DataStore
import Foundation
import SwiftUI
import Testing
@testable import MeetingChat
@testable import MeetingChatUI

@Suite("Chat answers")
struct ChatAnswerPresentationTests {
    private let questionID = UUID()

    private func answer(
        _ text: String = "We chose the blue remote [0:21].",
        state: ChatMessageView.State = .complete,
        footer: String? = "Based on the transcript through 0:46",
        isUnsaved: Bool = false
    ) -> ChatMessageView {
        ChatMessageView(
            id: UUID(), questionID: questionID, role: .answer, text: text,
            blocks: ChatAnswerParser.blocks(text, evidenceTimes: [21]),
            state: state, footer: footer, isUnsaved: isUnsaved
        )
    }

    // MARK: - Copy

    @Test("copied text drops Markdown markers and brackets")
    func copyTextStripsMarkdown() {
        let blocks = ChatAnswerParser.blocks("**A base** it lives in [0:34]", evidenceTimes: [34])
        #expect(ChatAnswerCopy.plainText(blocks) == "A base it lives in 0:34")
    }

    @Test("lists, numbers and headings copy as plain text")
    func copyTextKeepsStructure() {
        let markdown = "Intro *here*.\n\n- one [0:34]\n  - nested\n1. first\n2. second\n\n## Next steps\nShip it."
        let blocks = ChatAnswerParser.blocks(markdown, evidenceTimes: [34])
        #expect(ChatAnswerCopy.plainText(blocks) == "Intro here.\n\n• one 0:34\n  • nested\n1. first\n2. second\n\nNext steps\n\nShip it.")
    }

    // MARK: - Footer

    @Test("each ending shows its note, error, basis, Retry and Copy")
    func answerFooters() {
        #expect(ChatAnswerFooterPresentation.make(answer()) == ChatAnswerFooterPresentation(
            showsCopy: true, basis: "Based on the transcript through 0:46"
        ))
        // A saved transcript, or no basis at all, shows no basis line.
        #expect(ChatAnswerFooterPresentation.make(answer(footer: nil)) == ChatAnswerFooterPresentation(showsCopy: true))
        #expect(ChatAnswerFooterPresentation.make(answer(state: .stopped)) == ChatAnswerFooterPresentation(
            showsCopy: true, note: "Stopped", basis: "Based on the transcript through 0:46"
        ))
        #expect(ChatAnswerFooterPresentation.make(answer(state: .failed("The AI stopped before finishing."))) == ChatAnswerFooterPresentation(
            showsCopy: true, error: "The AI stopped before finishing.", basis: "Based on the transcript through 0:46", showsRetry: true
        ))
        // A failure before any text, and before a prompt existed: nothing to copy, no basis.
        #expect(ChatAnswerFooterPresentation.make(answer("", state: .failed("The AI model couldn't start."), footer: nil)) == ChatAnswerFooterPresentation(
            error: "The AI model couldn't start.", showsRetry: true
        ))
        #expect(ChatAnswerFooterPresentation.make(answer("", state: .interrupted, footer: nil)) == ChatAnswerFooterPresentation(
            note: "Interrupted", showsRetry: true
        ))
        #expect(ChatAnswerFooterPresentation.make(answer(isUnsaved: true))?.isUnsaved == true)
        #expect(ChatAnswerFooterPresentation.make(answer(state: .streaming(.streaming))) == nil)
    }

    // MARK: - Status

    @Test("before the first word, the status line says what the answer waits for")
    func statusTexts() {
        #expect(ChatAnswerPresentation.statusText(.loadingModel) == "Loading the AI model…")
        #expect(ChatAnswerPresentation.statusText(.waitingForSummary) == "Waiting for the summary to finish…")
        #expect(ChatAnswerPresentation.statusText(.waitingForRecordingToEnd) == "Answers when the recording stops")
        #expect(ChatAnswerPresentation.statusText(.thinking) == "Thinking…")
        #expect(ChatAnswerPresentation.statusText(.streaming) == nil)

        #expect(ChatAnswerPresentation.statusText(for: answer("", state: .streaming(.thinking))) == "Thinking…")
        #expect(ChatAnswerPresentation.statusText(for: answer("Words", state: .streaming(.streaming))) == nil)
        #expect(ChatAnswerPresentation.statusText(for: answer()) == nil)
    }

    @Test("a finished answer is announced once, whole")
    func finishedAnnouncements() {
        #expect(ChatAnswerPresentation.finishedAnnouncement(answer()) == "We chose the blue remote 0:21.")
        #expect(ChatAnswerPresentation.finishedAnnouncement(answer(state: .failed("The AI stopped before finishing."))) == "The AI stopped before finishing.")
        #expect(ChatAnswerPresentation.finishedAnnouncement(answer(state: .streaming(.streaming))) == nil)
    }

    // MARK: - Chips

    @Test("a cited time becomes a padded, linked mono chip; other times and links stay plain")
    func chipSegments() throws {
        let blocks = ChatAnswerParser.blocks("We chose blue [0:21], not [9:59]. See [the docs](https://example.com).", evidenceTimes: [21])
        let segments = try ChatAnswerText.segments(#require(blocks.first).text)

        #expect(segments.map { String($0.text.characters) } == ["We chose blue ", "0:21", ", not 9:59. See the docs."])
        #expect(segments.map(\.chipTime) == [nil, 21, nil])
        #expect(ChatAnswerText.chips(segments) == [ChatAnswerText.Chip(label: "0:21", time: 21)])

        let chip = segments[1].text
        #expect(chip.runs.allSatisfy { $0.link == ChatAnswerText.link(to: 21) })
        #expect(chip.runs.allSatisfy { $0[AttributeScopes.SwiftUIAttributes.FontAttribute.self] == ChatAnswerText.chipFont })
        // The padding: kerning after the chip's last character and before the chip.
        #expect(chip.runs.last?[AttributeScopes.SwiftUIAttributes.KerningAttribute.self] == ChatAnswerText.chipPadding)
        #expect(segments[0].text.runs.last?[AttributeScopes.SwiftUIAttributes.KerningAttribute.self] == ChatAnswerText.chipPadding)
        #expect(segments[0].text.runs.first?[AttributeScopes.SwiftUIAttributes.KerningAttribute.self] == nil)
        // Model output links nowhere but to the transcript.
        #expect(segments[2].text.runs.allSatisfy { $0.link == nil })
    }

    @Test("VoiceOver names a chip by its own text, which can differ from the second it goes to")
    func chipLabelsReadAsWritten() throws {
        let blocks = ChatAnswerParser.blocks("At [0:34], then [12:34–13:10] and [0:34] again.", evidenceTimes: [30, 750])
        let chips = try ChatAnswerText.chips(ChatAnswerText.segments(#require(blocks.first).text))
        #expect(chips == [
            ChatAnswerText.Chip(label: "0:34", time: 30),
            ChatAnswerText.Chip(label: "12:34–13:10", time: 750)
        ])
    }

    @Test("chip links parse back to their second; other URLs are not chips")
    func timeLinksRoundTrip() throws {
        let link = try #require(ChatAnswerText.link(to: 42.5))
        #expect(link.absoluteString == "biscotti-chat-time:42.5")
        #expect(ChatAnswerText.seconds(from: link) == 42.5)
        #expect(try ChatAnswerText.seconds(from: #require(ChatAnswerText.link(to: 3725))) == 3725)
        #expect(try ChatAnswerText.seconds(from: #require(URL(string: "https://example.com/42"))) == nil)
        #expect(try ChatAnswerText.seconds(from: #require(URL(string: "biscotti-chat-time:soon"))) == nil)
        #expect(try ChatAnswerText.seconds(from: #require(URL(string: "biscotti-chat-time:-4"))) == nil)
    }

    // MARK: - List

    @Test("an answer sits 16 pt under its question; turns are 26 pt apart; rows keep their identity when saved")
    func turnSpacing() {
        let question = ChatMessageView(id: questionID, questionID: questionID, role: .question, text: "Which remote?")
        let streaming = answer(state: .streaming(.streaming))
        let nextID = UUID()
        let next = ChatMessageView(id: nextID, questionID: nextID, role: .question, text: "Why?")

        let rows = ChatMessageList.rows([question, streaming, next])
        #expect(rows.map(\.spacingAbove) == [0, 16, 26])

        var saved = streaming
        saved.id = UUID()
        #expect(saved.rowKey == streaming.rowKey)
        #expect(question.rowKey != streaming.rowKey)
    }
}
