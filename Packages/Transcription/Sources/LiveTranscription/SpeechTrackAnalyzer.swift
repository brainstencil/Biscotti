import Foundation
import LiveTranscriptModel

/// Audio for one track's analyzer.
package struct SpeechInput: Equatable {
    /// 16 kHz mono Float32, as the live pump sends it.
    package var samples: [Float]
    /// The input's time on the recording timeline when it is the analyzer's
    /// first; nil when it follows the previous input.
    package var startTime: TimeInterval?

    package init(samples: [Float], startTime: TimeInterval?) {
        self.samples = samples
        self.startTime = startTime
    }
}

/// One result of a track's analyzer, with times on the recording timeline.
package struct SpeechResult: Equatable {
    /// Final results carry one word per time range. A volatile result carries
    /// one word for its whole text, because the analyzer times only final text.
    package var words: [TimedWord]
    package var start: TimeInterval
    package var end: TimeInterval
    /// Final text never changes; volatile text is replaced by the next result.
    package var isFinal: Bool
    /// The analyzer will not change results before this time.
    package var finalizedThrough: TimeInterval

    package init(words: [TimedWord], start: TimeInterval, end: TimeInterval, isFinal: Bool, finalizedThrough: TimeInterval) {
        self.words = words
        self.start = start
        self.end = end
        self.isFinal = isFinal
        self.finalizedThrough = finalizedThrough
    }
}

package enum SpeechAnalyzerEvent: Equatable {
    case result(SpeechResult)
    /// The analyzer has taken the audio up to this time.
    case received(through: TimeInterval)
}

/// One track's speech analyzer, as `SpeechAnalyzerLiveSession` drives it.
///
/// The system analyzer implements it on macOS 26; tests use a fake, so the
/// session is tested on every macOS the package supports.
package protocol SpeechTrackAnalyzer: Sendable {
    /// Results and progress, in the order the analyzer produced them. Ends
    /// after `finish()`, or throws when the analyzer fails or is cancelled.
    var events: AsyncThrowingStream<SpeechAnalyzerEvent, any Error> { get }
    /// Queues audio without waiting.
    /// - Returns: False when the audio was dropped: the input queue was full,
    ///   or the audio could not be converted. The session reports either as a
    ///   `queueOverflow` gap.
    func enqueue(_ input: SpeechInput) -> Bool
    /// Ends the input and finalizes everything received; `events` ends once
    /// the last results are out.
    func finish() async throws
    func cancel() async
}

/// Creates a session's analyzers: one per track at the start, and a fresh one
/// for a track after a long gap.
package protocol SpeechTrackAnalyzerFactory: Sendable {
    /// - Parameter locale: A locale identifier such as "en-US".
    /// - Throws: `LiveSessionError.languageUnsupported`, `.assetNotInstalled`
    ///   or `.engineUnavailable`.
    func makeAnalyzer(for track: LiveTrack, locale: String, vocabulary: [String]) async throws -> any SpeechTrackAnalyzer
}
