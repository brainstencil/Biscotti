import DesignSystem
import SwiftUI

/// The field's 28 pt round button: Send (disabled or ready) or Stop.
struct ChatRoundButton: View {
    let kind: ChatFieldPresentation.ButtonKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                if kind == .stop {
                    // `cardFill`, not white: in dark mode `ink` is light, and a
                    // white square would vanish on the circle.
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Tokens.cardFill)
                        .frame(width: 9, height: 9)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(kind == .send ? Color.onAccent : Color.inkTertiary)
                }
            }
            .frame(width: Tokens.chatRoundButton, height: Tokens.chatRoundButton)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(kind == .sendDisabled)
        .help(kind == .stop ? "Stop answer (Esc)" : "Send question (Return)")
        .accessibilityLabel(kind == .stop ? "Stop answer" : "Send question")
    }

    private var fill: Color {
        switch kind {
        case .send: Tokens.accentFill
        case .stop: .ink
        case .sendDisabled, .none: Tokens.neutralChip
        }
    }
}

/// A small bordered button inside the field or an answer's footer: "Open
/// Settings", "Turn On", "Retry". `cardFill`, a `cardStroke` border,
/// `chipRadius`, sage medium text.
struct ChatInlineButtonStyle: ButtonStyle {
    var height: CGFloat = Tokens.chatRoundButton
    var fontSize: CGFloat = 12.5
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.chipRadius, style: .continuous)
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(isEnabled ? Color.sage : Color.inkTertiary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background {
                shape.fill(Tokens.cardFill)
                if configuration.isPressed {
                    shape.fill(Tokens.neutralChip)
                }
            }
            .overlay { shape.strokeBorder(Tokens.cardStroke, lineWidth: 1) }
            .contentShape(shape)
            .fixedSize()
    }
}

/// An icon button with the rounded `neutralChip` fill while hovered or pressed.
struct ChatHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(isPressed: configuration.isPressed) { configuration.label }
    }
}

/// The chat card header's icon buttons, matching the transcript drawer's.
struct ChatHeaderIconButton: View {
    let systemImage: String
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.inkSecondary)
        .help(help)
        .accessibilityLabel(label)
    }
}
