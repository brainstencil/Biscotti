import DesignSystem
import MeetingChat
import SwiftUI

/// What the preview of a chip's line shows: who spoke, when, and what they said.
struct ChatChipPreviewPresentation: Equatable {
    /// How long the pointer rests on a chip before its line shows: about
    /// the system tooltip's delay.
    static let restDelay = Duration.seconds(1)

    /// Nil for a live row from the one-track fallback, which names no speaker.
    let speaker: String?
    /// "10:32", the line's start.
    let time: String
    /// The line's text, with a live line's unsettled tail.
    let text: String

    init(line: ChatEvidenceLine) {
        speaker = line.speaker.isEmpty ? nil : line.speaker
        time = ChatEvidence.format(line.start)
        text = [line.text, line.unsettled].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "Alex · 10:32", or "10:32" when the line names no speaker.
    var heading: String {
        speaker.map { "\($0) · \(time)" } ?? time
    }

    /// The bubble's top edge in the list: 6 pt below the chip if it fits
    /// there, otherwise 6 pt above it, otherwise on the side with more room.
    static func top(chip: CGRect, height: CGFloat, containerHeight: CGFloat) -> CGFloat {
        let below = chip.maxY + gap
        let above = chip.minY - gap - height
        if below + height <= containerHeight - margin { return below }
        if above >= margin { return above }
        return containerHeight - chip.maxY >= chip.minY ? below : above
    }

    /// The bubble's leading edge in the list: at the chip's, kept `margin`
    /// inside the list's edges.
    static func leading(chip: CGRect, width: CGFloat, containerWidth: CGFloat) -> CGFloat {
        max(margin, min(chip.minX, containerWidth - margin - width))
    }

    static let gap: CGFloat = 6
    static let margin: CGFloat = 12
    static let maxWidth: CGFloat = 320
}

/// The chip whose line is previewed, published by its target for the list's overlay.
struct ChatChipPreviewRequest: Equatable {
    let anchor: Anchor<CGRect>
    let line: ChatEvidenceLine
}

struct ChatChipPreviewKey: PreferenceKey {
    static var defaultValue: ChatChipPreviewRequest? {
        nil
    }

    static func reduce(value: inout ChatChipPreviewRequest?, nextValue: () -> ChatChipPreviewRequest?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Draws the previewed chip's line over this view, next to the chip.
    /// Over the message list rather than inside its rows, so later rows do
    /// not cover it and the scroll view does not clip it.
    func chatChipPreview() -> some View {
        overlayPreferenceValue(ChatChipPreviewKey.self) { request in
            GeometryReader { proxy in
                if let request {
                    ChatChipPreviewPlacement(chip: proxy[request.anchor], container: proxy.size, line: request.line)
                }
            }
        }
    }
}

/// The bubble, placed by `ChatChipPreviewPresentation` from its own size.
private struct ChatChipPreviewPlacement: View {
    let chip: CGRect
    let container: CGSize
    let line: ChatEvidenceLine

    var body: some View {
        let maxWidth = min(ChatChipPreviewPresentation.maxWidth, container.width - 2 * ChatChipPreviewPresentation.margin)
        ZStack(alignment: .topLeading) {
            Color.clear
            ChatChipPreviewBubble(presentation: ChatChipPreviewPresentation(line: line))
                .frame(maxWidth: max(0, maxWidth), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .alignmentGuide(.leading) { size in
                    -ChatChipPreviewPresentation.leading(chip: chip, width: size.width, containerWidth: container.width)
                }
                .alignmentGuide(.top) { size in
                    -ChatChipPreviewPresentation.top(chip: chip, height: size.height, containerHeight: container.height)
                }
        }
        .frame(width: container.width, height: container.height)
        .allowsHitTesting(false)
        // The chip's label names its target; the preview is for the eye only.
        .accessibilityHidden(true)
    }
}

/// The cited line, in the card's style: the speaker and time in small
/// secondary text, then up to three lines of the line's text.
private struct ChatChipPreviewBubble: View {
    let presentation: ChatChipPreviewPresentation

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.chipRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 3) {
            Text(presentation.heading)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.inkSecondaryLegible)
            Text(presentation.text)
                .font(.system(size: 13))
                .foregroundStyle(.ink)
                .lineLimit(3)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background {
            shape.fill(Tokens.cardFill)
                .shadow(color: Tokens.cardShadow, radius: 8, y: 2)
        }
        .overlay { shape.strokeBorder(Tokens.cardStroke, lineWidth: 0.5) }
    }
}
