import Foundation

/// The "Loading the AI model…" line and its bar. The bar fills against the
/// last measured load of the model on this Mac, an estimate from earlier
/// loads, not a measure of this one, so it never claims the load is done:
/// it stops at `maximumFraction` until the load ends.
struct ChatModelLoadPresentation: Equatable {
    static let loadingText = "Loading the AI model…"
    static let longerText = "longer than last time"
    /// The bar holds here until the load really ends.
    static let maximumFraction = 0.9

    /// "Loading the AI model… 12 s", or "Loading the AI model… 52 s, longer
    /// than last time" once the load runs past the estimate.
    let text: String
    /// How full the bar is; nil for an indeterminate bar, before any load of
    /// the model was measured.
    let fraction: Double?
    /// What VoiceOver reads and announces: the same without the seconds, so
    /// it changes once, when the load runs past the estimate, not every second.
    let accessibilityText: String

    /// - Parameters:
    ///   - elapsed: Since the load started; nil when the start is unknown,
    ///     which shows no seconds.
    ///   - estimate: The model's last measured load.
    static func make(elapsed: Duration?, estimate: Duration?) -> Self {
        guard let elapsed = elapsed.map({ max($0, .zero) }) else {
            return Self(text: loadingText, fraction: nil, accessibilityText: spoken(loadingText))
        }
        let seconds = Int(elapsed / .seconds(1))
        guard let estimate, estimate > .zero else {
            return Self(text: "\(loadingText) \(seconds) s", fraction: nil, accessibilityText: Self.spoken(loadingText))
        }
        let fraction = min(elapsed / estimate, maximumFraction)
        guard elapsed > estimate else {
            return Self(text: "\(loadingText) \(seconds) s", fraction: fraction, accessibilityText: Self.spoken(loadingText))
        }
        return Self(
            text: "\(loadingText) \(seconds) s, \(longerText)",
            fraction: fraction,
            accessibilityText: "\(Self.spoken(loadingText)), \(longerText)"
        )
    }

    /// The text without its trailing ellipsis, which VoiceOver reads aloud.
    private static func spoken(_ text: String) -> String {
        text.hasSuffix("…") ? String(text.dropLast()) : text
    }
}
