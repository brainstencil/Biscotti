import SwiftUI

/// A quiet brand sign-off lockup: brand mark, wordmark, and tagline.
/// Reused by Home (with caller-supplied top padding) and onboarding.
public struct BrandFooter: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 3) {
            BrandMark()

            Text("Biscotti")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(.ink)
            Text("Total recall, total privacy.")
                .font(.system(size: 12))
                .foregroundStyle(.inkTertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
