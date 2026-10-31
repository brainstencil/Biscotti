import AppKit
import DesignSystem
import MeetingChat
import SwiftUI
import TranscriptUI

/// One answer: before its first word, what it waits for (the model load's
/// bar, a status line, or typing dots while the model reads); then its
/// blocks, with typing dots while it streams; then, once it ends, the footer row.
struct ChatAnswerView: View {
    let message: ChatMessageView
    let state: MeetingChatState
    let service: MeetingChatService
    let onTime: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingSM) {
            switch ChatAnswerPresentation.slot(for: message) {
            case .loadingModel:
                ChatModelLoadLine(load: service.modelLoad)
            case let .status(text):
                ChatStatusLine(text: text)
            case .firstWord:
                ChatTypingDots(label: ChatAnswerPresentation.firstWordLabel, announces: true)
            case let .text(isStreaming):
                if !message.blocks.isEmpty {
                    ChatAnswerBlocks(blocks: message.blocks, chipActions: chipActions)
                }
                if isStreaming {
                    ChatTypingDots(label: ChatAnswerPresentation.writingLabel, announces: false)
                }
            }
            if let footer = ChatAnswerFooterPresentation.make(message) {
                ChatAnswerFooter(footer: footer, message: message, state: state, service: service)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: message.state) { old, _ in
            guard case .streaming = old,
                  let text = ChatAnswerPresentation.finishedAnnouncement(message), !text.isEmpty
            else { return }
            AccessibilityNotification.Announcement(text).post()
        }
    }

    private var chipActions: ChatChipActions {
        let service = service
        let meetingID = state.meetingID
        return ChatChipActions(onTime: onTime) { time in
            await service.citedLine(at: time, meetingID: meetingID)
        }
    }
}

// MARK: - Status

/// The transcript's typing dots in the answer's slot, named for VoiceOver.
/// Before the first word they are announced once, as the status line was.
struct ChatTypingDots: View {
    let label: String
    let announces: Bool

    var body: some View {
        TypingDots()
            .padding(.vertical, Tokens.spacingXS)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .task {
                if announces {
                    AccessibilityNotification.Announcement(label).post()
                }
            }
    }
}

/// "Loading the AI model…" with the seconds so far, over a bar that fills
/// against the model's last load on this Mac (`ChatModelLoadPresentation`).
/// VoiceOver reads it without the seconds, and hears it once when it starts
/// and once if the load runs past the estimate.
struct ChatModelLoadLine: View {
    static let barWidth: CGFloat = 240

    let load: ChatModelLoad?

    var body: some View {
        TimelineView(.periodic(from: load?.startedAt ?? .now, by: 0.25)) { context in
            let presentation = ChatModelLoadPresentation.make(
                elapsed: load.map { .milliseconds(Int64(context.date.timeIntervalSince($0.startedAt) * 1000)) },
                estimate: load?.estimate
            )
            VStack(alignment: .leading, spacing: Tokens.spacingSM) {
                Text(presentation.text)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.inkSecondaryLegible)
                Group {
                    if let fraction = presentation.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .controlSize(.small)
                .frame(maxWidth: Self.barWidth)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityText)
            .task(id: presentation.accessibilityText) {
                AccessibilityNotification.Announcement(presentation.accessibilityText).post()
            }
        }
    }
}

/// A small spinner and what the answer waits for. Announced when it changes.
struct ChatStatusLine: View {
    let text: String

    var body: some View {
        HStack(spacing: Tokens.spacingSM) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.inkSecondaryLegible)
        }
        .accessibilityElement(children: .combine)
        .task(id: text) {
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

// MARK: - Blocks

/// The answer's Markdown blocks, 8 pt apart, with their time chips.
struct ChatAnswerBlocks: View {
    let blocks: [ChatBlock]
    let chipActions: ChatChipActions

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacingSM) {
            ForEach(blocks.indices, id: \.self) { index in
                ChatBlockView(block: blocks[index], chipActions: chipActions)
            }
        }
    }
}

private struct ChatBlockView: View {
    static let indent: CGFloat = 18
    static let bodyFont = Font.system(size: 14)

    let block: ChatBlock
    let chipActions: ChatChipActions

    var body: some View {
        switch block {
        case let .paragraph(text):
            blockText(text, font: Self.bodyFont)
        case let .heading(text):
            blockText(text, font: .system(size: 14, weight: .semibold), traits: .isHeader)
        case let .bullet(level, text):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                bulletMarker
                blockText(text, font: Self.bodyFont)
            }
            .padding(.leading, CGFloat(max(0, level - 1)) * Self.indent)
        case let .numbered(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: "\(number).")
                    .font(Self.bodyFont)
                    .monospacedDigit()
                    .foregroundStyle(.inkSecondary)
                    .frame(minWidth: Self.indent - 2, alignment: .leading)
                blockText(text, font: Self.bodyFont)
            }
        }
    }

    /// A 4 pt dot in an 18 pt column. The empty text gives the column the
    /// line's baseline, so the dot sits on the first line.
    private var bulletMarker: some View {
        Text(verbatim: "\u{200B}")
            .font(Self.bodyFont)
            .frame(width: Self.indent, alignment: .leading)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(Color.inkTertiary)
                    .frame(width: 4, height: 4)
                    .padding(.leading, 5)
                    .offset(y: 1)
            }
            .accessibilityHidden(true)
    }

    /// The text, then its chips' targets over it: after the text in
    /// reading order, for Tab and VoiceOver alike.
    private func blockText(_ text: AttributedString, font: Font, traits: AccessibilityTraits = []) -> some View {
        let segments = ChatAnswerText.segments(text)
        let chips = ChatAnswerText.chips(segments)
        return ChatAnswerText.text(segments)
            .font(font)
            .foregroundStyle(.ink)
            .lineSpacing(Tokens.chatLineSpacing)
            .textRenderer(ChatChipRenderer())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(traits)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                if !chips.isEmpty {
                    ChatChipTargets(layouts: layouts, chips: chips, actions: chipActions)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Footer

/// Copy, then what happened to the answer and what it was based on, then Retry.
private struct ChatAnswerFooter: View {
    let footer: ChatAnswerFooterPresentation
    let message: ChatMessageView
    let state: MeetingChatState
    let service: MeetingChatService

    var body: some View {
        HStack(spacing: Tokens.spacingSM) {
            if footer.showsCopy {
                ChatCopyButton(text: ChatAnswerCopy.plainText(message.blocks))
            }
            if let label {
                label
                    .font(.system(size: 11.5))
                    .foregroundStyle(.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if footer.showsRetry {
                Button("Retry") {
                    let questionID = message.questionID
                    let meetingID = state.meetingID
                    Task { await service.retry(questionID: questionID, meetingID: meetingID) }
                }
                .buttonStyle(ChatInlineButtonStyle(height: 22, fontSize: 11.5))
                .disabled(state.isAnswering || state.availability != .available)
                .help("Ask this question again")
            }
        }
        .frame(minHeight: 22)
    }

    /// The note, the error in red, the basis and the unsaved line, joined by " · ".
    private var label: Text? {
        var parts: [Text] = []
        if let note = footer.note {
            parts.append(Text(note))
        }
        if let error = footer.error {
            parts.append(Text(error).foregroundStyle(.signalRedText))
        }
        if let basis = footer.basis {
            parts.append(Text(basis))
        }
        if footer.isUnsaved {
            parts.append(Text(ChatAnswerFooterPresentation.unsavedText))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { Text("\($0) · \($1)") }
    }
}

/// A 14 pt copy icon that shows "Copied" in its place for 1.5 s.
private struct ChatCopyButton: View {
    let text: String
    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                didCopy = false
            }
        } label: {
            Group {
                if didCopy {
                    Text("Copied")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.inkSecondary)
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundStyle(.inkTertiary)
                }
            }
            .padding(.horizontal, Tokens.spacingXS)
            .frame(minWidth: 22, minHeight: 22)
            .contentShape(Rectangle())
            .transaction { $0.animation = nil }
        }
        .buttonStyle(ChatHoverButtonStyle())
        .help("Copy answer")
        .accessibilityLabel(didCopy ? "Copied" : "Copy answer")
    }
}
