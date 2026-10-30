import DataStore
import Formatting
import Foundation
import LiveTranscriptModel

/// Turns a transcript into the timestamped lines the model reads and cites.
public enum ChatEvidence {
    static let youSpeaker = "You"
    static let othersSpeaker = "Others"
    /// A saved segment joins the previous line, from the same speaker, while the pause before it is under this.
    static let mergePause: TimeInterval = 3
    /// The most a merged line spans, from its first segment's start to its last segment's end.
    static let maxLineSpan: TimeInterval = 60
    /// Gaps touching within this are one stretch.
    static let gapJoinTolerance: TimeInterval = 0.05
    /// A stretch is listed when the parts of it that may have held sound add up
    /// to this. Matches the drawer's `TranscriptItemBuilder.minimumGapMarker`.
    static let minimumGap: TimeInterval = 5

    public static func lines(for transcript: ChatTranscript) -> [ChatEvidenceLine] {
        switch transcript {
        case let .live(snapshot): snapshotLines(snapshot, keepsTail: true)
        case let .draft(snapshot): snapshotLines(snapshot, keepsTail: false)
        case let .saved(data): savedLines(data)
        }
    }

    /// Stretches the live transcript does not cover, merged across tracks, in
    /// time order, at their full length. A stretch that is almost all known
    /// silence missed nothing and is left out.
    public static func gaps(for transcript: ChatTranscript) -> [ClosedRange<TimeInterval>] {
        switch transcript {
        case let .live(snapshot), let .draft(snapshot): mergedGaps(snapshot.gaps)
        case .saved: []
        }
    }

    /// "4:05" under an hour, "1:02:09" from an hour; floored to whole seconds.
    public static func format(_ time: TimeInterval) -> String {
        TimeFormatting.formatPlaybackTime(time)
    }

    /// The transcript as the prompt gives it: lines and gaps in time order.
    static func entries(for transcript: ChatTranscript) -> [ChatEvidenceEntry] {
        let lineEntries = lines(for: transcript).map { ChatEvidenceEntry(start: $0.start, formatted: formatted($0), line: $0) }
        let gapEntries = gaps(for: transcript).map {
            ChatEvidenceEntry(start: $0.lowerBound, formatted: rangeMarker($0, note: "not transcribed"), line: nil)
        }
        return (gapEntries + lineEntries).enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    /// `[4:05] Others: text {tail}`; the braces appear only with a tail.
    static func formatted(_ line: ChatEvidenceLine) -> String {
        let speaker = line.speaker.isEmpty ? "" : "\(line.speaker): "
        let tail = line.unsettled.isEmpty ? "" : "{\(line.unsettled)}"
        let body = [line.text, tail].filter { !$0.isEmpty }.joined(separator: " ")
        return "[\(format(line.start))] \(speaker)\(body)"
    }

    /// `[4:05–4:20 note]`.
    static func rangeMarker(_ range: ClosedRange<TimeInterval>, note: String) -> String {
        "[\(format(range.lowerBound))–\(format(range.upperBound)) \(note)]"
    }

    // MARK: - Private

    /// One line per row. A draft will not change any more, so a tail that never
    /// settled joins its row's text.
    private static func snapshotLines(_ snapshot: LiveTranscriptSnapshot, keepsTail: Bool) -> [ChatEvidenceLine] {
        snapshot.rows.compactMap { row in
            let speaker = speaker(for: row.track)
            let line = keepsTail
                ? ChatEvidenceLine(start: row.startTime, speaker: speaker, text: singleLine(row.settledText), unsettled: singleLine(row.tailText))
                : ChatEvidenceLine(start: row.startTime, speaker: speaker, text: singleLine(row.settledText + row.tailText))
            return line.text.isEmpty && line.unsettled.isEmpty ? nil : line
        }
    }

    private static func speaker(for track: LiveTrack) -> String {
        switch track {
        case .mic: youSpeaker
        case .system: othersSpeaker
        case .mixed: ""
        }
    }

    private static func savedLines(_ data: TranscriptData) -> [ChatEvidenceLine] {
        var lines: [ChatEvidenceLine] = []
        var lineEnd: TimeInterval = 0
        for segment in data.segments where hasText(segment.text) {
            let text = singleLine(segment.text)
            let speaker = segment.speakerID.flatMap(data.speakerName(forID:)) ?? segment.speakerLabel
            if let last = lines.last, last.speaker == speaker,
               segment.startTime - lineEnd < mergePause,
               segment.endTime - last.start <= maxLineSpan
            {
                lines[lines.count - 1].text += " " + text
                lineEnd = max(lineEnd, segment.endTime)
            } else {
                lines.append(ChatEvidenceLine(start: segment.startTime, speaker: speaker, text: text))
                lineEnd = segment.endTime
            }
        }
        return lines
    }

    /// Touching gaps join into one stretch whether silent or not: a stall over
    /// speech is stored as alternating silent and not-silent pieces, and only
    /// together are they long enough to list. The same rule as the drawer's
    /// `TranscriptItemBuilder.gapMarkers` in `TranscriptUI`, which this module
    /// cannot import, so the model sees the gaps the user sees.
    private static func mergedGaps(_ gaps: [LiveGap]) -> [ClosedRange<TimeInterval>] {
        var stretches: [GapStretch] = []
        for gap in gaps.sorted(by: { $0.startTime < $1.startTime }) where gap.duration > 0 {
            if let last = stretches.last, gap.startTime <= last.end + gapJoinTolerance {
                stretches[stretches.count - 1].add(gap)
            } else {
                stretches.append(GapStretch(gap))
            }
        }
        return stretches.filter { $0.mayHaveHeldSound >= minimumGap }.map { $0.start ... $0.end }
    }

    /// Whether a transcript segment's text gives chat anything to read: the
    /// one rule for "the transcript has text", used by the evidence, the
    /// field's availability and the save hook.
    static func hasText(_ text: String) -> Bool {
        !singleLine(text).isEmpty
    }

    /// Whether a draft gives chat a line to read: a row whose text, its tail
    /// joined as the draft's evidence joins it, has text by the same rule.
    static func hasText(_ draft: LiveTranscriptSnapshot) -> Bool {
        draft.rows.contains { hasText($0.settledText + $0.tailText) }
    }

    /// One prompt line per entry: line breaks inside the text become spaces.
    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Touching gaps, and how much of them may have held sound: the union of the
/// gaps not known to be silent. Gaps join in start-time order. Mirrors
/// `GapStretch` in `TranscriptUI/TranscriptItemBuilder.swift`.
private struct GapStretch {
    let start: TimeInterval
    private(set) var end: TimeInterval
    private(set) var mayHaveHeldSound: TimeInterval = 0
    private var soundEnd = -TimeInterval.infinity

    init(_ gap: LiveGap) {
        start = gap.startTime
        end = gap.startTime
        add(gap)
    }

    mutating func add(_ gap: LiveGap) {
        end = max(end, gap.endTime)
        guard !gap.isSilent else { return }
        mayHaveHeldSound += max(0, gap.endTime - max(gap.startTime, soundEnd))
        soundEnd = max(soundEnd, gap.endTime)
    }
}

/// A transcript line or a gap, as the prompt lists it.
struct ChatEvidenceEntry: Equatable {
    let start: TimeInterval
    let formatted: String
    /// Nil for a gap, which is not evidence anything was said.
    let line: ChatEvidenceLine?
}
