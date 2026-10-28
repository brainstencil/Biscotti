import DataStore
import Foundation

extension MeetingChatService {
    /// Loads the meeting's threads and reopens its open thread, if any. Call
    /// when the meeting's page or recording screen appears.
    public func load(meetingID: UUID) async {
        let state = state(for: meetingID)
        await refreshTranscriptFlag(meetingID)
        await reloadThreads(meetingID: meetingID)
        if let threadID = state.openThreadID {
            await show(threadID, in: state, token: nextThreadLoadToken(meetingID))
        }
    }

    /// Shows a thread from the History menu.
    public func openThread(_ threadID: UUID, meetingID: UUID) async {
        let state = state(for: meetingID)
        await show(threadID, in: state, token: nextThreadLoadToken(meetingID))
    }

    /// Closes the open thread and the card; the next question starts a thread.
    public func newChat(meetingID: UUID) {
        let state = state(for: meetingID)
        _ = nextThreadLoadToken(meetingID)
        state.openThreadID = nil
        state.messages = []
        state.isCardOpen = false
    }

    /// Deletes a thread and its messages. An answer being written in it is
    /// stopped and not saved.
    public func deleteThread(_ threadID: UUID, meetingID: UUID) async {
        if let run, run.threadID == threadID {
            run.discarded = true
            stop()
        }
        do {
            try await store.deleteChatThread(id: threadID)
        } catch {
            logger.error("Couldn't delete the thread: \(error.localizedDescription, privacy: .private)")
        }
        if state(for: meetingID).openThreadID == threadID {
            newChat(meetingID: meetingID)
        }
        await reloadThreads(meetingID: meetingID)
    }

    // MARK: - Loading

    /// The turns before `questionID` in a stored thread.
    func storedTurns(threadID: UUID, before questionID: UUID) async -> [ChatTurn] {
        do {
            guard let thread = try await store.chatThread(id: threadID) else { return [] }
            let views = Self.views(for: thread)
            let questionIndex = views.firstIndex { $0.id == questionID } ?? views.endIndex
            return Self.earlierTurns(in: Array(views[..<questionIndex]))
        } catch {
            logger.error("Couldn't read the thread: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    func reloadThreads(meetingID: UUID) async {
        do {
            let threads = try await store.chatThreads(meetingID: meetingID)
            state(for: meetingID).threads = threads
        } catch {
            logger.error("Couldn't read the threads: \(error.localizedDescription, privacy: .private)")
        }
    }

    func nextThreadLoadToken(_ meetingID: UUID) -> Int {
        let token = (threadLoadTokens[meetingID] ?? 0) + 1
        threadLoadTokens[meetingID] = token
        return token
    }

    /// Reads the thread and makes it the open one, unless a later change of
    /// the open thread came first. A thread that is gone closes.
    private func show(_ threadID: UUID, in state: MeetingChatState, token: Int) async {
        let thread: ChatThreadData?
        do {
            thread = try await store.chatThread(id: threadID)
        } catch {
            logger.error("Couldn't read the thread: \(error.localizedDescription, privacy: .private)")
            return
        }
        guard threadLoadTokens[state.meetingID] == token else { return }
        guard let thread, thread.summary.meetingID == state.meetingID else {
            if state.openThreadID == threadID {
                state.openThreadID = nil
                state.messages = []
            }
            return
        }
        state.openThreadID = threadID
        state.messages = withRunningAnswer(Self.views(for: thread), threadID: threadID)
    }

    /// Shows the running answer in its question's answer slot: the store has
    /// its question but not yet the answer (or, for a retry, the old answer).
    private func withRunningAnswer(_ views: [ChatMessageView], threadID: UUID) -> [ChatMessageView] {
        guard let run, run.threadID == threadID,
              let index = views.firstIndex(where: { $0.role == .answer && $0.questionID == run.questionID })
        else { return views }
        var views = views
        views[index] = run.view
        return views
    }

    /// Shows the run's current view, if its thread is the open one.
    func publish(_ run: AnswerRun) {
        guard let state = states[run.meetingID],
              state.openThreadID == run.threadID,
              let index = state.messages.firstIndex(where: { $0.role == .answer && $0.questionID == run.questionID })
        else { return }
        state.messages[index] = run.view
    }

    // MARK: - Mapping

    /// The stored messages as views. A question with no answer right after it
    /// was interrupted (the app quit mid-answer) and gets an interrupted
    /// answer view, with Retry. A stored answer's citations link to the times
    /// they linked to when it was written.
    static func views(for thread: ChatThreadData) -> [ChatMessageView] {
        let answeredIndexes = Set(thread.messages.filter { $0.role == .answer }.map { $0.index - 1 })
        var views: [ChatMessageView] = []
        var questionID: UUID?
        for message in thread.messages {
            switch message.role {
            case .question:
                questionID = message.id
                views.append(ChatMessageView(id: message.id, questionID: message.id, role: .question, text: message.text))
                if !answeredIndexes.contains(message.index) {
                    views.append(ChatMessageView(id: UUID(), questionID: message.id, role: .answer, text: "", state: .interrupted))
                }
            case .answer:
                views.append(ChatMessageView(
                    id: message.id,
                    questionID: questionID ?? message.id,
                    role: .answer,
                    text: message.text,
                    blocks: ChatAnswerParser.blocks(message.text, evidenceTimes: message.citedTimes),
                    state: viewState(of: message),
                    footer: footer(for: message.basis)
                ))
            }
        }
        return views
    }

    private static func viewState(of answer: ChatMessageData) -> ChatMessageView.State {
        switch answer.state {
        case .complete: .complete
        case .stopped: .stopped
        case .failed: .failed(answer.errorMessage ?? ChatErrorText.unexpected)
        }
    }

    /// The line under an answer: how far the live transcript reached, or that
    /// the draft was used. Nothing for a saved transcript or no basis.
    static func footer(for basis: ChatBasis?) -> String? {
        switch basis {
        case let .live(through): "Based on the transcript through \(ChatEvidence.format(through))"
        case .draft: "Based on the draft transcript"
        case .transcript, nil: nil
        }
    }

    /// The thread's question and answer pairs, for the next question's prompt:
    /// complete or stopped answers only. Failed, interrupted and running
    /// answers, and their questions, are left out.
    static func earlierTurns(in messages: [ChatMessageView]) -> [ChatTurn] {
        var questions: [UUID: String] = [:]
        var turns: [ChatTurn] = []
        for message in messages {
            switch message.role {
            case .question:
                questions[message.id] = message.text
            case .answer:
                guard message.state == .complete || message.state == .stopped,
                      let question = questions[message.questionID]
                else { continue }
                turns.append(ChatTurn(question: question, answer: message.text))
            }
        }
        return turns
    }
}
