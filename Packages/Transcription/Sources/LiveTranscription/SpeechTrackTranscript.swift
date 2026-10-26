import Foundation
import LiveTranscriptModel

/// Turns one track's SpeechAnalyzer events into append-only rows and the
/// track's watermarks.
///
/// A final result settles its words; a volatile result replaces the tail.
/// The watermarks follow only what the analyzer reports: it reports nothing
/// during silence, and a gap the session records does not tell whether the
/// analyzer still holds text from before it.
struct SpeechTrackTranscript {
    struct Watermarks: Equatable {
        var transcribedThrough: TimeInterval
        var settledThrough: TimeInterval
    }

    let track: LiveTrack
    /// The end of the audio the analyzer has accepted or reported on. The
    /// analyzer's intake is used, not only result ends, because it reports no
    /// results for silence; it is not how far analysis has got.
    private(set) var transcribedThrough: TimeInterval
    /// The analyzer's finalization point, as carried by the results delivered
    /// so far, so it never runs ahead of the final text behind it.
    private(set) var settledThrough: TimeInterval
    private var rows: LiveRowBuilder

    init(track: LiveTrack, startTime: TimeInterval) {
        self.track = track
        transcribedThrough = startTime
        settledThrough = startTime
        rows = LiveRowBuilder(track: track)
    }

    var watermarks: Watermarks {
        Watermarks(transcribedThrough: transcribedThrough, settledThrough: settledThrough)
    }

    /// - Returns: The rows created or changed.
    mutating func apply(_ event: SpeechAnalyzerEvent) -> [LiveRow] {
        switch event {
        case let .received(through):
            transcribedThrough = max(transcribedThrough, through)
            return []
        case let .result(result):
            let before = rows.currentRows
            transcribedThrough = max(transcribedThrough, result.end)
            if result.isFinal {
                rows.settle(result.words)
                rows.setTail([])
            } else {
                rows.setTail(result.words)
            }
            settledThrough = max(settledThrough, min(result.finalizedThrough, transcribedThrough))
            return rows.takeChanges(since: before)
        }
    }

    /// Closes the open row, when the session finishes or an analyzer is
    /// replaced after a long gap; later text starts a new row.
    /// - Parameters:
    ///   - incomplete: The analyzer did not finish: the tail is settled as it
    ///     is and the rows this changes are marked incomplete.
    ///   - end: The end of the analyzer's audio, which a complete finish has resolved.
    mutating func close(incomplete: Bool, through end: TimeInterval) -> [LiveRow] {
        let before = rows.currentRows
        if incomplete {
            rows.settle(rows.tail)
        } else {
            transcribedThrough = max(transcribedThrough, end)
        }
        rows.setTail([])
        rows.closeOpenRow()
        settledThrough = max(settledThrough, transcribedThrough)
        var changed = rows.takeChanges(since: before)
        if incomplete {
            for index in changed.indices {
                changed[index].isIncomplete = true
            }
        }
        return changed
    }
}
