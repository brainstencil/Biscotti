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
/// become sage mono chips that link to `biscotti-chat-time:<seconds>`.
enum ChatAnswerText {
    static let linkScheme = "biscotti-chat-time"
    /// The chip's horizontal padding, and its corner radius.
    static let chipPadding: CGFloat = 5
    static let chipVerticalPadding: CGFloat = 1
    static let chipFont = Font.biscottiMono(11.5)

    /// A run of a block's text: plain, or one chip with its target second.
    struct Segment: Equatable {
        var text: AttributedString
        var chipTime: TimeInterval?
    }

    static func link(to seconds: TimeInterval) -> URL? {
        URL(string: "\(linkScheme):\(seconds)")
    }

    /// The second a chip's link points at; nil for any other URL.
    static func seconds(from url: URL) -> TimeInterval? {
        guard url.scheme == linkScheme,
              let seconds = TimeInterval(url.absoluteString.dropFirst(linkScheme.count + 1)),
              seconds.isFinite, seconds >= 0
        else { return nil }
        return seconds
    }

    /// The text cut at its chips. Chips get their font, colour, link and
    /// padding; every other link is removed, because the answer is model
    /// output and only chips may lead anywhere.
    ///
    /// The padding is kerning: 5 pt after the character before a chip and
    /// after the chip's last character, so the wash that `ChatChipRenderer`
    /// draws 5 pt beyond the chip's glyphs never covers the words around it.
    static func segments(_ text: AttributedString) -> [Segment] {
        var segments: [Segment] = []
        for (time, range) in text.runs[ChatTimeAttribute.self] {
            var piece = AttributedString(text[range])
            if let time {
                piece[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = chipFont
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .sage
                piece.link = link(to: time)
                kernAfterLastCharacter(of: &piece)
                if let previous = segments.indices.last, segments[previous].chipTime == nil {
                    kernAfterLastCharacter(of: &segments[previous].text)
                }
                segments.append(Segment(text: piece, chipTime: time))
            } else {
                piece.link = nil
                segments.append(Segment(text: piece, chipTime: nil))
            }
        }
        return segments
    }

    /// The segments as one `Text`, each chip carrying `ChatChipAttribute`.
    static func text(_ segments: [Segment]) -> Text {
        segments.enumerated().reduce(Text(verbatim: "")) { text, item in
            let (index, segment) = item
            let piece = segment.chipTime == nil
                ? Text(segment.text)
                : Text(segment.text).customAttribute(ChatChipAttribute(id: index))
            return Text("\(text)\(piece)")
        }
    }

    /// A chip as VoiceOver offers it: its text as written, and its target.
    struct Chip: Hashable {
        /// "0:34" or "12:34–13:10", as the chip reads.
        let label: String
        /// The start of the transcript line it links to.
        let time: TimeInterval
    }

    /// The chips, in order, once each.
    static func chips(_ segments: [Segment]) -> [Chip] {
        var seen = Set<Chip>()
        return segments.compactMap { segment in
            segment.chipTime.map { Chip(label: String(segment.text.characters), time: $0) }
        }
        .filter { seen.insert($0).inserted }
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
            for rect in Self.chipRects(in: line) {
                let shape = RoundedRectangle(cornerRadius: ChatAnswerText.chipPadding, style: .continuous)
                context.fill(shape.path(in: rect), with: .color(Tokens.accentWashSoft))
            }
            context.draw(line)
        }
    }

    /// The chip backgrounds on a line: the glyphs' bounds, 5 pt wider on the
    /// left (the right already holds the chip's trailing kerning) and 1 pt
    /// taller on each side.
    static func chipRects(in line: Text.Layout.Line) -> [CGRect] {
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
        return order.compactMap { bounds[$0] }.map { rect in
            CGRect(
                x: rect.minX - horizontal,
                y: rect.minY - vertical,
                width: rect.width + horizontal,
                height: rect.height + 2 * vertical
            )
        }
    }
}
