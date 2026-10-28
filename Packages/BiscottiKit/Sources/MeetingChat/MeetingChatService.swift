import DataStore
import Foundation
import Intelligence
import LiveTranscriptionService
import Observation
import os

/// The chat's source of truth while the app runs: for each meeting, whether
/// chat is available, its threads, the open thread and the answer being
/// written. Asks, stops, retries, and opens, starts and deletes threads,
/// saving through the store and answering through the broker. AppCore owns one.
///
/// One answer is written at a time across the app, because there is one model.
@MainActor @Observable
public final class MeetingChatService {
    /// The purpose of chat's leases on the broker.
    public static let leasePurpose = "chat"
    /// The longest question sent; the field stops at this length.
    public nonisolated static let maxQuestionLength = 2000

    /// Turns the live transcript on, as the Settings toggle does. AppCore sets
    /// it; without it, `turnOnLiveTranscript()` turns it on for this run only.
    @ObservationIgnored public var onTurnOnLiveTranscript: (@MainActor () async -> Void)?

    // MARK: - Observed by `MeetingChatState.availability`

    /// The meeting whose answer is being written or waits, if any.
    private(set) var answeringMeetingID: UUID?
    /// Whether each known meeting has a preferred transcript, from the store.
    private var transcriptFlags: [UUID: Bool] = [:]
    /// Meetings whose recording stopped and whose final pass has not ended.
    /// Until the pass is queued, no job says the transcript is on its way.
    private var pendingFinalPasses: Set<UUID> = []

    // MARK: - Dependencies

    let store: any ChatStoring
    let broker: LLMBroker
    let modelURL: @MainActor () -> URL?
    let live: LiveTranscriptionService
    let recordingMeetingID: @MainActor () -> UUID?
    let isTranscribing: @MainActor (UUID) -> Bool
    /// Variable only so the chat load driver can force its mode.
    @ObservationIgnored var policy: ChatResourcePolicy
    let answerFlushInterval: Duration
    /// Time since the service started, on the injected clock.
    let elapsed: @Sendable () -> Duration
    let logger = Logger(subsystem: "net.scosman.biscotti", category: "meeting-chat")

    // MARK: - Answer state

    @ObservationIgnored var states: [UUID: MeetingChatState] = [:]
    /// The answer being written, or waiting for the recording to stop.
    @ObservationIgnored var run: AnswerRun?
    @ObservationIgnored var answerTask: Task<Void, Never>?
    /// Bumped by every change of a meeting's open thread, so a slower load
    /// that started earlier does not overwrite it.
    @ObservationIgnored var threadLoadTokens: [UUID: Int] = [:]
    /// Answer view updates while answers streamed. Tests read it.
    @ObservationIgnored var answerFlushCount = 0

    #if DEBUG
        /// The chat load driver's listener (`report(_:)`). Debug builds only.
        @ObservationIgnored var loadObserver: (@MainActor (ChatLoadEvent) -> Void)?
    #endif

    /// - Parameters:
    ///   - modelURL: The active AI model's file, nil when none is downloaded.
    ///   - recordingMeetingID: The meeting being recorded, nil when none is.
    ///   - isTranscribing: Whether a meeting's final transcript is queued or running.
    ///   - answerFlushInterval: The shortest time between two updates of an
    ///     answer being written.
    ///   - clock: Times `answerFlushInterval`.
    public init(
        store: any ChatStoring,
        broker: LLMBroker,
        modelURL: @escaping @MainActor () -> URL?,
        live: LiveTranscriptionService,
        recordingMeetingID: @escaping @MainActor () -> UUID?,
        isTranscribing: @escaping @MainActor (UUID) -> Bool,
        policy: ChatResourcePolicy = .forThisMac(),
        answerFlushInterval: Duration = .milliseconds(50),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.store = store
        self.broker = broker
        self.modelURL = modelURL
        self.live = live
        self.recordingMeetingID = recordingMeetingID
        self.isTranscribing = isTranscribing
        self.policy = policy
        self.answerFlushInterval = answerFlushInterval
        elapsed = Self.stopwatch(on: clock)
    }

    /// The state object for a meeting, created on first use and kept while the app runs.
    public func state(for meetingID: UUID) -> MeetingChatState {
        if let state = states[meetingID] {
            return state
        }
        let state = MeetingChatState(meetingID: meetingID) { [weak self] meetingID in
            self?.availability(for: meetingID) ?? .noModel
        }
        states[meetingID] = state
        return state
    }

    /// A pass saved the meeting's preferred transcript. AppCore calls it from
    /// the pass itself, in the same main-actor turn that marks the job
    /// completed, so the field never reads "no transcript" in between. The
    /// rest of availability is worked out on each read from observable state
    /// (`MeetingChatState.availability`), so model, setting and recording
    /// changes need no call.
    public func transcriptWasSaved(meetingID: UUID) {
        noteTranscript(meetingID, exists: true)
    }

    /// AppCore calls this the moment a recording stops. Until
    /// `finalPassDidEnd(meetingID:)`, a meeting with no transcript and no
    /// draft reads as transcribing: its pass is not queued yet, so no job
    /// says so.
    public func finalPassWillStart(meetingID: UUID) {
        pendingFinalPasses.insert(meetingID)
    }

    /// AppCore calls this once the final pass after Stop has ended: saved,
    /// failed or never run.
    public func finalPassDidEnd(meetingID: UUID) {
        pendingFinalPasses.remove(meetingID)
    }

    // MARK: - Asking

    /// Sends the meeting's draft as a question, then clears the draft.
    public func ask(meetingID: UUID) async {
        let state = state(for: meetingID)
        let question = String(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxQuestionLength))
        guard !question.isEmpty, answeringMeetingID == nil, availability(for: meetingID) == .available else { return }
        state.draft = ""
        // Taken before the first wait, so a second Return cannot send twice.
        reserveAnswer(in: state)

        let threadID: UUID
        let questionID: UUID
        do {
            if let openThreadID = state.openThreadID {
                questionID = try await store.appendChatQuestion(threadID: openThreadID, text: question)
                threadID = openThreadID
            } else {
                (threadID, questionID) = try await store.createChatThread(meetingID: meetingID, firstQuestion: question)
            }
        } catch {
            logger.error("Couldn't save the question: \(error.localizedDescription, privacy: .private)")
            releaseAnswer(in: state)
            if state.draft.isEmpty { state.draft = question }
            return
        }

        if state.openThreadID == nil {
            state.openThreadID = threadID
            state.messages = []
        }
        // The thread shown may have changed during the write (History): the
        // turns then come from the store, and the views are not appended.
        let isShown = state.openThreadID == threadID
        let earlierTurns = isShown
            ? Self.earlierTurns(in: state.messages)
            : await storedTurns(threadID: threadID, before: questionID)
        let run = AnswerRun(
            meetingID: meetingID,
            threadID: threadID,
            questionID: questionID,
            question: question,
            earlierTurns: earlierTurns
        )
        if isShown {
            // A load that started before the question was written would show the thread without it.
            _ = nextThreadLoadToken(meetingID)
            state.messages.append(ChatMessageView(id: questionID, questionID: questionID, role: .question, text: question))
            state.messages.append(run.view)
        }
        state.isCardOpen = true
        let thread = state.messages.count > 2 ? "continued" : "new"
        let recording = recordingMeetingID() == nil ? "no recording" : "recording"
        logger.info("Ask in a \(thread, privacy: .public) thread, \(recording, privacy: .public)")
        start(run)
        await reloadThreads(meetingID: meetingID)
    }

    /// Answers a stored question again, with the turns before it, and saves
    /// over its old answer.
    public func retry(questionID: UUID, meetingID: UUID) async {
        let state = state(for: meetingID)
        guard answeringMeetingID == nil, availability(for: meetingID) == .available,
              let threadID = state.openThreadID,
              let questionIndex = state.messages.firstIndex(where: { $0.role == .question && $0.id == questionID })
        else { return }
        reserveAnswer(in: state)
        let run = AnswerRun(
            meetingID: meetingID,
            threadID: threadID,
            questionID: questionID,
            question: state.messages[questionIndex].text,
            earlierTurns: Self.earlierTurns(in: Array(state.messages[..<questionIndex]))
        )
        if let answerIndex = state.messages.firstIndex(where: { $0.role == .answer && $0.questionID == questionID }) {
            state.messages[answerIndex] = run.view
        } else {
            state.messages.insert(run.view, at: questionIndex + 1)
        }
        logger.info("Retry")
        start(run)
    }

    /// Stops the answer being written, anywhere. An answer that waits for the
    /// recording to stop goes back to an unanswered question.
    public func stop() {
        guard let run else { return }
        run.stopRequested = true
        if run.isParked {
            run.isParked = false
            run.view.state = .interrupted
            publish(run)
            end(run)
            logger.info("A waiting question was stopped")
        } else if let reader = run.reader {
            // Cancelled inside a pull, the stream still ends, so the broker keeps the model loaded.
            reader.cancel()
        } else {
            answerTask?.cancel()
        }
    }

    // MARK: - Recording

    /// AppCore calls this once a recording runs. On a Mac that closes the
    /// model after each answer during a recording, the model kept loaded by
    /// an earlier answer or summary is closed too, so its memory is free for
    /// the meeting.
    public func recordingDidStart() async {
        if let meetingID = recordingMeetingID() {
            report(.recordingStarted(meetingID: meetingID))
        }
        guard policy.closesAfterAnswer(isRecording: true) else { return }
        logger.info("Recording started: closing the AI model when it is idle")
        await broker.closeWhenIdle()
    }

    /// AppCore calls this when a recording stops, so a question waiting for
    /// the end starts.
    public func recordingDidStop(meetingID: UUID) async {
        report(.recordingStopped(meetingID: meetingID))
        guard let run, run.isParked else { return }
        run.isParked = false
        run.mayWaitForRecording = false
        run.view.state = .streaming(.thinking)
        publish(run)
        logger.info("Recording stopped: answering the waiting question")
        start(run)
    }

    /// The field's "Turn On" action while the live transcript is off. Live
    /// transcription starts from now, not from the start of the recording, so
    /// until the final transcript is saved, chat can answer only about what is
    /// said after it.
    public func turnOnLiveTranscript() async {
        if let onTurnOnLiveTranscript {
            await onTurnOnLiveTranscript()
        } else {
            await live.setEnabled(true)
        }
    }

    /// AppCore calls this when it deletes a meeting. The meeting's answer,
    /// running or waiting, stops without saving and frees the model for
    /// other meetings, and its chat state goes.
    public func meetingWasDeleted(_ meetingID: UUID) {
        if let run, run.meetingID == meetingID {
            run.discarded = true
            stop()
        }
        states[meetingID] = nil
        transcriptFlags[meetingID] = nil
        pendingFinalPasses.remove(meetingID)
        threadLoadTokens[meetingID] = nil
    }

    // MARK: - Availability

    /// In the component doc's order; the first match wins.
    func availability(for meetingID: UUID) -> ChatAvailability {
        if let answeringMeetingID, answeringMeetingID != meetingID {
            return .answeringElsewhere
        }
        if modelURL() == nil {
            return .noModel
        }
        if recordingMeetingID() == meetingID {
            return live.isEnabled ? .available : .liveTranscriptOff
        }
        if transcriptFlags[meetingID] == true || live.draft(for: meetingID) != nil {
            return .available
        }
        return isTranscribing(meetingID) || pendingFinalPasses.contains(meetingID) ? .transcribing : .noTranscript
    }

    func refreshTranscriptFlag(_ meetingID: UUID) async {
        let hasTranscript: Bool
        do {
            hasTranscript = try await store.meetingDetail(id: meetingID)?.preferredTranscript != nil
        } catch {
            logger.error("Couldn't read the meeting: \(error.localizedDescription, privacy: .private)")
            return
        }
        noteTranscript(meetingID, exists: hasTranscript)
    }

    /// Records whether a meeting has a preferred transcript. A transcript,
    /// once there, stays (re-transcribing replaces it), so a reading taken
    /// before a pass saved one never undoes `transcriptWasSaved`.
    func noteTranscript(_ meetingID: UUID, exists: Bool) {
        let flag = transcriptFlags[meetingID]
        guard flag != true, flag != exists else { return }
        transcriptFlags[meetingID] = exists
    }

    // MARK: - The answer slot

    private func reserveAnswer(in state: MeetingChatState) {
        answeringMeetingID = state.meetingID
        state.isAnswering = true
    }

    private func releaseAnswer(in state: MeetingChatState) {
        answeringMeetingID = nil
        state.isAnswering = false
    }

    func start(_ run: AnswerRun) {
        self.run = run
        answerTask = Task { [weak self] in
            await self?.runAnswer(run)
        }
    }

    /// Frees the slot for the next question.
    func end(_ run: AnswerRun) {
        guard self.run === run else { return }
        self.run = nil
        answerTask = nil
        answeringMeetingID = nil
        states[run.meetingID]?.isAnswering = false
        report(.ended(run))
    }

    /// Time since this call, on `clock`.
    static func stopwatch(on clock: some Clock<Duration>) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }
}
