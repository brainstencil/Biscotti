import DesignSystem
import Foundation
import MeetingChat
import SwiftUI

/// Marks a time chip's runs for `ChatChipRenderer`. `id` tells neighbouring
/// chips apart, since one chip can be drawn as several runs.
struct ChatChipAttribute: TextAttribute {
    let id: Int
}

/// Turns a block's text into the `Text` the chat card draws: cited times
/// become sage mono chips. The chips are drawn in the text and act through
/// the targets `ChatChipTargets` lays over them, so the text holds no links.
enum ChatAnswerText {
    /// The chip's horizontal padding, and its corner radius.
    static let chipPadding: CGFloat = 5
    static let chipVerticalPadding: CGFloat = 1
    static let chipFont = Font.biscottiMono(11.5)

    /// A run of a block's text: plain, or one chip with its target second.
    struct Segment: Equatable {
        var text: AttributedString
        var chipTime: TimeInterval?
    }

    /// The text cut at its chips. Chips get their font, colour and padding.
    /// Every link is removed, because the answer is model output: only chips
    /// lead anywhere, through their targets.
    ///
    /// The padding is kerning: 5 pt after the character before a chip and
    /// after the chip's last character, so the wash that `ChatChipRenderer`
    /// draws 5 pt beyond the chip's glyphs never covers the words around it.
    static func segments(_ text: AttributedString) -> [Segment] {
        var segments: [Segment] = []
        for (time, range) in text.runs[ChatTimeAttribute.self] {
            var piece = AttributedString(text[range])
            piece.link = nil
            if let time {
                piece[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = chipFont
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .sage
                kernAfterLastCharacter(of: &piece)
                if let previous = segments.indices.last, segments[previous].chipTime == nil {
                    kernAfterLastCharacter(of: &segments[previous].text)
                }
                segments.append(Segment(text: piece, chipTime: time))
            } else {
                segments.append(Segment(text: piece, chipTime: nil))
            }
        }
        return segments
    }

    /// The segments as one `Text`, each chip carrying `ChatChipAttribute`
    /// with its segment's index as its ID.
    static func text(_ segments: [Segment]) -> Text {
        segments.enumerated().reduce(Text(verbatim: "")) { text, item in
            let (index, segment) = item
            let piece = segment.chipTime == nil
                ? Text(segment.text)
                : Text(segment.text).customAttribute(ChatChipAttribute(id: index))
            return Text("\(text)\(piece)")
        }
    }

    /// A chip as its target offers it to the keyboard and VoiceOver.
    struct Chip: Hashable, Identifiable {
        /// Its segment's index, the `ChatChipAttribute` ID of its runs.
        let id: Int
        /// "0:34" or "12:34–13:10", as the chip reads.
        let label: String
        /// The start of the transcript line it links to.
        let time: TimeInterval

        /// Named by the chip's own text, which can differ from the second it
        /// goes to (the start of the line it cites).
        var accessibilityLabel: String {
            "Go to \(label) in the transcript"
        }
    }

    /// Every chip, in reading order: a time cited twice is two chips, as it
    /// is two places to click.
    static func chips(_ segments: [Segment]) -> [Chip] {
        segments.enumerated().compactMap { index, segment in
            segment.chipTime.map { Chip(id: index, label: String(segment.text.characters), time: $0) }
        }
    }

    private static func kernAfterLastCharacter(of text: inout AttributedString) {
        guard let last = text.characters.indices.last else { return }
        text[last ..< text.endIndex][AttributeScopes.SwiftUIAttributes.KerningAttribute.self] = chipPadding
    }
}

/// Draws an `accentWashSoft` rounded rectangle behind each time chip, then
/// the text. A chip's runs on one line share one rectangle.
struct ChatChipRenderer: TextRenderer {
    var displayPadding: EdgeInsets {
        let vertical = ChatAnswerText.chipVerticalPadding
        return EdgeInsets(top: vertical, leading: ChatAnswerText.chipPadding, bottom: vertical, trailing: 0)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for chip in Self.chipRects(in: line) {
                let shape = RoundedRectangle(cornerRadius: ChatAnswerText.chipPadding, style: .continuous)
                context.fill(shape.path(in: chip.rect), with: .color(Tokens.accentWashSoft))
            }
            context.draw(line)
        }
    }

    /// Each chip's rectangles in a layout, by chip ID: one per line it is on.
    static func chipRects(in layout: Text.Layout) -> [Int: [CGRect]] {
        layout.flatMap(chipRects(in:)).reduce(into: [:]) { rects, chip in
            rects[chip.id, default: []].append(chip.rect)
        }
    }

    /// The chip backgrounds on a line, with their chip IDs: the glyphs'
    /// bounds, 5 pt wider on the left (the right already holds the chip's
    /// trailing kerning) and 1 pt taller on each side.
    static func chipRects(in line: Text.Layout.Line) -> [(id: Int, rect: CGRect)] {
        var bounds: [Int: CGRect] = [:]
        var order: [Int] = []
        for run in line {
            guard let chip = run[ChatChipAttribute.self] else { continue }
            let rect = run.typographicBounds.rect
            if let existing = bounds[chip.id] {
                bounds[chip.id] = existing.union(rect)
            } else {
                bounds[chip.id] = rect
                order.append(chip.id)
            }
        }
        let horizontal = ChatAnswerText.chipPadding
        let vertical = ChatAnswerText.chipVerticalPadding
        return order.compactMap { id in
            bounds[id].map { rect in
                (id, CGRect(
                    x: rect.minX - horizontal,
                    y: rect.minY - vertical,
                    width: rect.width + horizontal,
                    height: rect.height + 2 * vertical
                ))
            }
        }
    }
}
