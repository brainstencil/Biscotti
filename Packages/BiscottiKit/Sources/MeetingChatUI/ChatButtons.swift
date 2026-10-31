import DesignSystem
import SwiftUI

/// The field's 28 pt round button: Send (disabled or ready) or Stop. Under
/// the pointer, Send with text and Stop keep their fill, lightened
/// (`ChatHover.filledOpacity`); disabled Send does not respond.
struct ChatRoundButton: View {
    let kind: ChatFieldPresentation.ButtonKind
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(fill)
                    .opacity(isHovered && kind != .sendDisabled ? ChatHover.filledOpacity : 1)
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
        .onHover { isHovered = $0 }
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

/// The chat's one hover state: under the pointer, or pressed, an enabled
/// button takes the `neutralChip` wash in its own shape, as History and
/// Copy do. The filled round buttons keep their fill and lighten instead,
/// so Send stays green.
enum ChatHover {
    /// Send's and Stop's fill under the pointer.
    static let filledOpacity = 0.85

    static func showsWash(isHovered: Bool, isPressed: Bool, isEnabled: Bool) -> Bool {
        isEnabled && (isHovered || isPressed)
    }
}

/// A small bordered button inside the field or an answer's footer: "Open
/// Settings", "Turn On", "Retry". `cardFill`, a `cardStroke` border,
/// `chipRadius`, sage medium text; the hover wash over the fill.
struct ChatInlineButtonStyle: ButtonStyle {
    var height: CGFloat = Tokens.chatRoundButton
    var fontSize: CGFloat = 12.5

    func makeBody(configuration: Configuration) -> some View {
        ChatInlineButtonBody(configuration: configuration, height: height, fontSize: fontSize)
    }
}

private struct ChatInlineButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    let fontSize: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.chipRadius, style: .continuous)
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(isEnabled ? Color.sage : Color.inkTertiary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background {
                shape.fill(Tokens.cardFill)
                if ChatHover.showsWash(isHovered: isHovered, isPressed: configuration.isPressed, isEnabled: isEnabled) {
                    shape.fill(Tokens.neutralChip)
                }
            }
            .overlay { shape.strokeBorder(Tokens.cardStroke, lineWidth: 1) }
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .fixedSize()
    }
}

/// An icon button with the rounded `neutralChip` fill while hovered or pressed.
struct ChatHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverHighlight(isPressed: configuration.isPressed) { configuration.label }
    }
}

/// The round jump-to-newest button: `cardFill` with a `cardStroke` ring and
/// a shadow, and the hover wash over the fill.
struct ChatCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChatCircleButtonBody(configuration: configuration)
    }
}

private struct ChatCircleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .frame(width: Tokens.chatRoundButton, height: Tokens.chatRoundButton)
            .background {
                Circle().fill(Tokens.cardFill).shadow(color: Tokens.cardShadow, radius: 6, y: 2)
                if ChatHover.showsWash(isHovered: isHovered, isPressed: configuration.isPressed, isEnabled: isEnabled) {
                    Circle().fill(Tokens.neutralChip)
                }
            }
            .overlay { Circle().strokeBorder(Tokens.cardStroke, lineWidth: 1) }
            .contentShape(Circle())
            .onHover { isHovered = $0 }
    }
}

/// The chat card header's icon buttons: New chat and Close chat. As high
/// as History, with its hover wash.
struct ChatHeaderIconButton: View {
    static let size: CGFloat = 26

    let systemImage: String
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.inkSecondary)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChatHoverButtonStyle())
        .help(help)
        .accessibilityLabel(label)
    }
}
