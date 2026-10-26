import Foundation
import LiveTranscriptModel
import Synchronization

/// Releases a clip's audio in 100 ms steps, as capture would deliver it, and
/// exposes only the samples whose time has arrived.
///
/// One task releases steps; any task may read how far the source has got.
final class PacedSource: Sendable {
    /// How steps are timed.
    struct Pacing {
        /// True when steps follow one another at once and times are simulated.
        let isSimulated: Bool
        /// Returns once `elapsed` has passed since the source was created.
        let reach: @Sendable (_ elapsed: Duration) async throws -> Void

        /// Each step waits for its own deadline on `clock`, so steps do not drift.
        static func realTime(_ clock: some Clock<Duration>) -> Pacing {
            let origin = clock.now
            return Pacing(isSimulated: false) { elapsed in
                try await clock.sleep(until: origin.advanced(by: elapsed), tolerance: nil)
            }
        }

        /// Each step moves `clock`, which the session also reads, at once.
        static func simulated(_ clock: VirtualClock) -> Pacing {
            let origin = clock.now
            return Pacing(isSimulated: true) { elapsed in
                let remaining = clock.now.duration(to: origin.advanced(by: elapsed))
                if remaining > .zero {
                    clock.advance(by: remaining)
                }
            }
        }
    }

    static let step = Duration.milliseconds(100)
    static let stepSamples = 1600

    let sampleCount: Int
    private let pacing: Pacing
    private let releasedSteps = Mutex(0)

    init(sampleCount: Int, pacing: Pacing) {
        self.sampleCount = sampleCount
        self.pacing = pacing
    }

    var isSimulated: Bool {
        pacing.isSimulated
    }

    var releasedSamples: Int {
        min(releasedSteps.withLock { $0 } * Self.stepSamples, sampleCount)
    }

    /// Source time: the end of the audio released so far, on the clip's timeline.
    var releasedThrough: TimeInterval {
        Double(releasedSamples) / LiveAudioChunk.sampleRate
    }

    /// Waits for the next step's time, then releases it.
    /// - Returns: False once every sample has been released.
    func releaseNextStep() async throws -> Bool {
        let step = releasedSteps.withLock { $0 }
        guard step * Self.stepSamples < sampleCount else { return false }
        try await pacing.reach(Self.step * (step + 1))
        releasedSteps.withLock { $0 = step + 1 }
        return true
    }
}
