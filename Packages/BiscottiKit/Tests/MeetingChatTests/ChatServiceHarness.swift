import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
import LiveTranscriptionService
import LiveTranscriptModel
import LocalLLM
import Testing
import Transcription
@testable import MeetingChat

/// What the chat service reads from the rest of the app, set by each test.
@MainActor
final class ChatWorld {
    var recordingID: UUID?
    var hasModel = true
    var transcribing: Set<UUID> = []
}

/// A chat service on a `CoreFixture`'s store, broker and scripted model,
/// with a fake live transcript and the recording, model and final passes
/// set by the test.
@MainActor
struct ChatHarness {
    static let model = URL(fileURLWithPath: "/models/chat.gguf")
    static let meetingTitle = "Remote control design"

    let fix: CoreFixture
    let world: ChatWorld
    let engines = FakeLiveEngineFactory()
    let live: LiveTranscriptionService
    let tap = ScriptedTap()
    /// The service's store: the fixture's, which a test can make fail or hold.
    let chatStore: TestChatStore
    let service: MeetingChatService

    init(
        policy: ChatResourcePolicy = ChatResourcePolicy(physicalMemory: 32 << 30),
        clock: any Clock<Duration> = ContinuousClock(),
        liveEnabled: Bool = true,
        liveModelPresent: Bool = true
    ) throws {
        let fix = try makeCoreFixture(testName: "MeetingChatTests")
        let world = ChatWorld()
        let live = makeFakeLiveService(engines: engines, model: FakeLiveModel(present: liveModelPresent), isEnabled: liveEnabled)
        let chatStore = TestChatStore(fix.store)
        self.fix = fix
        self.world = world
        self.live = live
        self.chatStore = chatStore
        service = MeetingChatService(
            store: chatStore,
            broker: fix.llmBroker,
            modelURL: { world.hasModel ? Self.model : nil },
            live: live,
            recordingMeetingID: { world.recordingID },
            isTranscribing: { world.transcribing.contains($0) },
            policy: policy,
            clock: clock
        )
    }

    var opener: ScriptedLLMOpener {
        fix.llmOpener
    }

    var script: LLMScript {
        fix.llmOpener.script
    }

    func state(_ meetingID: UUID) -> MeetingChatState {
        service.state(for: meetingID)
    }

    // MARK: - Meetings

    func meeting() async throws -> UUID {
        try await fix.store.createMeeting(title: Self.meetingTitle)
    }

    /// A meeting whose preferred transcript has lines at 0:00 and 0:20.
    func meetingWithTranscript() async throws -> (meetingID: UUID, transcriptID: UUID) {
        let meetingID = try await meeting()
        let result = TranscriptResult(
            transcriptionMethodId: "v1",
            language: "en",
            speakerCount: 2,
            segments: [
                Self.segment(0, 4, "We picked the blue remote.", speaker: 0),
                Self.segment(20, 24, "Battery life matters most.", speaker: 1)
            ],
            processingDuration: 1
        )
        let transcriptID = try await fix.store.addTranscript(result, vocabularyUsed: [], mappedEventIdentifier: nil, to: meetingID)
        try await fix.store.setPreferredTranscript(transcriptID, for: meetingID)
        await service.load(meetingID: meetingID)
        return (meetingID, transcriptID)
    }

    private static func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String, speaker: Int) -> TranscriptSegment {
        TranscriptSegment(
            speakerID: speaker, speakerLabel: "Speaker \(speaker)", startTime: start, endTime: end,
            text: text, confidence: 1, noSpeechProbability: 0, words: nil
        )
    }

    // MARK: - Recording

    /// Starts the meeting's live transcript and returns its engine.
    func startRecording(_ meetingID: UUID) async throws -> FakeLiveEngine {
        world.recordingID = meetingID
        await live.start(meetingID: meetingID, tap: tap, timelineOffset: 0)
        try await waitUntil("a live engine") { engines.engines.count == 1 }
        let engine = engines.engines[0]
        try await waitUntil("its config") { await engine.config != nil }
        return engine
    }

    /// Sends live rows on both tracks, through 0:46. A track counts towards
    /// how far the live transcript reaches once it has captured audio.
    func sendLiveRows(_ engine: FakeLiveEngine) async throws {
        tap.mic.pushTone(seconds: 0.5, from: 0)
        tap.system.pushTone(seconds: 0.5, from: 0)
        await engine.emit(liveUpdate(.system, rows: [
            LiveRow(track: .system, startTime: 3, endTime: 8, settledText: "Let's design the remote."),
            LiveRow(track: .system, startTime: 21, endTime: 26, settledText: "A magnet on the back", tailText: " of it")
        ], transcribedThrough: 46, settledThrough: 40))
        await engine.emit(liveUpdate(.mic, rows: [], transcribedThrough: 46, settledThrough: 46))
        try await waitUntil("the live rows, through 0:46") {
            live.rows.count == 2 && live.snapshot(includeTail: true)?.transcribedThrough == 46
        }
    }

    /// Stops the recording; its draft stays.
    func stopRecording(_ meetingID: UUID) async {
        world.recordingID = nil
        // The recorder closes its tap, so the live finish need not wait for its deadline.
        tap.end(at: 2)
        _ = await live.stop(meetingID).value
    }

    // MARK: - Asking

    func ask(_ question: String, in meetingID: UUID) async {
        state(meetingID).draft = question
        await service.ask(meetingID: meetingID)
    }

    func waitForAnswer(in meetingID: UUID) async throws {
        try await waitUntil("the answer to end") { !state(meetingID).isAnswering }
    }

    /// Asks and waits for the answer to end.
    func askAndWait(_ question: String, in meetingID: UUID) async throws {
        await ask(question, in: meetingID)
        try await waitForAnswer(in: meetingID)
    }

    /// The open thread's last answer view.
    func lastAnswer(in meetingID: UUID) throws -> ChatMessageView {
        try #require(state(meetingID).messages.last { $0.role == .answer })
    }

    /// The status of the answer being written, if any.
    func status(in meetingID: UUID) -> ChatAnswerStatus? {
        guard case let .streaming(status) = state(meetingID).messages.last?.state else { return nil }
        return status
    }

    /// The stored open thread.
    func storedThread(in meetingID: UUID) async throws -> ChatThreadData {
        let threadID = try #require(state(meetingID).openThreadID)
        return try #require(await fix.store.chatThread(id: threadID))
    }

    /// The messages of the last streamed prompt.
    var lastPrompt: [LLMMessage] {
        opener.sessions.last?.streamingCalls.last ?? []
    }
}

/// Advances `clock` once something sleeps on it.
@MainActor
func advanceWhenWaiting(_ clock: TestClock, by duration: Duration = .seconds(1)) async throws {
    try await waitUntil("a sleep on the clock") { clock.pendingSleepCount > 0 }
    clock.advance(by: duration)
}

extension LLMMessage {
    var summary: String {
        "\(role.rawValue): \(content)"
    }
}
