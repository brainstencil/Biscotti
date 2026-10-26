import CoreMedia
import Foundation
import LiveTranscriptModel
import Speech
import Testing
@testable import LiveTranscription

/// Only the mapping of Apple's result text runs; no analyzer is created.
@Suite("System speech analyzer")
struct SystemSpeechAnalyzerTests {
    @available(macOS 26, *)
    @Test("words come from the time-range runs; untimed runs take the result's range and spaces join the next word")
    func wordsComeFromTimeRangeRuns() {
        func timed(_ text: String, _ start: Double, _ end: Double) -> AttributedString {
            var run = AttributedString(text)
            run.audioTimeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000), end: CMTime(seconds: end, preferredTimescale: 1000))
            return run
        }
        let text = timed("Hello,", 100, 100.48) + AttributedString(" ") + timed("everyone.", 100.48, 100.96) + AttributedString(" again")

        let words = SpeechResult.words(in: text, start: 100, end: 101.02)

        #expect(words == [
            TimedWord(text: "Hello,", start: 100, end: 100.48),
            TimedWord(text: " everyone.", start: 100.48, end: 100.96),
            TimedWord(text: " again", start: 100, end: 101.02)
        ])
    }
}
