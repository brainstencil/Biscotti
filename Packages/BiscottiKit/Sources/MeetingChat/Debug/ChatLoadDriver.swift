#if DEBUG
    import Foundation
    import os

    /// Asks a plan's questions through the chat service while a recorded
    /// meeting plays, for the chat measurement (`Tools/chat_bench`). Started by
    /// the launch argument `-chatLoadTest <plan.json>`. Debug builds only.
    ///
    /// Once the plan's start event comes (a recording's start or its stop), it
    /// asks each question at its due time, one at a time: a question whose
    /// time comes while an answer runs waits for it. It writes one `chat-load`
    /// line per event, which `Tools/chat_bench/analyze.py` reads:
    /// - `plan name= mode= closeModelAfterAnswer= startAfter= delay= interval= questions=`
    ///   (`closeModelAfterAnswer=-` keeps this Mac's policy)
    /// - `worker name= path=`: each worker's executable, or `missing`
    /// - `recording-started`, `recording-stopped`
    /// - `ask q= t=` (seconds after the start), `skip q= reason=`, `not-sent q=`
    /// - `lease q= loading=`, `first-token q=`
    /// - `done q= outcome= promptTokens= context= partial= tokens= generated=
    ///   generationSeconds= cited= linked=`, then `error=` and the failure's
    ///   text for a failed answer
    /// - `plan-done`
    /// - `memory app= transcriber= llm= appResident= transcriberResident=
    ///   llmResident=`: physical footprints and resident sizes in MiB, every
    ///   second, `-` for a worker that is not running.
    @MainActor
    public final class ChatLoadDriver {
        nonisolated static let logger = Logger(subsystem: "net.scosman.biscotti", category: "chat-load")
        /// The driver of this app run, kept until the app quits.
        private static var running: ChatLoadDriver?

        let plan: ChatLoadPlan
        private let chat: MeetingChatService
        private let clock: any Clock<Duration>
        private let elapsed: @Sendable () -> Duration
        private var tasks: [Task<Void, Never>] = []

        /// The meeting the plan asks about, and when its start event came.
        private var start: (meetingID: UUID, at: Duration)?
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var answerWaiter: CheckedContinuation<Void, Never>?
        /// Answers that ended while the driver ran.
        private var endedCount = 0
        /// The question being answered, numbered from 1.
        private var current: Int?
        private var leaseLogged = false

        /// When each question was asked, after the plan's start. Tests read it.
        private(set) var askTimes: [Duration] = []
        /// Each ended answer's figures, in order. Tests read it.
        private(set) var results: [ChatLoadResult] = []

        init(plan: ChatLoadPlan, chat: MeetingChatService, clock: any Clock<Duration> = ContinuousClock()) {
            self.plan = plan
            self.chat = chat
            self.clock = clock
            elapsed = MeetingChatService.stopwatch(on: clock)
        }

        /// Starts the plan named by `-chatLoadTest` in `arguments`, if any. The
        /// path must be absolute: an app started with `open` runs in `/`.
        @discardableResult
        public static func startIfRequested(
            chat: MeetingChatService,
            arguments: [String] = ProcessInfo.processInfo.arguments
        ) -> ChatLoadDriver? {
            guard let path = ChatLoadPlan.path(in: arguments) else { return nil }
            let plan: ChatLoadPlan
            do {
                plan = try ChatLoadPlan.load(from: URL(fileURLWithPath: path))
            } catch {
                logger.error("Couldn't read the plan at \(path, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
            let driver = ChatLoadDriver(plan: plan, chat: chat)
            driver.start(sampler: .forApp())
            running = driver
            return driver
        }

        /// Forces the plan's mode, listens to the service, and starts the
        /// schedule and, with a sampler, the memory log.
        func start(sampler: FootprintSampler?) {
            chat.policy = chat.policy.override(mode: plan.mode.policyMode, closesAfterAnswer: plan.closeModelAfterAnswer)
            chat.loadObserver = { [weak self] event in self?.handle(event) }
            log("plan name=\(plan.name) mode=\(plan.mode.rawValue) closeModelAfterAnswer=\(plan.closeModelAfterAnswer.map(String.init) ?? "-") startAfter=\(plan.startAfter.rawValue) delay=\(plan.startDelaySeconds) interval=\(plan.intervalSeconds) questions=\(plan.questions.count)")
            tasks.append(Task { await self.runPlan() })
            if let sampler {
                log("worker name=transcriber path=\(sampler.transcriberExecutable ?? "missing")")
                log("worker name=llm path=\(sampler.llmExecutable ?? "missing")")
                tasks.append(Self.logMemory(with: sampler, clock: clock))
            }
        }

        /// Ends the schedule and the memory log.
        func stop() {
            tasks.forEach { $0.cancel() }
            tasks = []
            startWaiter?.resume()
            startWaiter = nil
            answerWaiter?.resume()
            answerWaiter = nil
        }

        // MARK: - Schedule

        private func runPlan() async {
            if start == nil {
                await withCheckedContinuation { startWaiter = $0 }
            }
            guard let start, !Task.isCancelled else { return }
            for (index, question) in plan.questions.enumerated() {
                let wait = start.at + plan.dueTime(ofQuestion: index) - elapsed()
                if wait > .zero {
                    do {
                        try await clock.sleep(for: wait)
                    } catch {
                        return
                    }
                }
                await ask(question, number: index + 1, in: start.meetingID)
                guard !Task.isCancelled else { return }
            }
            log("plan-done")
        }

        private func ask(_ question: String, number: Int, in meetingID: UUID) async {
            // An answer the driver did not ask for, such as one typed in the app, ends first.
            while chat.answeringMeetingID != nil, !Task.isCancelled {
                await nextAnswerEnd()
            }
            guard !Task.isCancelled else { return }
            let state = chat.state(for: meetingID)
            let availability = state.availability
            guard availability == .available else {
                log("skip q=\(number) reason=\(availability)")
                return
            }
            current = number
            leaseLogged = false
            let askedAt = elapsed() - (start?.at ?? .zero)
            askTimes.append(askedAt)
            log("ask q=\(number) t=\(Self.seconds(askedAt))")
            let endedBefore = endedCount
            state.draft = question
            await chat.ask(meetingID: meetingID)
            guard endedCount == endedBefore else { return }
            if chat.answeringMeetingID == nil {
                // The question could not be saved, so no answer started.
                log("not-sent q=\(number)")
                current = nil
            } else {
                await nextAnswerEnd()
            }
        }

        private func nextAnswerEnd() async {
            await withCheckedContinuation { answerWaiter = $0 }
        }

        // MARK: - Events

        private func handle(_ event: ChatLoadEvent) {
            switch event {
            case let .recordingStarted(meetingID):
                log("recording-started")
                if plan.startAfter == .recordingStart { begin(meetingID) }
            case let .recordingStopped(meetingID):
                log("recording-stopped")
                if plan.startAfter == .recordingStop { begin(meetingID) }
            case let .leaseStarted(_, loadingModel):
                guard !leaseLogged else { return }
                leaseLogged = true
                log("lease q=\(questionLabel) loading=\(loadingModel)")
            case .firstToken:
                log("first-token q=\(questionLabel)")
            case let .ended(run):
                let result = ChatLoadResult(question: current, run: run)
                results.append(result)
                log(result.logLine)
                current = nil
                leaseLogged = false
                endedCount += 1
                answerWaiter?.resume()
                answerWaiter = nil
            }
        }

        /// The plan's start: only the first start event counts.
        private func begin(_ meetingID: UUID) {
            guard start == nil else { return }
            start = (meetingID, elapsed())
            startWaiter?.resume()
            startWaiter = nil
        }

        private var questionLabel: String {
            current.map(String.init) ?? "-"
        }

        private func log(_ line: String) {
            Self.logger.notice("\(line, privacy: .public)")
        }

        // MARK: - Memory

        /// Logs the footprints every second, off the main actor.
        private static func logMemory(with sampler: FootprintSampler, clock: any Clock<Duration>) -> Task<Void, Never> {
            Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    let memory = sampler.sample()
                    let footprints = "app=\(Self.mebibytes(memory.app?.footprint)) transcriber=\(Self.mebibytes(memory.transcriber?.footprint)) llm=\(Self.mebibytes(memory.llm?.footprint))"
                    let resident = "appResident=\(Self.mebibytes(memory.app?.resident)) transcriberResident=\(Self.mebibytes(memory.transcriber?.resident)) llmResident=\(Self.mebibytes(memory.llm?.resident))"
                    Self.logger.notice("memory \(footprints, privacy: .public) \(resident, privacy: .public)")
                    do {
                        try await clock.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                }
            }
        }

        private nonisolated static func mebibytes(_ bytes: UInt64?) -> String {
            bytes.map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "-"
        }

        static func seconds(_ duration: Duration) -> String {
            let (seconds, attoseconds) = duration.components
            return String(format: "%.1f", Double(seconds) + Double(attoseconds) / 1e18)
        }
    }

    /// One ended answer's figures, as the driver logs them.
    struct ChatLoadResult: Equatable {
        /// Numbered from 1; nil for an answer the driver did not ask for.
        var question: Int?
        /// complete, stopped, failed, interrupted (a waiting question was
        /// stopped) or discarded (its thread or meeting was deleted). An
        /// answer view still streaming when its run ended would be
        /// "unfinished"; the service never leaves one.
        var outcome: String
        var promptTokens: Int?
        var contextSize: Int?
        var isPartial: Bool?
        /// Tokens received, after the model's channel splitter.
        var tokens: Int
        /// The model's own count and decode time, when the stream said it finished.
        var generatedTokens: Int?
        var generationSeconds: Double?
        /// Times cited in brackets, and those that became links.
        var citedTimes: Int
        var linkedTimes: Int
        /// A failed answer's text for the user (`ChatErrorText`).
        var error: String?

        @MainActor
        init(question: Int?, run: AnswerRun) {
            self.question = question
            // A discarded run keeps the view it had while streaming, so its flag comes first.
            switch run.view.state {
            case _ where run.discarded: outcome = "discarded"
            case .complete: outcome = "complete"
            case .stopped: outcome = "stopped"
            case .interrupted: outcome = "interrupted"
            case let .failed(message):
                outcome = "failed"
                error = message
            case .streaming: outcome = "unfinished"
            }
            promptTokens = run.prompt?.promptTokens
            contextSize = run.prompt?.contextSize
            isPartial = run.prompt?.isPartial
            tokens = run.tokenCount
            generatedTokens = run.generation?.generatedTokenCount
            generationSeconds = run.generation?.generationDuration
            (citedTimes, linkedTimes) = Self.citations(in: run.text, evidenceTimes: run.prompt?.evidenceTimes ?? [])
        }

        var logLine: String {
            func value(_ value: (some CustomStringConvertible)?) -> String {
                value.map(\.description) ?? "-"
            }
            let generation = "generated=\(value(generatedTokens)) generationSeconds=\(value(generationSeconds.map { String(format: "%.3f", $0) }))"
            let line = "done q=\(value(question)) outcome=\(outcome) promptTokens=\(value(promptTokens)) context=\(value(contextSize)) partial=\(value(isPartial)) tokens=\(tokens) \(generation) cited=\(citedTimes) linked=\(linkedTimes)"
            return error.map { "\(line) error=\($0)" } ?? line
        }

        /// The times an answer cites in brackets (each time or range in a
        /// group counts), and how many of them the parser links to evidence.
        static func citations(in answer: String, evidenceTimes: [TimeInterval]) -> (cited: Int, linked: Int) {
            let time = #/\d{1,2}:\d{2}(?::\d{2})?(?:\s*[–—-]\s*\d{1,2}:\d{2}(?::\d{2})?)?/#
            let cited = answer.matches(of: #/\[[^\]\n]*\]/#).reduce(0) { count, bracket in
                count + answer[bracket.range].matches(of: time).count
            }
            let linked = ChatAnswerParser.blocks(answer, evidenceTimes: evidenceTimes).reduce(0) { count, block in
                count + block.text.runs.count { $0[ChatTimeAttribute.self] != nil }
            }
            return (cited, linked)
        }
    }
#endif
