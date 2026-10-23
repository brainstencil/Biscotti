import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("BrandMark")
struct BrandMarkTests {
    @Test("Artwork renders in sage, not its own baked-in black fill")
    @MainActor
    func artworkRendersInSage() throws {
        let side = 20
        let artwork = try Image(decorative: halfBlackArtwork(side: side), scale: 1)
        let renderer = ImageRenderer(content: BrandMark(artwork: artwork, height: CGFloat(side)))
        renderer.proposedSize = ProposedViewSize(width: CGFloat(side), height: CGFloat(side))
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: rendered)

        let midY = bitmap.pixelsHigh / 2
        let painted = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: midY)?.usingColorSpace(.sRGB))
        let unpainted = try #require(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: midY))

        let sageVariants = [NSAppearance.Name.aqua, .darkAqua].compactMap { resolvedSRGB(.sage, in: $0) }
        #expect(sageVariants.count == 2)
        #expect(
            sageVariants.contains { isClose(painted, $0) },
            "Opaque artwork pixel should be sage, got \(painted)"
        )
        #expect(unpainted.alphaComponent < 0.05, "Transparent artwork pixel should stay transparent")
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

/// A square image whose left half is opaque black and right half transparent,
/// standing in for the SVG's baked-in black fill.
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

private func resolvedSRGB(_ color: NSColor, in appearanceName: NSAppearance.Name) -> NSColor? {
    var resolved: NSColor?
    NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
        resolved = color.usingColorSpace(.sRGB)
    }
    return resolved
}

/// Both colours must be sRGB. The tolerance absorbs 8-bit rendering and
/// colour-space round-trips.
private func isClose(_ lhs: NSColor, _ rhs: NSColor, tolerance: CGFloat = 0.02) -> Bool {
    abs(lhs.redComponent - rhs.redComponent) <= tolerance
        && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
        && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
        && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
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
