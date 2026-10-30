import AudioCapture
import Calendar
import DataStore
import Foundation
import Intelligence
import LiveTranscriptionService
import MeetingCatalog
import MeetingChat
import MeetingDetection
import Notifications
import os
import Permissions
import Recording
import Transcription
import TranscriptionService
import Vocabulary

// MARK: - Production factory

public extension AppCore {
    /// Builds a fully-wired `AppCore` for the real app.
    ///
    /// - Parameters:
    ///   - storageRoot: The app's persistent data directory
    ///     (e.g. `…/Library/Application Support/Biscotti/`). Recordings are
    ///     stored under `Recordings/` within this directory; the DataStore
    ///     file is placed at `<storageRoot>/Biscotti.store`.
    ///   - transcriberServiceName: The Mach service name for the XPC
    ///     transcription worker (e.g. `"net.scosman.biscotti.BiscottiTranscriber"`).
    /// - Returns: A ready-to-use `AppCore`. Call `onLaunch()` after presenting the UI.
    static func live(
        storageRoot: URL,
        transcriberServiceName: String
    ) throws -> AppCore {
        let logger = Logger(
            subsystem: "net.scosman.biscotti",
            category: "startup"
        )

        logger.info("AppCore.live: DataStore init starting")
        let store = try DataStore(storage: .onDisk(storageRoot))
        logger.info("AppCore.live: DataStore init done")

        let permissions = Permissions()
        let recordingsRoot = storageRoot.appendingPathComponent("Recordings")

        logger.info("AppCore.live: RecordingController init")
        let recording = RecordingController(
            store: store,
            permissions: permissions,
            storageRoot: recordingsRoot,
            makeRecorder: {
                LiveRecorderAdapter(recorder: AudioRecorder.live())
            }
        )

        let transcription = buildTranscription(
            store: store, serviceName: transcriberServiceName, logger: logger
        )

        logger.info("AppCore.live: CalendarService init")
        let catalog = BundledMeetingCatalog()
        let calendar = CalendarService(store: store, catalog: catalog)

        logger.info("AppCore.live: MeetingDetector init")
        let detector = MeetingDetector(catalog: catalog)

        logger.info("AppCore.live: NotificationService init")
        let notifications = NotificationService()
        let notifAuth = LiveNotificationAuthorizerAdapter(service: notifications)
        permissions.setNotificationAuthorizer(notifAuth)

        logger.info("AppCore.live: ModelManager + Intelligence init")
        let llmBroker = LLMBroker(opener: LiveLLMConnectionOpener())
        let (modelManager, intelligence) = buildModelAndIntelligence(store: store, llmBroker: llmBroker)

        logger.info("AppCore.live: constructing AppCore")
        let core = AppCore(
            store: store,
            permissions: permissions,
            recording: recording,
            transcription: transcription,
            calendar: calendar,
            detector: detector,
            notifications: notifications,
            intelligence: intelligence,
            modelManager: modelManager,
            llmBroker: llmBroker,
            liveTranscription: buildLiveTranscription(store: store, serviceName: transcriberServiceName)
        )
        startChatLoadDriverIfRequested(core)
        logger.info("AppCore.live: done")
        return core
    }

    /// Debug builds: the chat measurement's load driver, when the app was
    /// launched with `-chatLoadTest <plan.json>` (Tools/chat_bench).
    @MainActor
    private static func startChatLoadDriverIfRequested(_ core: AppCore) {
        #if DEBUG
            ChatLoadDriver.startIfRequested(chat: core.chat, app: core.chatLoadControls())
        #endif
    }

    /// Builds the live `ModelManager` + `Intelligence` with real LocalLLM-backed
    /// implementations. `Intelligence` reaches the model through `llmBroker`,
    /// the connection chat shares. Extracted to keep `live(storageRoot:…)`
    /// under the function body length lint limit.
    @MainActor
    private static func buildModelAndIntelligence(
        store: DataStore, llmBroker: LLMBroker
    ) -> (ModelManager, Intelligence) {
        let modelProvider = LiveModelProvider()
        let hardwareProbe = LiveHardwareProbe()
        let modelManager = ModelManager(
            store: store,
            models: modelProvider,
            hardware: hardwareProbe
        )
        let intelligence = Intelligence(
            store: store,
            llm: BrokeredLLMRunner(broker: llmBroker),
            modelManager: modelManager,
            settings: { [store] in
                let saved = try? await store.settings()
                let raw = saved?.summaryPrompt ?? ""
                let effective = raw.isEmpty
                    ? IntelligencePrompts.defaultSummaryPrompt : raw
                return AISettings(
                    enabled: saved?.aiAnalysisEnabled ?? true,
                    summaryPrompt: effective
                )
            }
        )
        return (modelManager, intelligence)
    }

    /// Builds the live transcript service. Each live session gets its own
    /// `Transcriber`, so its connection to the worker ends with it. The
    /// setting is applied at launch (`onLaunch`).
    @MainActor
    private static func buildLiveTranscription(
        store: DataStore, serviceName: String
    ) -> LiveTranscriptionService {
        let vocabulary = VocabularyService(store: store)
        let engine: LiveEngineFactory = { WhisperXPCSession(client: Transcriber(backend: .hosted(serviceName: serviceName))) }
        return LiveTranscriptionService(
            engine: engine,
            model: WhisperLiveModel(),
            vocabulary: { await vocabulary.effectiveVocabulary(meetingID: $0) },
            isEnabled: AppSettingsData().liveTranscriptResolved()
        )
    }

    /// Builds the live `TranscriptionService` with XPC engine and vocabulary.
    /// Extracted to keep `live(storageRoot:…)` under the function body
    /// length lint limit.
    @MainActor
    private static func buildTranscription(
        store: DataStore, serviceName: String, logger: Logger
    ) -> TranscriptionService {
        logger.info("AppCore.live: TranscriptionService init")
        let transcriber = Transcriber(backend: .hosted(serviceName: serviceName))
        return TranscriptionService(
            store: store,
            engine: LiveTranscriberAdapter(transcriber: transcriber),
            vocabulary: VocabularyService(store: store),
            preparedModels: PreparedModels(build: PreparedModels.buildIdentity(), defaults: .standard),
            diskSpace: .system
        )
    }
}

// MARK: - AudioRecorder adapter

/// Bridges `AudioCapture.AudioRecorder` to the `RecorderControlling` protocol.
private struct LiveRecorderAdapter: RecorderControlling {
    let recorder: AudioRecorder

    func requestPermissions(systemProbePath: URL) async -> Bool {
        await recorder.requestPermissions(systemProbePath: systemProbePath)
    }

    func start(paths: CapturePaths, liveTap: LiveAudioTap?) async throws {
        try await recorder.start(paths: paths, liveTap: liveTap)
    }

    func timelineOffset() async -> TimeInterval? {
        await recorder.timelineOffset
    }

    func stop() async {
        await recorder.stop()
    }

    func stateStream() -> AsyncStream<CaptureState> {
        let recorder = recorder
        return AsyncStream { continuation in
            let task = Task {
                let stream = await recorder.stateStream()
                for await state in stream {
                    guard !Task.isCancelled else { break }
                    continuation.yield(state)
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func probableSystemAudioDenied() async -> Bool {
        await recorder.probableSystemAudioDenied()
    }

    func observedSystemAudio() async -> Bool {
        await recorder.observedSystemAudio()
    }

    func probeSystemAudioWithTone(timeout: Duration) async -> Bool {
        await recorder.probeSystemAudioWithTone(timeout: timeout)
    }
}

// MARK: - Notification authorizer adapter

/// Bridges `NotificationService` to the `NotificationAuthorizing` protocol
/// so that `Permissions.requestNotifications()` actually fires the real
/// `UNUserNotificationCenter.requestAuthorization(options:)` call.
///
/// `@MainActor` because `NotificationService` is `@MainActor`-isolated.
private struct LiveNotificationAuthorizerAdapter: NotificationAuthorizing,
    @unchecked Sendable
{
    let service: NotificationService

    func status() async -> PermissionState {
        let authorized = await service.isCurrentlyAuthorized()
        if authorized {
            return .authorized
        }
        let denied = await service.isDenied()
        return denied ? .denied : .notDetermined
    }

    func request() async -> Bool {
        await service.requestAuthorization()
    }
}

// MARK: - Transcriber adapter

/// Bridges `Transcription.Transcriber` to the `Transcribing` protocol.
private struct LiveTranscriberAdapter: Transcribing {
    let transcriber: Transcriber

    nonisolated(nonsending) func ensureModelsDownloaded(
        status: (@Sendable (String) -> Void)?
    ) async throws {
        try await transcriber.ensureModelsDownloaded(status: status)
    }

    nonisolated(nonsending) func processAudio(
        mic: URL,
        system: URL,
        customVocabulary: [String]
    ) async throws -> TranscriptResult {
        try await transcriber.processAudio(
            mic: mic,
            system: system,
            customVocabulary: customVocabulary
        )
    }

    nonisolated(nonsending) func modelsPresent() async -> Bool {
        await transcriber.modelsPresent()
    }

    nonisolated(nonsending) func cancelActiveWork() async {
        await transcriber.cancelActiveWork()
    }

    nonisolated(nonsending) func waitUntilWorkerIdle() async {
        await transcriber.waitUntilWorkerIdle()
    }

    nonisolated(nonsending) func prepareModels(_ models: [String], keepLoaded: String?, reloadingKept: Bool) async throws -> [String] {
        try await transcriber.prepareModels(models, keepLoaded: keepLoaded, reloadingKept: reloadingKept)
    }

    nonisolated(nonsending) func unloadFinalPassModels() async {
        await transcriber.unloadModels()
    }

    nonisolated(nonsending) func observeWorkerInterruptions(_ handler: @escaping @Sendable () -> Void) async {
        await transcriber.observeInterruptions(handler)
    }

    nonisolated(nonsending) func observeModelLoads(_ handler: @escaping @Sendable (Bool) -> Void) async {
        await transcriber.observeModelLoads(handler)
    }

    nonisolated(nonsending) func shutdown() async {
        await transcriber.shutdown()
    }
}

#if DEBUG

    // MARK: - Chat measurement

    extension AppCore {
        /// What the chat load driver uses to run a plan with nobody at the
        /// Mac: the end of the launch and of the speech models' preparation,
        /// the Settings model picker's path, and the Record and Stop buttons'
        /// paths. Debug builds only.
        ///
        /// - Parameter settle: How long no speech model must have been
        ///   prepared before the launch counts as done.
        func chatLoadControls(settle: Duration = .seconds(3)) -> ChatLoadAppControls {
            ChatLoadAppControls(
                waitForLaunch: { [weak self] in
                    await self?.waitUntilLaunched()
                    await self?.waitUntilModelsPrepared(settle: settle)
                },
                selectModel: { [weak self] id in
                    guard let self else { return false }
                    await modelManager.selectModel(id: id)
                    return modelManager.activeModelID == id
                },
                startRecording: { [weak self] in await self?.startRecording() },
                stopRecording: { [weak self] in await self?.stopRecording() }
            )
        }

        /// Returns once no speech model has been prepared for `settle`, as for
        /// a user who opens the app ahead of a meeting. A new build, or a
        /// Core ML cache that macOS purged under low disk space, compiles the
        /// models for minutes first, and a recording started meanwhile holds
        /// its live transcript until the live model's compile ends.
        ///
        /// It checks the preparation after every sleep of `poll`, however long
        /// the sleep took, and ends only once every check over `settle` found
        /// no model being prepared. So a sleep that overran, as when the
        /// process stalls during a long compile, never ends the wait
        /// unchecked. Writes one `chat-load` line, `launch-wait-done
        /// seconds=`, when it ends.
        ///
        /// - Returns: How long it waited, on `clock`.
        @discardableResult
        func waitUntilModelsPrepared(
            settle: Duration = .seconds(3),
            poll: Duration = .milliseconds(500),
            clock: any Clock<Duration> = ContinuousClock()
        ) async -> Duration {
            let waited = await waitWhilePreparing(settle: settle, poll: poll, on: clock)
            if !Task.isCancelled {
                let seconds = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
                chatLoadLogger.info("launch-wait-done seconds=\(String(format: "%.1f", seconds), privacy: .public)")
            }
            return waited
        }

        private func waitWhilePreparing<C: Clock<Duration>>(settle: Duration, poll: Duration, on clock: C) async -> Duration {
            let start = clock.now
            // The first of the latest checks in a row that found no preparation.
            var idleSince: C.Instant?
            while !Task.isCancelled {
                let now = clock.now
                if transcription.isPreparingModels {
                    idleSince = nil
                } else {
                    let since = idleSince ?? now
                    if since.duration(to: now) >= settle { break }
                    idleSince = since
                }
                try? await clock.sleep(for: poll)
            }
            return start.duration(to: clock.now)
        }
    }

    /// The chat load driver's category, which `Tools/chat_bench` captures.
    private let chatLoadLogger = Logger(subsystem: "net.scosman.biscotti", category: "chat-load")
#endif
