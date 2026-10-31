import DataStore
import Foundation

extension MeetingChatService {
    /// The transcript chat reads for a meeting now, with the meeting's
    /// detail: the live transcript while this meeting records, otherwise the
    /// preferred transcript, otherwise the draft. The transcript a chip
    /// click shows.
    func transcriptNow(for meetingID: UUID) async throws -> (transcript: ChatTranscript?, detail: MeetingDetailData?) {
        let isRecordingThis = recordingMeetingID() == meetingID
        // Taken before the store read, at the moment of the call.
        let snapshot = isRecordingThis ? live.snapshot(includeTail: true) : nil
        let detail = try await store.meetingDetail(id: meetingID)
        let transcript: ChatTranscript? = if isRecordingThis {
            snapshot.map { .live($0) }
        } else if let saved = detail?.preferredTranscript {
            .saved(saved)
        } else {
            live.draft(for: meetingID).map { .draft($0) }
        }
        return (transcript, detail)
    }

    /// The transcript line a time chip goes to, for the preview shown while
    /// the pointer rests on it: in the transcript a click shows
    /// (`transcriptNow(for:)`), the line the chip's time falls in. Nil when
    /// the meeting has no such line or its transcript cannot be read.
    public func citedLine(at time: TimeInterval, meetingID: UUID) async -> ChatEvidenceLine? {
        do {
            guard let transcript = try await transcriptNow(for: meetingID).transcript else { return nil }
            return Self.line(at: time, in: ChatEvidence.lines(for: transcript))
        } catch {
            logger.error("Couldn't read the meeting for a chip's line: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// The line starting at `time`, which is where a chip points (the start
    /// of the line it cites); otherwise the last line starting before it,
    /// the one a time inside a line falls in.
    nonisolated static func line(at time: TimeInterval, in lines: [ChatEvidenceLine]) -> ChatEvidenceLine? {
        let tolerance = 0.001
        if let exact = lines.first(where: { abs($0.start - time) < tolerance }) {
            return exact
        }
        return lines.filter { $0.start <= time }.max { $0.start < $1.start }
    }
}
