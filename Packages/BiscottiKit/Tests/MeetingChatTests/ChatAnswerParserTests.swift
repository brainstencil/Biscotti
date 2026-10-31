import Foundation
import Testing
@testable import MeetingChat

@Suite("ChatAnswerParser")
struct ChatAnswerParserTests {
    @Test("blank lines split paragraphs; list and heading markers start their own blocks")
    func paragraphsAndLists() {
        let answer = """
        ## Decisions
        They chose a magnet.
        It sticks to the back.

        - Battery life
          - About a year
        * Price
        1. Order samples
        2) Test them
        """

        let blocks = ChatAnswerParser.blocks(answer, evidenceTimes: [])

        #expect(blocks == [
            .heading(AttributedString("Decisions")),
            .paragraph(AttributedString("They chose a magnet.\nIt sticks to the back.")),
            .bullet(level: 1, AttributedString("Battery life")),
            .bullet(level: 2, AttributedString("About a year")),
            .bullet(level: 1, AttributedString("Price")),
            .numbered(number: 1, AttributedString("Order samples")),
            .numbered(number: 2, AttributedString("Test them"))
        ])
    }

    @Test("lines that only look like markers stay text")
    func nearMarkersAreText() {
        let blocks = ChatAnswerParser.blocks("2026. was busy\n#hashtag\n**Key** point\n1.5 hours", evidenceTimes: [])

        #expect(blocks.count == 1)
        #expect(Self.text(blocks[0]) == "2026. was busy\n#hashtag\nKey point\n1.5 hours")
    }

    @Test("a marker with nothing after it yet is already its block")
    func streamingMarkerStartsBlock() {
        #expect(ChatAnswerParser.blocks("Points:\n- ", evidenceTimes: []) == [
            .paragraph(AttributedString("Points:")),
            .bullet(level: 1, AttributedString(""))
        ])
        #expect(ChatAnswerParser.blocks("Points:\n3.", evidenceTimes: []).last == .numbered(number: 3, AttributedString("")))
    }

    @Test("bold and italic runs are kept")
    func inlineMarkdown() throws {
        let blocks = ChatAnswerParser.blocks("The **magnet** is *optional*.", evidenceTimes: [])

        let text = try #require(Self.attributed(blocks.first))
        #expect(String(text.characters) == "The magnet is optional.")
        let intents = text.runs.compactMap { run in run.inlinePresentationIntent.map { (String(text[run.range].characters), $0) } }
        #expect(intents.count == 2)
        #expect(intents.first?.0 == "magnet")
        #expect(intents.first?.1 == .stronglyEmphasized)
        #expect(intents.last?.0 == "optional")
        #expect(intents.last?.1 == .emphasized)
    }

    @Test("an unclosed bold marker shows as text")
    func unclosedBoldDoesNotFail() {
        let blocks = ChatAnswerParser.blocks("Some **bold", evidenceTimes: [])

        #expect(blocks.count == 1)
        #expect(Self.text(blocks[0]) == "Some **bold")
    }

    @Test("a citation near a line given becomes a time linked to that line")
    func validCitationBecomesTime() throws {
        let blocks = ChatAnswerParser.blocks("They chose a magnet [0:21].", evidenceTimes: [3, 20, 46])

        let text = try #require(Self.attributed(blocks.first))
        #expect(String(text.characters) == "They chose a magnet 0:21.")
        #expect(Self.times(in: text) == [Self.TimeRun(text: "0:21", seconds: 20)])
    }

    @Test("a citation far from every line stays plain text")
    func farCitationStaysPlain() throws {
        let blocks = ChatAnswerParser.blocks("Later [9:00] they left.", evidenceTimes: [3, 520])

        let text = try #require(Self.attributed(blocks.first))
        #expect(String(text.characters) == "Later 9:00 they left.")
        #expect(Self.times(in: text).isEmpty)
    }

    @Test("a citation with hours parses as h:mm:ss")
    func hourCitation() throws {
        let blocks = ChatAnswerParser.blocks("See [1:02:09].", evidenceTimes: [3720, 3729.4])

        let text = try #require(Self.attributed(blocks.first))
        #expect(Self.times(in: text) == [Self.TimeRun(text: "1:02:09", seconds: 3729.4)])
    }

    @Test("a range citation links to the line nearest its start")
    func rangeCitationUsesStart() throws {
        let blocks = ChatAnswerParser.blocks("Discussed [12:34–13:10] and [0:05 - 0:09].", evidenceTimes: [5, 750, 790])

        let text = try #require(Self.attributed(blocks.first))
        #expect(String(text.characters) == "Discussed 12:34–13:10 and 0:05 - 0:09.")
        #expect(Self.times(in: text) == [
            Self.TimeRun(text: "12:34–13:10", seconds: 750),
            Self.TimeRun(text: "0:05 - 0:09", seconds: 5)
        ])
    }

    @Test("a citation inside bold keeps the bold, and citations work in every block kind")
    func citationsKeepAttributesInEveryBlock() throws {
        let blocks = ChatAnswerParser.blocks("# Plan [0:21]\n- **Magnet [0:21]**\n2. Ship [0:46]", evidenceTimes: [21, 46])

        #expect(blocks.count == 3)
        let bullet = try #require(Self.attributed(blocks[1]))
        let chip = try #require(bullet.runs.first { $0[ChatTimeAttribute.self] != nil })
        #expect(chip.inlinePresentationIntent == .stronglyEmphasized)
        #expect(blocks.compactMap { Self.attributed($0) }.map { Self.times(in: $0).map(\.seconds) } == [[21], [21], [46]])
    }

    @Test("each time in a grouped citation is judged on its own")
    func groupedCitations() throws {
        let blocks = ChatAnswerParser.blocks("See [0:21, 1:05] and [0:21; 9:00] and [0:21–0:40, 1:05].", evidenceTimes: [20, 65])

        let text = try #require(Self.attributed(blocks.first))
        #expect(String(text.characters) == "See 0:21, 1:05 and 0:21; 9:00 and 0:21–0:40, 1:05.")
        #expect(Self.times(in: text) == [
            Self.TimeRun(text: "0:21", seconds: 20),
            Self.TimeRun(text: "1:05", seconds: 65),
            Self.TimeRun(text: "0:21", seconds: 20),
            Self.TimeRun(text: "0:21–0:40", seconds: 20),
            Self.TimeRun(text: "1:05", seconds: 65)
        ])
    }

    @Test("Windows line endings split lines like plain ones")
    func crlfLineEndings() {
        #expect(ChatAnswerParser.blocks("One\r\nTwo\r\n\r\n- Three", evidenceTimes: []) == [
            .paragraph(AttributedString("One\nTwo")),
            .bullet(level: 1, AttributedString("Three"))
        ])
    }

    @Test("brackets that are not times are left alone")
    func otherBracketsUntouched() {
        let blocks = ChatAnswerParser.blocks("A [note] and [12:3] and [123:45].", evidenceTimes: [0])

        #expect(Self.text(blocks[0]) == "A [note] and [12:3] and [123:45].")
    }

    @Test("the nearest evidence time is found on either side, within 15 s")
    func nearestEvidence() {
        let times: [TimeInterval] = [10, 40, 100]

        #expect(ChatAnswerParser.nearestEvidence(to: 24, in: times) == 10)
        #expect(ChatAnswerParser.nearestEvidence(to: 26, in: times) == 40)
        #expect(ChatAnswerParser.nearestEvidence(to: 115, in: times) == 100)
        #expect(ChatAnswerParser.nearestEvidence(to: 116, in: times) == nil)
        #expect(ChatAnswerParser.nearestEvidence(to: 0, in: []) == nil)
    }

    @Test("cited times are the distinct linked times, ascending, and parse back to the same links")
    func citedTimesParseBack() {
        let answer = "- Blue [1:05] and [0:21].\n\nAgain [0:22], never [9:00]."
        let blocks = ChatAnswerParser.blocks(answer, evidenceTimes: [0, 20, 64, 300])

        let cited = ChatAnswerParser.citedTimes(in: blocks)

        #expect(cited == [20, 64])
        #expect(ChatAnswerParser.blocks(answer, evidenceTimes: cited) == blocks)
    }

    // MARK: - Helpers

    struct TimeRun: Equatable {
        let text: String
        let seconds: TimeInterval
    }

    private static func attributed(_ block: ChatBlock?) -> AttributedString? {
        switch block {
        case let .paragraph(text), let .bullet(_, text), let .numbered(_, text), let .heading(text): text
        case nil: nil
        }
    }

    private static func text(_ block: ChatBlock) -> String {
        attributed(block).map { String($0.characters) } ?? ""
    }

    private static func times(in text: AttributedString) -> [TimeRun] {
        text.runs.compactMap { run in
            run[ChatTimeAttribute.self].map { TimeRun(text: String(text[run.range].characters), seconds: $0) }
        }
    }
}
