import SwiftUI

/// The Biscotti brand mark: the shield + mic glyph, tinted sage.
///
/// Draws the menu-bar artwork from the app's asset catalog rather than a
/// second copy of the SVG. That asset lives in the app target, so it resolves
/// from the main bundle at runtime and renders blank in package previews.
/// The artwork is forced to template rendering so the sage tint replaces the
/// SVG's baked-in black fill.
public struct BrandMark: View {
    /// App asset-catalog name of the single-colour shield + mic artwork
    /// (shared with the idle menu-bar icon).
    nonisolated static let assetName = "MenuBarIcon"

    private let artwork: Image
    private let height: CGFloat

    /// - Parameter height: Rendered height in points; the width follows the
    ///   artwork's aspect ratio.
    public init(height: CGFloat = 16) {
        self.init(artwork: Image(decorative: Self.assetName), height: height)
    }

    init(artwork: Image, height: CGFloat) {
        self.artwork = artwork
        self.height = height
    }

    public var body: some View {
        artwork
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(.sage)
    }
}
