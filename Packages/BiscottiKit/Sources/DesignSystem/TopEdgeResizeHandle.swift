import SwiftUI

/// A card's draggable top edge, laid over the card with
/// `.overlay(alignment: .top)`: dragging it changes the card's height,
/// double-clicking restores the default, and VoiceOver adjusts it in steps.
/// A small grabber shows while the pointer is over it. The live transcript
/// drawer and the chat cards use it.
public struct TopEdgeResizeHandle: View {
    static let hitHeight: CGFloat = 8

    let label: String
    let height: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
    @Binding var dragHeight: CGFloat?
    let onSave: (CGFloat) -> Void
    let onReset: () -> Void
    @State private var isHovering = false
    @State private var startHeight: CGFloat?
    /// Resets on its own when a drag ends or is cancelled, for example when
    /// the card hides mid-drag, which skips `onEnded`.
    @GestureState private var isDragging = false

    /// - Parameters:
    ///   - label: VoiceOver's name for the height, such as "Transcript height".
    ///   - height: The card's height now.
    ///   - range: The heights a drag or VoiceOver may reach.
    ///   - step: How far one VoiceOver adjustment moves the edge.
    ///   - dragHeight: The height while the edge is dragged, nil otherwise.
    ///   - onSave: A finished drag or adjustment, within `range`.
    ///   - onReset: A double-click: back to the default height.
    public init(
        label: String,
        height: CGFloat,
        range: ClosedRange<CGFloat>,
        step: CGFloat = 40,
        dragHeight: Binding<CGFloat?>,
        onSave: @escaping (CGFloat) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.label = label
        self.height = height
        self.range = range
        self.step = step
        _dragHeight = dragHeight
        self.onSave = onSave
        self.onReset = onReset
    }

    public var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.hitHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.inkTertiary)
                    .frame(width: 36, height: 4)
                    .padding(.top, 3)
                    .opacity(isHovering || dragHeight != nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isHovering)
            }
            .offset(y: -Self.hitHeight / 2)
            .pointerStyle(.frameResize(position: .top))
            .onHover { isHovering = $0 }
            .gesture(drag)
            .onChange(of: isDragging) { _, dragging in
                guard !dragging else { return }
                startHeight = nil
                dragHeight = nil
            }
            .onTapGesture(count: 2, perform: onReset)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(height.rounded())) points")
            .accessibilityHint("Drag to resize. Double-click to restore the default height.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: save(height + step)
                case .decrement: save(height - step)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "Restore default height", onReset)
    }

    /// Dragging up makes the card taller.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($isDragging) { _, dragging, _ in dragging = true }
            .onChanged { value in
                let start = startHeight ?? height
                startHeight = start
                dragHeight = clamp(start - value.translation.height)
            }
            .onEnded { value in
                let start = startHeight ?? height
                startHeight = nil
                dragHeight = nil
                save(start - value.translation.height)
            }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func save(_ value: CGFloat) {
        onSave(clamp(value))
    }
}
