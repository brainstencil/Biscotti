import SwiftUI

/// The Biscotti brand mark: the shield + mic glyph, tinted sage.
///
/// Draws the menu-bar artwork from the app's asset catalog rather than a
/// second copy of the SVG. That asset lives in the app target, so it resolves
/// from the main bundle at runtime and renders blank in package previews.
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
        // The colour comes from a sage fill cut to the artwork's alpha, not
        // from template rendering, so it never depends on whether the image
        // source honours template mode or on the SVG's baked-in black fill.
        fittedArtwork
            .frame(height: height)
            .overlay { Color.sage }
            .mask { fittedArtwork }
    }

    /// `.original` keeps the mask's alpha the artwork's own: a template
    /// image would instead draw in the inherited foreground style, whose
    /// default (label colour) is partly transparent and would fade the mark.
    private var fittedArtwork: some View {
        artwork
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
    }
}
