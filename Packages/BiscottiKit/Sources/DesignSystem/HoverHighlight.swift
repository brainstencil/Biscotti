import SwiftUI

/// A rounded `neutralChip` fill while hovered or pressed. Used by small
/// menu and icon buttons, such as the live transcript's language menu and
/// the chat's History menu.
public struct HoverHighlight<Content: View>: View {
    let isPressed: Bool
    let content: Content
    @State private var isHovered = false

    public init(isPressed: Bool, @ViewBuilder content: () -> Content) {
        self.isPressed = isPressed
        self.content = content()
    }

    public var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Tokens.buttonRadius, style: .continuous)
                    .fill(isHovered || isPressed ? Tokens.neutralChip : Color.clear)
            }
            .onHover { isHovered = $0 }
    }
}
