import Foundation
import Intelligence

/// Loading the AI model before a question needs it, keeping it loaded for
/// "Keep the AI model ready", and timing each load for the loading bar.
public extension MeetingChatService {
    /// The purpose of the lease that loads the model before a question.
    static let loadAheadPurpose = "chat-load-ahead"

    // MARK: - Keep the AI model ready

    /// The "Keep the AI model ready" setting, kept in UserDefaults. On, the
    /// model loads now and stays loaded instead of closing after the idle
    /// keep-alive; during a recording the memory rule still wins
    /// (`ChatResourcePolicy.keepsModelLoaded`). Off, the normal idle close
    /// starts from now.
    func setKeepsModelReady(_ isOn: Bool) async {
        guard isOn != keepsModelReady else { return }
        keepsModelReady = isOn
        modelRecords.keepModelReady(isOn)
        logger.info("Keep the AI model ready: \(isOn, privacy: .public)")
        await applyModelHold()
        if isOn {
            loadModelAhead(reason: "setting")
        }
    }

    /// AppCore calls this once the launch work that needs the GPU, the speech
    /// models' preparation, has ended. With "Keep the AI model ready" on, the
    /// model loads now.
    func launchWorkDidEnd() async {
        await applyModelHold()
        if keepsModelReady {
            loadModelAhead(reason: "launch")
        }
    }

    /// AppCore calls this when the active model changes. With "Keep the AI
    /// model ready" on, the new model replaces the loaded one now, and a
    /// deleted model's memory is freed.
    func activeModelDidChange() async {
        guard keepsModelReady else { return }
        if modelURL() == nil {
            await broker.closeWhenIdle()
        } else {
            loadModelAhead(reason: "model change")
        }
    }

    /// Whether this Mac closes the model after each answer during a
    /// recording, which "Keep the AI model ready" does not change.
    var closesModelDuringRecordings: Bool {
        policy.closesAfterAnswer(isRecording: true)
    }

    /// Sets the broker's hold on the model (`setKeepsModelLoaded`) from the setting and the recording in progress.
    internal func applyModelHold() async {
        let isRecording = recordingMeetingID() != nil
        await broker.setKeepsModelLoaded(policy.keepsModelLoaded(keepModelReady: keepsModelReady, isRecording: isRecording))
    }

    // MARK: - Loading ahead

    /// The question field took the cursor. With chat available for the
    /// meeting and the model not loaded, the model starts loading now, so it
    /// is ready, or nearer to ready, when the question is sent. With no
    /// question, the model closes after the idle keep-alive, as after an answer.
    func questionFieldDidTakeFocus(meetingID: UUID) {
        guard availability(for: meetingID) == .available else { return }
        loadModelAhead(reason: "focus")
    }

    /// Starts loading the model through the broker, unless a load ahead is
    /// running, an answer is being written or waits, the policy says no
    /// (`loadsAhead`), or there is no model. The broker skips it while any
    /// lease runs or waits, or when the model is loaded.
    internal func loadModelAhead(reason: String) {
        let isRecording = recordingMeetingID() != nil
        guard loadAheadTask == nil, run == nil, policy.loadsAhead(isRecording: isRecording),
              let model = modelURL()
        else { return }
        let keepAlive = policy.keepAlive(isRecording: isRecording)
        loadAheadTask = Task { [weak self] in
            await self?.loadAhead(model, keepAlive: keepAlive, reason: reason)
            self?.loadAheadTask = nil
        }
    }

    private func loadAhead(_ model: URL, keepAlive: LLMKeepAlive, reason: String) async {
        let timer = ChatLoadTimer()
        do {
            let loaded = try await broker.loadAhead(
                model: model,
                priority: .interactive,
                purpose: Self.loadAheadPurpose,
                keepAlive: keepAlive,
                onWait: waitReporter(timer, model: model) { _ in }
            )
            modelLoadDidEnd(timer, model: model, loaded: loaded, reason: reason)
        } catch {
            modelLoadDidEnd(timer, model: model, loaded: false, reason: reason)
            logger.error("Couldn't load the AI model ahead (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Timing loads

    /// The `onWait` for a chat lease: notes the moment the broker starts
    /// loading the model, on the service's clock, then hands every wait to
    /// `handle` on the main actor.
    internal func waitReporter(
        _ timer: ChatLoadTimer,
        model: URL,
        handle: @escaping @MainActor @Sendable (LLMWait) -> Void
    ) -> @Sendable (LLMWait) -> Void {
        let elapsed = elapsed
        return { [weak self] wait in
            if wait == .loadingModel {
                timer.start(at: elapsed())
            }
            Task { @MainActor in
                if wait == .loadingModel {
                    self?.modelLoadDidStart(timer, model: model)
                }
                handle(wait)
            }
        }
    }

    /// Shows the load, unless it has already ended, and an answer waiting for
    /// it says "Loading the AI model…".
    private func modelLoadDidStart(_ timer: ChatLoadTimer, model: URL) {
        guard !timer.hasEnded else { return }
        modelLoad = ChatModelLoad(id: timer.id, startedAt: Date(), estimate: modelRecords.lastLoadDuration(of: model))
        if let run, !run.leaseStarted, !run.isParked {
            run.view.state = .streaming(.loadingModel)
            publish(run)
        }
    }

    /// Ends the timer. A load that finished stores its duration for the next
    /// estimate and logs it beside the last one.
    internal func modelLoadDidEnd(_ timer: ChatLoadTimer, model: URL, loaded: Bool, reason: String) {
        guard let started = timer.end() else { return }
        if modelLoad?.id == timer.id {
            modelLoad = nil
        }
        guard loaded else { return }
        let duration = elapsed() - started
        let last = modelRecords.lastLoadDuration(of: model).map { "\(Self.seconds($0)) s" } ?? "none"
        modelRecords.recordLoad(duration, of: model)
        logger.info("Model load took \(Self.seconds(duration), privacy: .public) s (\(reason, privacy: .public)); last time \(last, privacy: .public)")
    }

    private static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f", duration / .seconds(1))
    }
}
