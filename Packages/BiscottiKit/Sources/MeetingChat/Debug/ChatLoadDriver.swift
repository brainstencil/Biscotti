#if DEBUG
    import Foundation
    import os

    /// What an unattended plan needs from the app, which MeetingChat cannot
    /// reach: the end of its launch, the Settings model picker's path, and the
    /// Record and Stop buttons' paths. `AppCore.live` passes them. Debug
    /// builds only.
    public struct ChatLoadAppControls: Sendable {
        /// Returns once the app's launch has applied its settings, found the
        /// downloaded models and prepared the speech models.
        public var waitForLaunch: @MainActor () async -> Void
        /// Selects the catalog model with this id; true when it is then the
        /// active model.
        public var selectModel: @MainActor (String) async -> Bool
        public var startRecording: @MainActor () async -> Void
        public var stopRecording: @MainActor () async -> Void

        public init(
            waitForLaunch: @escaping @MainActor () async -> Void,
            selectModel: @escaping @MainActor (String) async -> Bool,
            startRecording: @escaping @MainActor () async -> Void,
            stopRecording: @escaping @MainActor () async -> Void
        ) {
            self.waitForLaunch = waitForLaunch
            self.selectModel = selectModel
            self.startRecording = startRecording
            self.stopRecording = stopRecording
        }
    }

    /// Asks a plan's questions through the chat service while a recorded
    /// meeting plays, for the chat measurement (`Tools/chat_bench`). Started by
    /// the launch argument `-chatLoadTest <plan.json>`. Debug builds only.
    ///
    /// Once the app has launched, it selects the plan's model and, for a plan
    /// with a recording, starts the recording itself and stops it after the
    /// plan's duration. Once the plan's start event comes (a recording's start
    /// or its stop), it asks each question at its due time, one at a time: a
    /// question whose time comes while an answer runs waits for it. It writes
    /// one `chat-load` line per event, which `Tools/chat_bench/analyze.py`
    /// and `run.sh` read:
    /// - `plan name= mode= closeModelAfterAnswer= startAfter= delay= interval=
    ///   questions= model= record= live=` (`closeModelAfterAnswer=-` keeps
    ///   this Mac's policy; `model=` is the active model's file; `record=` is
    ///   the recording's start delay and duration, `-` without one; `live=` is
    ///   whether a recording would get a live transcript)
    /// - `worker name= path=`: each worker's executable, or `missing`
    /// - `recording-started`, `recording-stopped`
    /// - `ask q= t=` (seconds after the start), `skip q= reason=`, `not-sent q=`
    /// - `lease q= loading=`, `first-token q=`
    /// - `done q= outcome= promptTokens= context= partial= tokens= generated=
    ///   generationSeconds= cited= linked=`, then `error=` and the failure's
    ///   text for a failed answer
    /// - `abort reason=`: the plan cannot run (`modelNotSelected`,
    ///   `liveTranscriptOff`, `liveModelMissing`, `recordingDidNotStart`,
    ///   `noAppControls`); no `plan-done` follows
    /// - `plan-done`: the questions were asked and the driver's recording,
    ///   if any, has stopped
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
        private let app: ChatLoadAppControls?
        private let clock: any Clock<Duration>
        private let elapsed: @Sendable () -> Duration
        private var tasks: [Task<Void, Never>] = []
        /// The plan's task, which ends with `plan-done` or `abort`. Tests await it.
        private(set) var planTask: Task<Void, Never>?

        /// The meeting the plan asks about, and when its start event came.
        private var start: (meetingID: UUID, at: Duration)?
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var answerWaiter: CheckedContinuation<Void, Never>?
        /// When the first recording started, from its event.
        private var recordingStartedAt: Duration?
        private var aborted = false
        /// Answers that ended while the driver ran.
        private var endedCount = 0
        /// The question being answered, numbered from 1.
        private var current: Int?
        private var leaseLogged = false

        /// When each question was asked, after the plan's start. Tests read it.
        private(set) var askTimes: [Duration] = []
        /// Each ended answer's figures, in order. Tests read it.
        private(set) var results: [ChatLoadResult] = []
        /// Every line written, except the memory lines. Tests read it.
        private(set) var lines: [String] = []

        init(plan: ChatLoadPlan, chat: MeetingChatService, clock: any Clock<Duration> = ContinuousClock(), app: ChatLoadAppControls? = nil) {
            self.plan = plan
            self.chat = chat
            self.app = app
            self.clock = clock
            elapsed = MeetingChatService.stopwatch(on: clock)
        }

        /// Starts the plan named by `-chatLoadTest` in `arguments`, if any. The
        /// path must be absolute: an app started with `open` runs in `/`.
        @discardableResult
        public static func startIfRequested(
            chat: MeetingChatService,
            app: ChatLoadAppControls? = nil,
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
            let driver = ChatLoadDriver(plan: plan, chat: chat, app: app)
            driver.start(sampler: .forApp())
            running = driver
            return driver
        }

        /// Forces the plan's mode, listens to the service, and starts the plan
        /// and, with a sampler, the memory log.
        func start(sampler: FootprintSampler?) {
            chat.policy = chat.policy.override(mode: plan.mode.policyMode, closesAfterAnswer: plan.closeModelAfterAnswer)
            chat.loadObserver = { [weak self] event in self?.handle(event) }
            let planTask = Task { await self.run() }
            self.planTask = planTask
            tasks.append(planTask)
            if let sampler {
                log("worker name=transcriber path=\(sampler.transcriberExecutable ?? "missing")")
                log("worker name=llm path=\(sampler.llmExecutable ?? "missing")")
                tasks.append(Self.logMemory(with: sampler, clock: clock))
            }
        }

        /// Ends the plan and the memory log.
        func stop() {
            tasks.forEach { $0.cancel() }
            tasks = []
            startWaiter?.resume()
            startWaiter = nil
            answerWaiter?.resume()
            answerWaiter = nil
        }

        // MARK: - Plan

        /// After the launch: the model, the plan line, then the recording and
        /// the questions side by side.
        private func run() async {
            await app?.waitForLaunch()
            guard !Task.isCancelled else { return }
            let modelSelected = await selectModel()
            log(planLine)
            guard modelSelected else { return abortPlan("modelNotSelected") }
            if let record = plan.record {
                guard let app else { return abortPlan("noAppControls") }
                guard chat.live.isEnabled else { return abortPlan("liveTranscriptOff") }
                guard chat.live.canStartLive else { return abortPlan("liveModelMissing") }
                async let recorded = makeRecording(record, with: app)
                await askQuestions()
                guard await recorded else { return }
            } else {
                await askQuestions()
            }
            guard !Task.isCancelled, !aborted else { return }
            log("plan-done")
        }

        private var planLine: String {
            let model = chat.modelURL()?.lastPathComponent ?? "-"
            let record = plan.record.map { "\($0.startAfterSeconds)+\($0.durationSeconds)" } ?? "-"
            let live = chat.live.canStartLive ? "on" : "off"
            return "plan name=\(plan.name) mode=\(plan.mode.rawValue) closeModelAfterAnswer=\(plan.closeModelAfterAnswer.map(String.init) ?? "-") startAfter=\(plan.startAfter.rawValue) delay=\(plan.startDelaySeconds) interval=\(plan.intervalSeconds) questions=\(plan.questions.count) model=\(model) record=\(record) live=\(live)"
        }

        /// Selects the plan's model as Settings does; false when it could not.
        private func selectModel() async -> Bool {
            guard let model = plan.model else { return true }
            guard let app else { return false }
            return await app.selectModel(model)
        }

        /// Starts the plan's recording after its delay, and stops it after its
        /// duration. False when it did not start or the plan stopped.
        private func makeRecording(_ record: ChatLoadPlan.Recording, with app: ChatLoadAppControls) async -> Bool {
            guard await sleep(untilElapsed: elapsed() + .seconds(record.startAfterSeconds)) else { return false }
            await app.startRecording()
            guard let startedAt = recordingStartedAt else {
                abortPlan("recordingDidNotStart")
                return false
            }
            guard await sleep(untilElapsed: startedAt + .seconds(record.durationSeconds)) else { return false }
            await app.stopRecording()
            return true
        }

        /// Ends the plan without `plan-done`.
        private func abortPlan(_ reason: String) {
            log("abort reason=\(reason)")
            aborted = true
            startWaiter?.resume()
            startWaiter = nil
        }

        private func askQuestions() async {
            if start == nil, !aborted {
                await withCheckedContinuation { startWaiter = $0 }
            }
            guard let start, !Task.isCancelled, !aborted else { return }
            for (index, question) in plan.questions.enumerated() {
                guard await sleep(untilElapsed: start.at + plan.dueTime(ofQuestion: index)) else { return }
                await ask(question, number: index + 1, in: start.meetingID)
                guard !Task.isCancelled else { return }
            }
        }

        /// Sleeps until the stopwatch reads `deadline`; false when cancelled.
        private func sleep(untilElapsed deadline: Duration) async -> Bool {
            let wait = deadline - elapsed()
            guard wait > .zero else { return !Task.isCancelled }
            do {
                try await clock.sleep(for: wait)
                return true
            } catch {
                return false
            }
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
                if recordingStartedAt == nil { recordingStartedAt = elapsed() }
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
            lines.append(line)
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
