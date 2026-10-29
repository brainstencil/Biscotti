import Foundation

/// Held live decoding, from `LiveTranscriptionService.holdDecoding(reason:maximum:)`.
/// Release it once; releasing twice does nothing. A hold that is never
/// released is released by its `maximum` timeout (a main-actor class cannot
/// release from `deinit`).
@MainActor
public final class LiveDecodingHold {
    public let reason: String
    /// Tells the service; nil once the hold has ended.
    private var onRelease: (@MainActor (LiveDecodingHold) -> Void)?
    /// Releases the hold at its `maximum`.
    var timeout: Task<Void, Never>?

    init(reason: String, onRelease: @escaping @MainActor (LiveDecodingHold) -> Void) {
        self.reason = reason
        self.onRelease = onRelease
    }

    var isReleased: Bool {
        onRelease == nil
    }

    public func release() {
        guard let onRelease else { return }
        invalidate()
        onRelease(self)
    }

    /// Ends the hold without telling the service, which has dropped it.
    func invalidate() {
        onRelease = nil
        timeout?.cancel()
        timeout = nil
    }
}
