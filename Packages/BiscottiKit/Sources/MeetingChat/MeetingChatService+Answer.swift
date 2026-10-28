import DataStore
import Foundation
import Intelligence
import LocalLLM

/// The answer being written: its question, what the model was given, and the
/// view the chat card shows for it.
@MainActor
final class AnswerRun {
    let meetingID: UUID
    let threadID: UUID
    let questionID: UUID
    let question: String
    let earlierTurns: [ChatTurn]
    let started = ContinuousClock.now
    /// The answer as the card shows it.
    var view: ChatMessageView
    /// Every token received so far.
    var text = ""
    /// Set once the prompt is built. Before that, the answer has no basis.
    var prompt: ChatPrompt?
    /// Pulls the model's stream while it is read.
    var reader: Task<Void, Never>?
    /// False once a recording's stop resumed it: it answers at once.
    var mayWaitForRecording = true
    /// Waiting for the recording to stop.
    var isParked = false
    /// The broker handed over the session, so its wait reports are stale.
    var leaseStarted = false
    var stopRequested = false
    /// Its thread was deleted: nothing is saved.
    var discarded = false
    var lastFlush: Duration?

    init(meetingID: UUID, threadID: UUID, questionID: UUID, question: String, earlierTurns: [ChatTurn]) {
        self.meetingID = meetingID
        self.threadID = threadID
        self.questionID = questionID
        self.question = question
        self.earlierTurns = earlierTurns
        view = ChatMessageView(id: UUID(), questionID: questionID, role: .answer, text: "", state: .streaming(.thinking))
    }
}

/// How the model's part of an answer ended.
enum AnswerOutcome {
    /// The stream ended; `sawDone` tells whether it said it was finished.
    case finished(sawDone: Bool)
    case failed(any Error)
}

/// The meeting has no transcript text to answer from.
struct NoChatTranscript: Error {}

extension MeetingChatService {
    func runAnswer(_ run: AnswerRun) async {
        // Any recording, not only this meeting's: the policy is about memory.
        let isRecording = recordingMeetingID() != nil
        if isRecording, run.mayWaitForRecording, policy.mode() == .waitForStop {
            park(run)
            return
        }
        let outcome = await answerOutcome(run, isRecording: isRecording)
        await finish(run, outcome)
    }

    private func park(_ run: AnswerRun) {
        run.isParked = true
        run.view.state = .streaming(.waitingForRecordingToEnd)
        answerTask = nil
        publish(run)
        logger.info("Policy waitForStop: the question waits for the recording to stop")
    }

    private func answerOutcome(_ run: AnswerRun, isRecording: Bool) async -> AnswerOutcome {
        do {
            if run.stopRequested { throw CancellationError() }
            let record = try await meetingRecord(for: run.meetingID)
            guard let model = modelURL() else { throw LLMBrokerError.modelUnavailable }
            let onWait: @Sendable (LLMWait) -> Void = { [weak self] wait in
                Task { @MainActor in self?.apply(wait, to: run) }
            }
            let sawDone = try await broker.withLease(
                model: model,
                priority: .interactive,
                purpose: Self.leasePurpose,
                keepAlive: policy.keepAlive(isRecording: isRecording),
                onWait: onWait
            ) { [weak self] session in
                guard let self else { throw CancellationError() }
                return try await answer(run, record: record, in: session)
            }
            return .finished(sawDone: sawDone)
        } catch {
            return .failed(error)
        }
    }

    /// The meeting's record, with the transcript to answer from: the live
    /// transcript while this meeting records, otherwise the preferred
    /// transcript, otherwise the draft.
    private func meetingRecord(for meetingID: UUID) async throws -> ChatMeetingRecord {
        let isRecordingThis = recordingMeetingID() == meetingID
        // Taken now, when the question is sent.
        let snapshot = isRecordingThis ? live.snapshot(includeTail: true) : nil
        let detail = try await store.meetingDetail(id: meetingID)
        let transcript: ChatTranscript? = if isRecordingThis {
            snapshot.map { .live($0) }
        } else if let saved = detail?.preferredTranscript {
            .saved(saved)
        } else {
            live.draft(for: meetingID).map { .draft($0) }
        }
        // A transcript with no lines yet, such as a live session that has heard
        // nothing, fails like a missing one rather than asking the model about nothing.
        guard let transcript, !ChatEvidence.lines(for: transcript).isEmpty else { throw NoChatTranscript() }
        return ChatMeetingRecord(
            title: detail?.title ?? "",
            date: detail?.date,
            invitees: Self.invitees(detail?.calendar),
            notes: detail?.notes ?? "",
            transcript: transcript
        )
    }

    /// The calendar organizer, then the attendees, once each. The spec names the
    /// attendees; the organizer was invited too, and `attendees` leaves them out.
    static func invitees(_ calendar: CalendarContextData?) -> [String] {
        let people = [calendar?.organizer].compactMap(\.self) + (calendar?.attendees ?? [])
        var seen = Set<String>()
        return people.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Runs inside the lease: builds the prompt, sizes the context and reads
    /// the answer. Returns whether the stream said it was finished.
    private func answer(_ run: AnswerRun, record: ChatMeetingRecord, in session: any LLMSession) async throws -> Bool {
        // A Stop during the model load ends the answer before a prompt exists.
        try Task.checkCancellation()
        run.leaseStarted = true
        run.view.state = .streaming(.thinking)
        publish(run)

        let prompt = try await ChatPromptBuilder.build(
            record: record,
            earlierTurns: run.earlierTurns,
            question: run.question,
            count: { try await session.countTokens(messages: $0) }
        )
        run.prompt = prompt
        logger.info("Prompt: \(prompt.promptTokens) tokens, context \(prompt.contextSize), partial \(prompt.isPartial)")
        try Task.checkCancellation()
        try await session.reconfigure(contextSize: prompt.contextSize)
        try Task.checkCancellation()
        // Not pulled yet, so a cancellation before `read` leaves the connection free.
        let stream = await session.generateStreaming(messages: prompt.messages, options: prompt.options)
        try Task.checkCancellation()
        return try await read(stream, for: run)
    }

    /// Reads the stream to its end, as the broker requires.
    ///
    /// A detached reader does the pulls and nothing else, and forwards each
    /// event here. Stop cancels the reader, so the cancellation lands inside a
    /// pull: the connection then cancels the generation and ends the stream,
    /// and the broker keeps the model loaded. Only a Stop in the instant
    /// between two pulls leaves the stream unfinished, and the next question
    /// reloads the model.
    private func read(_ stream: AsyncThrowingStream<StreamEvent, Error>, for run: AnswerRun) async throws -> Bool {
        let (events, forward) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        let reader = Task.detached {
            do {
                for try await event in stream {
                    forward.yield(event)
                }
                forward.finish()
            } catch {
                forward.finish(throwing: error)
            }
        }
        forward.onTermination = { _ in reader.cancel() }
        run.reader = reader
        defer { run.reader = nil }

        var sawDone = false
        for try await event in events {
            switch event {
            case let .token(text):
                run.text += text
                flushIfDue(run)
            case .reasoningToken:
                continue
            case .done:
                sawDone = true
            }
        }
        return sawDone
    }

    /// Updates the answer view at the first token, then at most every `answerFlushInterval`.
    private func flushIfDue(_ run: AnswerRun) {
        let now = elapsed()
        if let last = run.lastFlush, now - last < answerFlushInterval { return }
        run.lastFlush = now
        run.view.text = run.text
        run.view.blocks = ChatAnswerParser.blocks(run.text, evidenceTimes: run.prompt?.evidenceTimes ?? [])
        run.view.state = .streaming(.streaming)
        answerFlushCount += 1
        publish(run)
    }

    /// Reports why the answer is not running yet, until the lease starts.
    func apply(_ wait: LLMWait, to run: AnswerRun) {
        guard self.run === run, !run.leaseStarted else { return }
        switch wait {
        case .loadingModel:
            run.view.state = .streaming(.loadingModel)
            logger.info("Lease wait: loading the model")
        case let .queued(behind) where behind == BrokeredLLMRunner.defaultPurpose:
            run.view.state = .streaming(.waitingForSummary)
            logger.info("Lease wait: behind the summary")
        case let .queued(behind):
            logger.info("Lease wait: behind \(behind, privacy: .public)")
            return
        }
        publish(run)
    }

    // MARK: - Outcome

    /// Saves the answer, shows its final view and frees the slot.
    private func finish(_ run: AnswerRun, _ outcome: AnswerOutcome) async {
        let (state, errorMessage) = Self.result(of: outcome, stopRequested: run.stopRequested)
        let basis = run.prompt?.basis
        let blocks = ChatAnswerParser.blocks(run.text, evidenceTimes: run.prompt?.evidenceTimes ?? [])
        let viewState: ChatMessageView.State = switch state {
        case .complete: .complete
        case .stopped: .stopped
        case .failed: .failed(errorMessage ?? ChatErrorText.unexpected)
        }
        var view = ChatMessageView(
            id: run.view.id, questionID: run.questionID, role: .answer, text: run.text,
            blocks: blocks, state: viewState, footer: Self.footer(for: basis)
        )
        logger.info("Answer \(state.rawValue, privacy: .public) after \(Int((ContinuousClock.now - run.started) / .milliseconds(1))) ms\(Self.errorType(of: outcome), privacy: .public)")
        // Its thread or meeting was deleted: nothing to save or show.
        guard !run.discarded else {
            end(run)
            return
        }
        // Cited times are saved for failed answers too, not only complete or
        // stopped ones, so a failed answer's partial text keeps its links when reopened.
        do {
            view.id = try await store.saveChatAnswer(
                questionID: run.questionID, text: run.text, state: state, errorMessage: errorMessage,
                basis: basis, citedTimes: ChatAnswerParser.citedTimes(in: blocks)
            )
        } catch {
            view.isUnsaved = true
            logger.error("Couldn't save the answer: \(error.localizedDescription, privacy: .private)")
        }
        run.view = view
        publish(run)
        end(run)
        await reloadThreads(meetingID: run.meetingID)
    }

    /// The stored state and error message for an outcome. A finished stream
    /// wins over Stop; Stop wins over every failure.
    static func result(of outcome: AnswerOutcome, stopRequested: Bool) -> (ChatMessageState, String?) {
        if case .finished(sawDone: true) = outcome {
            return (.complete, nil)
        }
        if stopRequested {
            return (.stopped, nil)
        }
        return switch outcome {
        case .finished: (.failed, ChatErrorText.stoppedEarly)
        case let .failed(error): (.failed, message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        switch error {
        case is CancellationError: ChatErrorText.stoppedEarly
        case let error as LLMServiceError where error == .cancelled: ChatErrorText.stoppedEarly
        case is LLMBrokerError: ChatErrorText.modelFailed
        case ChatPromptError.tooLong: ChatErrorText.tooLong
        case is NoChatTranscript: ChatErrorText.noTranscript
        default: ChatErrorText.unexpected
        }
    }

    private static func errorType(of outcome: AnswerOutcome) -> String {
        guard case let .failed(error) = outcome else { return "" }
        return " (\(String(describing: type(of: error))))"
    }
}
