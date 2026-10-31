import DesignSystem
import MeetingChat
import SwiftUI

/// What a time chip does: a click (or Space or Return with the keyboard)
/// calls `onTime`, and a rest of the pointer previews the line `line` finds.
struct ChatChipActions {
    let onTime: (TimeInterval) -> Void
    /// The transcript line a chip's time goes to, or nil.
    let line: @MainActor (TimeInterval) async -> ChatEvidenceLine?
}

/// Clear targets over a block's chips, placed from the text's own layout
/// (`Text.LayoutKey`), as `ChatChipRenderer` draws them. Text links take no
/// keyboard focus and show no hand pointer, so the targets do both: each
/// chip is a link-like button, a Tab stop in reading order with the label
/// "Go to 0:42 in the transcript", and under the pointer the hand, with the
/// cited line previewed after a rest.
struct ChatChipTargets: View {
    let layouts: [Text.LayoutKey.AnchoredLayout]
    let chips: [ChatAnswerText.Chip]
    let actions: ChatChipActions

    var body: some View {
        GeometryReader { proxy in
            let rects = Self.rects(layouts: layouts, in: proxy)
            ForEach(chips) { chip in
                if let chipRects = rects[chip.id], !chipRects.isEmpty {
                    ChatChipTarget(chip: chip, rects: chipRects, actions: actions)
                }
            }
        }
    }

    /// Each chip's rectangles, in the targets' space.
    private static func rects(layouts: [Text.LayoutKey.AnchoredLayout], in proxy: GeometryProxy) -> [Int: [CGRect]] {
        layouts.reduce(into: [:]) { rects, anchored in
            let origin = proxy[anchored.origin]
            for (id, chipRects) in ChatChipRenderer.chipRects(in: anchored.layout) {
                rects[id, default: []] += chipRects.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
            }
        }
    }
}

/// One chip's targets: a button over its first rectangle, which takes the
/// focus and speaks for the chip, and plain click areas over the rest, when
/// the chip wraps onto the next line.
private struct ChatChipTarget: View {
    let chip: ChatAnswerText.Chip
    let rects: [CGRect]
    let actions: ChatChipActions

    @State private var hoveredRects: Set<Int> = []
    @State private var previewLine: ChatEvidenceLine?
    /// Set by a click; the preview stays away until the pointer leaves.
    @State private var isDismissed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChatAnswerText.chipPadding, style: .continuous)
        ZStack {
            ForEach(rects.indices, id: \.self) { index in
                target(index, shape: shape)
            }
        }
        .task(id: PreviewTrigger(isResting: !hoveredRects.isEmpty && !isDismissed, time: chip.time)) {
            previewLine = nil
            guard !hoveredRects.isEmpty, !isDismissed else { return }
            // Looked up during the rest, so the line is ready when it ends.
            let lookup = Task { await actions.line(chip.time) }
            defer { lookup.cancel() }
            try? await Task.sleep(for: ChatChipPreviewPresentation.restDelay)
            guard !Task.isCancelled else { return }
            let line = await lookup.value
            guard !Task.isCancelled else { return }
            previewLine = line
        }
        .onChange(of: hoveredRects.isEmpty) { _, isEmpty in
            if isEmpty { isDismissed = false }
        }
    }

    private func target(_ index: Int, shape: RoundedRectangle) -> some View {
        Group {
            if index == 0 {
                Button(action: go) {
                    Color.clear.contentShape(shape)
                }
                .buttonStyle(.plain)
                .contentShape(.focusEffect, shape)
                .onKeyPress(.return, phases: .down) { _ in
                    go()
                    return .handled
                }
                .accessibilityLabel(chip.accessibilityLabel)
                .accessibilityRemoveTraits(.isButton)
                .accessibilityAddTraits(.isLink)
                .anchorPreference(key: ChatChipPreviewKey.self, value: .bounds) { anchor in
                    previewLine.map { ChatChipPreviewRequest(anchor: anchor, line: $0) }
                }
            } else {
                Color.clear
                    .contentShape(shape)
                    .onTapGesture(perform: go)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: rects[index].width, height: rects[index].height)
        .pointerStyle(.link)
        .onHover { inside in
            if inside {
                hoveredRects.insert(index)
            } else {
                hoveredRects.remove(index)
            }
        }
        .position(x: rects[index].midX, y: rects[index].midY)
    }

    private func go() {
        // A click hides the preview until the pointer leaves. A key press or
        // VoiceOver with the pointer elsewhere leaves the next hover alone.
        isDismissed = !hoveredRects.isEmpty
        actions.onTime(chip.time)
    }

    private struct PreviewTrigger: Equatable {
        let isResting: Bool
        let time: TimeInterval
    }
}
