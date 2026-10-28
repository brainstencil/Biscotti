import DataStore
import Foundation
import Intelligence
import LiveTranscriptionService
import MeetingChat
import os
import Recording
import TranscriptionService

public extension MeetingChatService {
    /// The chat service on AppCore's other services: the active model, the
    /// recording in progress and the final passes.
    convenience init(
        store: DataStore,
        broker: LLMBroker,
        modelManager: ModelManager,
        live: LiveTranscriptionService,
        recording: RecordingController,
        transcription: TranscriptionService,
        policy: ChatResourcePolicy = .forThisMac(),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.init(
            store: store,
            broker: broker,
            modelURL: { modelManager.activeModelURL() },
            live: live,
            recordingMeetingID: { recording.recordingMeetingID },
            isTranscribing: { transcription.jobs[$0]?.isInProgress ?? false },
            policy: policy,
            clock: clock
        )
    }
}

extension JobStatus {
    /// Queued or running: the transcript is on its way.
    var isInProgress: Bool {
        switch self {
        case .downloadingModel, .transcribing, .queued: true
        case .idle, .completed, .failed: false
        }
    }
}

private let chatLogger = Logger(subsystem: "net.scosman.biscotti", category: "AppCore")

extension AppCore {
    /// Connects chat to the rest of the app: its "Turn On" action, and every
    /// final pass that saves a transcript, whoever asked for it (after Stop,
    /// the meeting page's Retry, re-transcription).
    func connectChat() {
        chat.onTurnOnLiveTranscript = { [weak self] in
            await self?.turnOnLiveTranscriptForChat()
        }
        // In the turn that marks the job completed, so chat never reads
        // "no transcript" in between.
        transcription.onTranscriptSaved = { [weak self] meetingID in
            self?.chat.transcriptWasSaved(meetingID: meetingID)
        }
    }

    /// Chat's "Turn On" while the live transcript is off: the same as the
    /// Settings toggle. The setting is saved and live transcription starts
    /// from now, with a start marker. The recording before that moment gets
    /// no live text, so chat cannot answer about it until the final
    /// transcript is saved. (The functional spec has the live transcript
    /// catch up from the start of the recording; it does not.)
    private func turnOnLiveTranscriptForChat() async {
        do {
            try await store.updateSettings { $0.liveTranscriptEnabled = true }
        } catch {
            chatLogger.error("Couldn't save the live transcript setting: \(error.localizedDescription, privacy: .private)")
        }
        await liveTranscription.setEnabled(true)
        await prepareModelsInBackground()
    }
}
