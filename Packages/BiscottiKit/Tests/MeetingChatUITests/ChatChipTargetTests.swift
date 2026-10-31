import DesignSystem
import Foundation
import SwiftUI
import Testing
@testable import MeetingChat
@testable import MeetingChatUI

@Suite("Chat chip targets and previews")
@MainActor
struct ChatChipTargetTests {
    // MARK: - Targets

    /// Lays out an answer paragraph as the card does and returns each chip's
    /// rectangles read from `Text.LayoutKey`, the targets' source.
    private func chipRects(_ markdown: String, evidenceTimes: [TimeInterval], width: CGFloat) throws -> [Int: [CGRect]] {
        let block = try #require(ChatAnswerParser.blocks(markdown, evidenceTimes: evidenceTimes).first)
        let segments = ChatAnswerText.segments(block.text)
        let box = RectBox()
        let view = ChatAnswerText.text(segments)
            .font(.system(size: 14))
            .lineSpacing(Tokens.chatLineSpacing)
            .textRenderer(ChatChipRenderer())
            .fixedSize(horizontal: false, vertical: true)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                box.capture(layouts)
            }
            .frame(width: width)
        let renderer = ImageRenderer(content: view)
        _ = renderer.nsImage
        return box.rects
    }

    @Test("the text's layout gives each chip a rectangle over it, in reading order")
    func targetsSitOnTheChips() throws {
        let rects = try chipRects("We chose blue [0:21], then [0:46].", evidenceTimes: [21, 46], width: 600)

        let first = try #require(rects[1]?.first)
        let second = try #require(rects[3]?.first)
        #expect(rects.keys.sorted() == [1, 3])
        #expect(rects.values.allSatisfy { $0.count == 1 }, "one line, one rectangle per chip")
        #expect(first.maxX <= second.minX, "the earlier chip sits to the left")
        #expect(abs(first.midY - second.midY) < 0.5, "on the same line")
        // A chip's 5 pt wash on the left, and its glyphs: wider than the padding alone.
        #expect(first.width > ChatAnswerText.chipPadding * 2)
        #expect(first.height > 10)
        #expect(first.minX > 0, "after the words before it")
    }

    @Test("a chip on a later line gets its rectangle there")
    func chipsOnLaterLines() throws {
        let words = String(repeating: "word ", count: 30)
        let rects = try chipRects("\(words)[0:21]", evidenceTimes: [21], width: 160)

        let chip = try #require(rects.values.first?.first)
        #expect(rects.count == 1)
        #expect(chip.minY > 40, "below the first lines")
    }

    // MARK: - Preview

    @Test("the preview names the speaker and the time, then the line's text")
    func previewText() {
        let saved = ChatChipPreviewPresentation(line: ChatEvidenceLine(start: 632.6, speaker: "Alex", text: "We should fund it publicly."))
        #expect(saved.heading == "Alex · 10:32")
        #expect(saved.text == "We should fund it publicly.")

        let live = ChatChipPreviewPresentation(line: ChatEvidenceLine(start: 21, speaker: "Others", text: "A magnet on the back", unsettled: "of it"))
        #expect(live.heading == "Others · 0:21")
        #expect(live.text == "A magnet on the back of it", "a live line's unsettled tail is part of it")

        let unnamed = ChatChipPreviewPresentation(line: ChatEvidenceLine(start: 3725, speaker: "", text: "", unsettled: "Hello"))
        #expect(unnamed.heading == "1:02:05", "the one-track fallback names no speaker")
        #expect(unnamed.text == "Hello")
    }

    @Test("the preview sits below the chip, above it when there is no room below, inside the list's edges")
    func previewPlacement() {
        let chip = CGRect(x: 300, y: 100, width: 40, height: 18)
        #expect(ChatChipPreviewPresentation.top(chip: chip, height: 60, containerHeight: 400) == 124)
        #expect(ChatChipPreviewPresentation.top(chip: chip.offsetBy(dx: 0, dy: 250), height: 60, containerHeight: 400) == 284)
        // No room on either side: the side with more room.
        #expect(ChatChipPreviewPresentation.top(chip: chip.offsetBy(dx: 0, dy: -50), height: 200, containerHeight: 220) == 74)

        #expect(ChatChipPreviewPresentation.leading(chip: chip, width: 200, containerWidth: 600) == 300)
        #expect(ChatChipPreviewPresentation.leading(chip: chip, width: 200, containerWidth: 420) == 208)
        #expect(ChatChipPreviewPresentation.leading(chip: chip.offsetBy(dx: -295, dy: 0), width: 200, containerWidth: 420) == 12)
    }
}

/// Collects the chip rectangles from the layouts a render reports.
@MainActor
private final class RectBox {
    var rects: [Int: [CGRect]] = [:]

    /// Keeps the rectangles; draws nothing.
    func capture(_ layouts: [Text.LayoutKey.AnchoredLayout]) -> Color {
        for anchored in layouts {
            for (id, chipRects) in ChatChipRenderer.chipRects(in: anchored.layout) {
                rects[id] = chipRects
            }
        }
        return .clear
    }
}
