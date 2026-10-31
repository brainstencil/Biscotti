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

    @Test("before the first word the slot shows the wait: the load's bar, a status line, or the dots")
    func slotsBeforeTheFirstWord() {
        #expect(ChatAnswerPresentation.slot(for: answer("", state: .streaming(.loadingModel))) == .loadingModel)
        #expect(ChatAnswerPresentation.slot(for: answer("", state: .streaming(.waitingForSummary))) == .status("Waiting for the summary to finish…"))
        #expect(ChatAnswerPresentation.slot(for: answer("", state: .streaming(.waitingForRecordingToEnd))) == .status("Answers when the recording stops"))
        #expect(ChatAnswerPresentation.slot(for: answer("", state: .streaming(.thinking))) == .firstWord)
        #expect(ChatAnswerPresentation.slot(for: answer("", state: .streaming(.streaming))) == .firstWord)
    }

    @Test("the dots follow the words while they stream and end with the answer, however it ends")
    func dotsEndWithTheAnswer() {
        #expect(ChatAnswerPresentation.slot(for: answer("Words", state: .streaming(.streaming))) == .text(isStreaming: true))
        let endings: [ChatMessageView.State] = [.complete, .stopped, .interrupted, .failed("The AI model couldn't start.")]
        for ending in endings {
            #expect(ChatAnswerPresentation.slot(for: answer("", state: ending)) == .text(isStreaming: false), "\(ending)")
            #expect(ChatAnswerPresentation.slot(for: answer(state: ending)) == .text(isStreaming: false), "\(ending)")
        }
    }

    @Test("a stream that ended with no words says so, with Retry, and is announced")
    func noAnswerFooter() {
        let empty = answer("", state: .complete, footer: nil)
        #expect(ChatAnswerFooterPresentation.make(empty) == ChatAnswerFooterPresentation(note: "The AI gave no answer", showsRetry: true))
        #expect(ChatAnswerPresentation.finishedAnnouncement(empty) == "The AI gave no answer")
    }

    // MARK: - Model load

    @Test("with no earlier load the bar is indeterminate and the text counts the seconds")
    func loadWithoutEstimate() {
        let load = ChatModelLoadPresentation.make(elapsed: .milliseconds(12900), estimate: nil)
        #expect(load == ChatModelLoadPresentation(text: "Loading the AI model… 12 s", fraction: nil, accessibilityText: "Loading the AI model"))
        #expect(ChatModelLoadPresentation.make(elapsed: nil, estimate: .seconds(20)).text == "Loading the AI model…")
    }

    @Test("the bar fills against the last load and stops short of full until the load ends")
    func loadFillsAgainstEstimate() {
        let estimate = Duration.seconds(20)
        #expect(ChatModelLoadPresentation.make(elapsed: .zero, estimate: estimate).fraction == 0)
        #expect(ChatModelLoadPresentation.make(elapsed: .seconds(10), estimate: estimate).fraction == 0.5)
        #expect(ChatModelLoadPresentation.make(elapsed: .seconds(19), estimate: estimate).fraction == 0.9)
        #expect(ChatModelLoadPresentation.make(elapsed: .seconds(300), estimate: estimate).fraction == 0.9)
        #expect(ChatModelLoadPresentation.make(elapsed: .seconds(-1), estimate: estimate).fraction == 0, "a clock step back reads as the start")
    }

    @Test("past the estimate the text says so plainly, and VoiceOver's text changes once, without seconds")
    func loadLongerThanLastTime() {
        let estimate = Duration.seconds(20)
        let onTime = ChatModelLoadPresentation.make(elapsed: .seconds(20), estimate: estimate)
        #expect(onTime.text == "Loading the AI model… 20 s")
        #expect(onTime.accessibilityText == "Loading the AI model")

        let late = ChatModelLoadPresentation.make(elapsed: .seconds(52), estimate: estimate)
        #expect(late.text == "Loading the AI model… 52 s, longer than last time")
        #expect(late.accessibilityText == "Loading the AI model, longer than last time")
        #expect(ChatModelLoadPresentation.make(elapsed: .seconds(53), estimate: estimate).accessibilityText == late.accessibilityText)
    }

    @Test("a finished answer is announced once, whole")
    func finishedAnnouncements() {
        #expect(ChatAnswerPresentation.finishedAnnouncement(answer()) == "We chose the blue remote 0:21.")
        #expect(ChatAnswerPresentation.finishedAnnouncement(answer(state: .failed("The AI stopped before finishing."))) == "The AI stopped before finishing.")
        #expect(ChatAnswerPresentation.finishedAnnouncement(answer(state: .streaming(.streaming))) == nil)
    }

    // MARK: - Chips

    @Test("a cited time becomes a padded mono chip; other times stay plain; the text holds no links")
    func chipSegments() throws {
        let blocks = ChatAnswerParser.blocks("We chose blue [0:21], not [9:59]. See [the docs](https://example.com).", evidenceTimes: [21])
        let segments = try ChatAnswerText.segments(#require(blocks.first).text)

        #expect(segments.map { String($0.text.characters) } == ["We chose blue ", "0:21", ", not 9:59. See the docs."])
        #expect(segments.map(\.chipTime) == [nil, 21, nil])
        #expect(ChatAnswerText.chips(segments) == [ChatAnswerText.Chip(id: 1, label: "0:21", time: 21)])

        let chip = segments[1].text
        #expect(chip.runs.allSatisfy { $0[AttributeScopes.SwiftUIAttributes.FontAttribute.self] == ChatAnswerText.chipFont })
        // The padding: kerning after the chip's last character and before the chip.
        #expect(chip.runs.last?[AttributeScopes.SwiftUIAttributes.KerningAttribute.self] == ChatAnswerText.chipPadding)
        #expect(segments[0].text.runs.last?[AttributeScopes.SwiftUIAttributes.KerningAttribute.self] == ChatAnswerText.chipPadding)
        #expect(segments[0].text.runs.first?[AttributeScopes.SwiftUIAttributes.KerningAttribute.self] == nil)
        // Model output links nowhere; a chip leads to the transcript through its target.
        #expect(segments.allSatisfy { $0.text.runs.allSatisfy { $0.link == nil } })
    }

    @Test("each chip is a stop in reading order, named by its own text, which can differ from the second it goes to")
    func chipLabelsReadAsWritten() throws {
        let blocks = ChatAnswerParser.blocks("At [0:34], then [12:34–13:10] and [0:34] again.", evidenceTimes: [30, 750])
        let chips = try ChatAnswerText.chips(ChatAnswerText.segments(#require(blocks.first).text))
        // A time cited twice is two chips on screen, so two stops.
        #expect(chips == [
            ChatAnswerText.Chip(id: 1, label: "0:34", time: 30),
            ChatAnswerText.Chip(id: 3, label: "12:34–13:10", time: 750),
            ChatAnswerText.Chip(id: 5, label: "0:34", time: 30)
        ])
        #expect(chips.map(\.accessibilityLabel) == [
            "Go to 0:34 in the transcript",
            "Go to 12:34–13:10 in the transcript",
            "Go to 0:34 in the transcript"
        ])
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
