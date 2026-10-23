import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("BrandMark")
struct BrandMarkTests {
    /// Renders the mark over a stand-in for the SVG (opaque black left half,
    /// transparent right half) and compares it with a plain `Color.sage`
    /// swatch from the same renderer, so colour space and light/dark
    /// resolution are identical on both sides of the comparison.
    @Test("Artwork renders in opaque sage, whatever its own fill or rendering intent", arguments: ArtworkSource.allCases)
    @MainActor
    func artworkRendersInSage(source: ArtworkSource) throws {
        let side = 20
        let artwork = try source.image(side: side)
        let mark = try render(BrandMark(artwork: artwork, height: CGFloat(side)), side: side)
        let swatch = try render(Color.sage, side: side)

        let painted = try pixel(in: mark, atWidthFraction: 0.25, heightFraction: 0.5)
        let unpainted = try pixel(in: mark, atWidthFraction: 0.75, heightFraction: 0.5)
        let sage = try pixel(in: swatch, atWidthFraction: 0.25, heightFraction: 0.5)

        // The values sit in the expanded expressions (not just the comments)
        // so they survive `make test`'s one-line-per-issue output filter.
        #expect(sage.isOpaqueGreen, "Reference swatch should be opaque sage, got \(sage)")
        #expect(painted.isClose(to: sage), "Opaque artwork pixel \(painted) should match sage \(sage)")
        #expect(unpainted.isTransparent, "Transparent artwork pixel should stay transparent, got \(unpainted)")
    }

    @Test("Artwork asset is an SVG imageset in the app asset catalog")
    func artworkAssetIsSVGInAppCatalog() throws {
        let imageset = repoRoot()
            .appendingPathComponent("App/Resources/Assets.xcassets")
            .appendingPathComponent("\(BrandMark.assetName).imageset")
        let manifest = try JSONDecoder().decode(
            ImagesetManifest.self,
            from: Data(contentsOf: imageset.appendingPathComponent("Contents.json"))
        )

        let svgName = try #require(manifest.images.compactMap(\.filename).first { $0.hasSuffix(".svg") })
        #expect(FileManager.default.fileExists(atPath: imageset.appendingPathComponent(svgName).path))
    }
}

// MARK: - Helpers

/// The parts of an asset-catalog `Contents.json` this suite reads.
private struct ImagesetManifest: Decodable {
    struct Entry: Decodable {
        let filename: String?
    }

    let images: [Entry]
}

/// How the stand-in artwork reaches `BrandMark`: as a plain bitmap (like the
/// SVG's baked-in black fill) or flagged as a template (like the asset
/// catalog's template rendering intent).
enum ArtworkSource: CaseIterable {
    case plainBitmap
    case templateImage

    @MainActor
    func image(side: Int) throws -> Image {
        let bitmap = try halfBlackArtwork(side: side)
        switch self {
        case .plainBitmap:
            return Image(decorative: bitmap, scale: 1)
        case .templateImage:
            let template = NSImage(cgImage: bitmap, size: NSSize(width: side, height: side))
            template.isTemplate = true
            return Image(nsImage: template)
        }
    }
}

/// A square image whose left half is opaque black and right half transparent.
private func halfBlackArtwork(side: Int) throws -> CGImage {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))
    return try #require(context.makeImage())
}

/// An 8-bit sRGB pixel, described as `rgba(r, g, b, a)` in test output.
private struct RGBA8: CustomStringConvertible {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Int

    init(_ color: NSColor) {
        red = Self.channel(color.redComponent)
        green = Self.channel(color.greenComponent)
        blue = Self.channel(color.blueComponent)
        alpha = Self.channel(color.alphaComponent)
    }

    var description: String {
        "rgba(\(red), \(green), \(blue), \(alpha))"
    }

    var isTransparent: Bool {
        alpha <= 2
    }

    /// True for either sage variant (light #4E7D5C, dark #86C295) and false
    /// for a blank or black render.
    var isOpaqueGreen: Bool {
        alpha >= 253 && green > red && green > blue
    }

    /// Channel-wise match. The slack absorbs rounding through the mask's
    /// offscreen pass; real failures are far larger (black is >= 78 levels
    /// off in every colour channel, the other sage variant >= 56, a mark
    /// faded to label-colour opacity ~38 in alpha).
    func isClose(to other: RGBA8, tolerance: Int = 6) -> Bool {
        [red - other.red, green - other.green, blue - other.blue, alpha - other.alpha]
            .allSatisfy { abs($0) <= tolerance }
    }

    private static func channel(_ value: CGFloat) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }
}

@MainActor
private func render(_ content: some View, side: Int) throws -> CGImage {
    let renderer = ImageRenderer(content: content)
    renderer.proposedSize = ProposedViewSize(width: CGFloat(side), height: CGFloat(side))
    renderer.scale = 1
    return try #require(renderer.cgImage)
}

/// The sRGB pixel at the given fractions of the image's width and height.
@MainActor
private func pixel(in image: CGImage, atWidthFraction widthFraction: Double, heightFraction: Double) throws -> RGBA8 {
    let bitmap = NSBitmapImageRep(cgImage: image)
    let column = Int(Double(bitmap.pixelsWide) * widthFraction)
    let row = Int(Double(bitmap.pixelsHigh) * heightFraction)
    let color = try #require(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB))
    return RGBA8(color)
}

/// The repo root, five levels above this file
/// (Packages/BiscottiKit/Tests/DesignSystemTests/).
private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // DesignSystemTests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // BiscottiKit/
        .deletingLastPathComponent() // Packages/
        .deletingLastPathComponent() // repo root
}
