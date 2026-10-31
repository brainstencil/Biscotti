import DataStore
import Foundation
import Intelligence
import LiveTranscriptionService
import MeetingChat
import Observation
import os
import Recording
import TranscriptionService

public extension MeetingChatService {
    /// The chat service on AppCore's other services: the active model, the
    /// recording in progress and the final passes.
    ///
    /// - Parameter defaults: Keeps each meeting's open thread and draft
    ///   across launches; the app passes `.standard`, tests nil.
    convenience init(
        store: DataStore,
        broker: LLMBroker,
        modelManager: ModelManager,
        live: LiveTranscriptionService,
        recording: RecordingController,
        transcription: TranscriptionService,
        policy: ChatResourcePolicy = .forThisMac(),
        clock: any Clock<Duration> = ContinuousClock(),
        defaults: UserDefaults? = nil
    ) {
        self.init(
            store: store,
            broker: broker,
            modelURL: { modelManager.activeModelURL() },
            live: live,
            recordingMeetingID: { recording.recordingMeetingID },
            isTranscribing: { transcription.jobs[$0]?.isInProgress ?? false },
            policy: policy,
            clock: clock,
            defaults: defaults
        )
    }
}

public extension AppCore {
    /// Chat's "Keep the AI model ready" setting, for Settings.
    var keepsChatModelReady: Bool {
        chat.keepsModelReady
    }

    /// Turns "Keep the AI model ready" on or off (`MeetingChatService.setKeepsModelReady(_:)`).
    func setKeepsChatModelReady(_ isOn: Bool) async {
        await chat.setKeepsModelReady(isOn)
    }

    /// Whether this Mac closes the chat model after each answer during a
    /// recording, which "Keep the AI model ready" does not change.
    var closesChatModelDuringRecordings: Bool {
        chat.closesModelDuringRecordings
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
        transcription.onTranscriptSaved = { [weak self] meetingID, segmentTexts in
            self?.chat.transcriptWasSaved(meetingID: meetingID, hasText: MeetingChatService.hasTranscriptText(segmentTexts))
        }
    }

    /// "Keep the AI model ready" after launch: once the launch work that
    /// needs the GPU, the speech models' preparation, has ended, chat loads
    /// the AI model if the setting is on. From then on, chat hears of every
    /// change of the active model, so the model it keeps loaded is the one
    /// selected.
    func startChatModelReadiness() {
        if chat.keepsModelReady {
            Task { [weak self] in
                await self?.waitWhilePreparingSpeechModels()
                await self?.chat.launchWorkDidEnd()
            }
        }
        let modelManager = modelManager
        let chat = chat
        Task {
            var current = modelManager.activeModelURL()
            while !Task.isCancelled {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withObservationTracking {
                        _ = modelManager.activeModelURL()
                    } onChange: {
                        continuation.resume()
                    }
                }
                let next = modelManager.activeModelURL()
                guard next != current else { continue }
                current = next
                await chat.activeModelDidChange()
            }
        }
    }

    /// Chat's "Turn On" while the live transcript is off: the same as the
    /// Settings toggle. The setting is saved and live transcription starts,
    /// catching up from the start of the recording as any start mid-recording
    /// does. Chat answers from what it has transcribed so far.
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
