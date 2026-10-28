import DataStore
import Foundation
import LiveTranscriptModel
import Testing
@testable import MeetingChat

@Suite("ChatEvidence")
struct ChatEvidenceTests {
    @Test("live rows become lines: mic is You, system is Others, tails are unsettled")
    func liveRowsBecomeLines() {
        let snapshot = ChatFixtures.snapshot(rows: [
            LiveRow(track: .system, startTime: 3.4, endTime: 6, settledText: " Let's look at the remote."),
            LiveRow(track: .mic, startTime: 21, endTime: 25, settledText: "What if I had a magnet on the back", tailText: " of it and"),
            LiveRow(track: .system, startTime: 30, endTime: 31, tailText: " Maybe.")
        ])

        let transcript = ChatTranscript.live(snapshot)

        #expect(ChatEvidence.lines(for: transcript) == [
            ChatEvidenceLine(start: 3.4, speaker: "Others", text: "Let's look at the remote."),
            ChatEvidenceLine(start: 21, speaker: "You", text: "What if I had a magnet on the back", unsettled: "of it and"),
            ChatEvidenceLine(start: 30, speaker: "Others", text: "", unsettled: "Maybe.")
        ])
        #expect(ChatEvidence.entries(for: transcript).map(\.formatted) == [
            "[0:03] Others: Let's look at the remote.",
            "[0:21] You: What if I had a magnet on the back {of it and}",
            "[0:30] Others: {Maybe.}"
        ])
    }

    @Test("a draft has no tail: words that never settled join the text")
    func draftTailJoinsText() {
        let snapshot = ChatFixtures.snapshot(rows: [
            LiveRow(track: .mic, startTime: 5, endTime: 9, settledText: "Battery life is", tailText: " about a year", isIncomplete: true)
        ])

        #expect(ChatEvidence.lines(for: .draft(snapshot)) == [
            ChatEvidenceLine(start: 5, speaker: "You", text: "Battery life is about a year")
        ])
    }

    @Test("rows from the one-track fallback name no speaker")
    func mixedRowsNameNoSpeaker() {
        let snapshot = ChatFixtures.snapshot(rows: [
            LiveRow(track: .mixed, startTime: 5, endTime: 7, settledText: "Hello\neveryone.")
        ])

        #expect(ChatEvidence.entries(for: .live(snapshot)).map(\.formatted) == ["[0:05] Hello everyone."])
    }

    @Test("saved segments merge while the speaker and the flow continue")
    func savedSegmentsMergeSameSpeaker() {
        let transcript = ChatFixtures.saved([
            ChatFixtures.segment(0, 4, "Welcome."),
            ChatFixtures.segment(5, 9, "Let's start."), // 1 s pause: merges
            ChatFixtures.segment(13, 15, "First item."), // 4 s pause: new line
            ChatFixtures.segment(15.5, 18, "I agree.", speaker: 1), // other speaker: new line
            ChatFixtures.segment(18.5, 50, "A long point,", speaker: 1),
            ChatFixtures.segment(50.5, 76, "and more of it.", speaker: 1), // would span 60.5 s: new line
            ChatFixtures.segment(76.5, 77, "", speaker: 1), // blank: skipped
            ChatFixtures.segment(77.5, 79, "Done.", speaker: 1)
        ])

        let lines = ChatEvidence.lines(for: .saved(transcript))

        #expect(lines == [
            ChatEvidenceLine(start: 0, speaker: "Speaker 1", text: "Welcome. Let's start."),
            ChatEvidenceLine(start: 13, speaker: "Speaker 1", text: "First item."),
            ChatEvidenceLine(start: 15.5, speaker: "Speaker 2", text: "I agree. A long point,"),
            ChatEvidenceLine(start: 50.5, speaker: "Speaker 2", text: "and more of it. Done.")
        ])
        #expect(ChatEvidence.gaps(for: .saved(transcript)).isEmpty)
    }

    @Test("an assigned person's name replaces the diarization label")
    func speakerNamesPreferAssignments() {
        let transcript = ChatFixtures.saved(
            [ChatFixtures.segment(0, 3, "Morning."), ChatFixtures.segment(4, 6, "Hi.", speaker: 1)],
            names: [1: "Kate"]
        )

        #expect(ChatEvidence.entries(for: .saved(transcript)).map(\.formatted) == [
            "[0:00] Speaker 1: Morning.",
            "[0:04] Kate: Hi."
        ])
    }

    @Test("times are floored to whole seconds, with hours from an hour")
    func timesFormat() {
        #expect(ChatEvidence.format(65) == "1:05")
        #expect(ChatEvidence.format(3729) == "1:02:09")
        #expect(ChatEvidence.format(59.9) == "0:59")
        #expect(ChatEvidence.format(0) == "0:00")
    }

    @Test("gaps merge across tracks and are listed in time order; silent and short ones are left out")
    func gapsBecomeLines() {
        let snapshot = ChatFixtures.snapshot(
            rows: [
                LiveRow(track: .system, startTime: 240, endTime: 244, settledText: "Before."),
                LiveRow(track: .system, startTime: 262, endTime: 266, settledText: "After.")
            ],
            gaps: [
                LiveGap(track: .system, startTime: 245, duration: 10, reason: .queueOverflow),
                LiveGap(track: .mic, startTime: 250, duration: 10, reason: .engineRestart),
                LiveGap(track: .mic, startTime: 300, duration: 30, reason: .queueOverflow, isSilent: true),
                LiveGap(track: .mic, startTime: 400, duration: 2, reason: .captureGap)
            ]
        )

        let transcript = ChatTranscript.live(snapshot)

        #expect(ChatEvidence.gaps(for: transcript) == [245 ... 260])
        #expect(ChatEvidence.entries(for: transcript).map(\.formatted) == [
            "[4:00] Others: Before.",
            "[4:05–4:20 not transcribed]",
            "[4:22] Others: After."
        ])
        #expect(ChatEvidence.entries(for: transcript).compactMap(\.line).count == 2)
    }

    @Test("a stall over speech, stored as alternating silent and not-silent gaps, is one gap at its full length")
    func stallOverSpeechIsOneGap() {
        // 3 s of dropped speech, then 1 s of dropped silence, ten times from 1:40.
        let gaps = (0 ..< 10).flatMap { cycle in
            let start = 100 + Double(cycle) * 4
            return [
                LiveGap(track: .system, startTime: start, duration: 3, reason: .queueOverflow),
                LiveGap(track: .system, startTime: start + 3, duration: 1, reason: .queueOverflow, isSilent: true)
            ]
        }
        let snapshot = ChatFixtures.snapshot(
            rows: [LiveRow(track: .system, startTime: 90, endTime: 99, settledText: "Before."), LiveRow(track: .system, startTime: 141, endTime: 145, settledText: "After.")],
            gaps: gaps
        )

        #expect(ChatEvidence.entries(for: .live(snapshot)).map(\.formatted) == [
            "[1:30] Others: Before.",
            "[1:40–2:20 not transcribed]",
            "[2:21] Others: After."
        ])
    }

    @Test("a stretch with under five seconds that may have held sound is left out")
    func mostlySilentStretchLeftOut() {
        let snapshot = ChatFixtures.snapshot(rows: [], gaps: [
            LiveGap(track: .mic, startTime: 10, duration: 20, reason: .queueOverflow, isSilent: true),
            LiveGap(track: .system, startTime: 12, duration: 4, reason: .queueOverflow),
            LiveGap(track: .mic, startTime: 14, duration: 4, reason: .engineRestart)
        ])

        // The not-silent parts overlap: 12 to 18 s is 6 s, so the stretch is kept; without the mic gap it would be 4 s.
        #expect(ChatEvidence.gaps(for: .live(snapshot)) == [10 ... 30])
        let shorter = ChatFixtures.snapshot(rows: [], gaps: Array(snapshot.gaps.prefix(2)))
        #expect(ChatEvidence.gaps(for: .live(shorter)).isEmpty)
    }
}
