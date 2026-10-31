import BiscottiTestSupport
import DataStore
import Foundation
import Intelligence
import LocalLLM
import Testing
@testable import MeetingChat

private let gib: UInt64 = 1 << 30

@Suite("MeetingChatService -- keeping the model ready")
@MainActor
struct MeetingChatModelLoadTests {
    /// A chat harness whose service keeps its settings in a defaults suite of its own.
    private struct Harness {
        let chat: ChatHarness
        let defaults: UserDefaults
        let cleanup: () -> Void
    }

    private func harness(
        memory: UInt64 = 32 * gib,
        waitForStopMaximumMemory: UInt64 = 0,
        clock: any Clock<Duration> = ContinuousClock()
    ) throws -> Harness {
        let suite = "meeting-chat-model-load-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let policy = ChatResourcePolicy(physicalMemory: memory, waitForStopMaximumMemory: waitForStopMaximumMemory)
        let chat = try ChatHarness(policy: policy, clock: clock, defaults: defaults)
        return Harness(chat: chat, defaults: defaults) {
            defaults.removePersistentDomain(forName: suite)
            chat.fix.cleanup()
        }
    }

    private func loadAheadEnded(_ chat: ChatHarness) async throws {
        try await waitUntil("the load ahead to end") { chat.service.loadAheadTask == nil }
    }

    // MARK: - Policy

    @Test("the model loads ahead outside recordings, and during one only where it would stay loaded")
    func policyLoadsAhead() {
        for memory in [8 * gib, 16 * gib, 32 * gib] {
            #expect(ChatResourcePolicy(physicalMemory: memory).loadsAhead(isRecording: false))
        }
        #expect(ChatResourcePolicy(physicalMemory: 32 * gib).loadsAhead(isRecording: true))
        #expect(!ChatResourcePolicy(physicalMemory: 16 * gib).loadsAhead(isRecording: true), "closed after each answer")
        #expect(!ChatResourcePolicy(physicalMemory: 32 * gib, waitForStopMaximumMemory: 32 * gib).loadsAhead(isRecording: true), "waits for Stop")
    }

    @Test("keep-ready keeps the model loaded unless the recording memory rule closes it")
    func policyKeepsModelLoaded() {
        let small = ChatResourcePolicy(physicalMemory: 16 * gib)
        let large = ChatResourcePolicy(physicalMemory: 32 * gib)
        for policy in [small, large] {
            #expect(!policy.keepsModelLoaded(keepModelReady: false, isRecording: false))
            #expect(!policy.keepsModelLoaded(keepModelReady: false, isRecording: true))
            #expect(policy.keepsModelLoaded(keepModelReady: true, isRecording: false))
        }
        #expect(large.keepsModelLoaded(keepModelReady: true, isRecording: true))
        #expect(!small.keepsModelLoaded(keepModelReady: true, isRecording: true))
    }

    // MARK: - The setting

    @Test("turning keep-ready on loads the model and keeps it past the idle keep-alive; off lets it close")
    func settingKeepsModelLoaded() async throws {
        let setup = try harness()
        defer { setup.cleanup() }
        let chat = setup.chat
        let defaults = setup.defaults
        #expect(!chat.service.keepsModelReady, "off by default")

        await chat.service.setKeepsModelReady(true)
        try await loadAheadEnded(chat)
        #expect(chat.opener.openCount == 1)
        #expect(defaults.bool(forKey: ChatModelRecords.keepModelReadyKey))

        let (meetingID, _) = try await chat.meetingWithTranscript()
        try await chat.askAndWait("What did we decide?", in: meetingID)
        chat.fix.llmClock.advance(by: .seconds(3600))
        try await Task.sleep(for: .milliseconds(20))
        #expect(chat.opener.closeCount == 0)
        #expect(chat.opener.openCount == 1, "the answer used the loaded model")

        await chat.service.setKeepsModelReady(false)
        chat.fix.llmClock.advance(by: .seconds(180))
        try await waitUntil("the idle close") { chat.opener.closeCount == 1 }
        #expect(chat.relaunched().keepsModelReady == false)
    }

    @Test("the setting is kept across launches, and loads the model once launch work ends")
    func settingLoadsAfterLaunch() async throws {
        let setup = try harness()
        defer { setup.cleanup() }
        let chat = setup.chat
        await chat.service.setKeepsModelReady(true)
        try await loadAheadEnded(chat)
        await chat.fix.llmBroker.closeWhenIdle()

        let relaunched = chat.relaunched()
        #expect(relaunched.keepsModelReady)
        await relaunched.launchWorkDidEnd()
        try await waitUntil("the load after launch") { relaunched.loadAheadTask == nil && chat.opener.openCount == 2 }
    }

    @Test("with keep-ready off, the end of launch work loads nothing")
    func launchWithSettingOffLoadsNothing() async throws {
        let setup = try harness()
        defer { setup.cleanup() }
        let chat = setup.chat

        await chat.service.launchWorkDidEnd()

        #expect(chat.service.loadAheadTask == nil)
        #expect(chat.opener.openCount == 0)
    }

    @Test("on a Mac under 24 GB a recording closes the kept model, and its stop loads it again")
    func recordingRuleWinsOverSetting() async throws {
        let setup = try harness(memory: 16 * gib)
        defer { setup.cleanup() }
        let chat = setup.chat
        await chat.service.setKeepsModelReady(true)
        try await loadAheadEnded(chat)
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)

        await chat.service.recordingDidStart()
        #expect(chat.opener.closeCount == 1)
        chat.service.questionFieldDidTakeFocus(meetingID: meetingID)
        #expect(chat.service.loadAheadTask == nil, "the memory rule would close it at once")
        try await chat.askAndWait("What is on the back?", in: meetingID)
        #expect(chat.opener.closeCount == 2, "closed after the answer")

        await chat.stopRecording(meetingID)
        await chat.service.recordingDidStop(meetingID: meetingID)
        try await loadAheadEnded(chat)
        #expect(chat.opener.openCount == 3)
        chat.fix.llmClock.advance(by: .seconds(3600))
        try await Task.sleep(for: .milliseconds(20))
        #expect(chat.opener.closeCount == 2, "kept loaded again")
    }

    @Test("on a Mac with 24 GB or more a recording keeps the kept model")
    func largeMacKeepsModelDuringRecording() async throws {
        let setup = try harness(memory: 32 * gib)
        defer { setup.cleanup() }
        let chat = setup.chat
        await chat.service.setKeepsModelReady(true)
        try await loadAheadEnded(chat)
        let meetingID = try await chat.meeting()
        let engine = try await chat.startRecording(meetingID)
        try await chat.sendLiveRows(engine)

        await chat.service.recordingDidStart()
        try await chat.askAndWait("What is on the back?", in: meetingID)
        chat.fix.llmClock.advance(by: .seconds(3600))
        try await Task.sleep(for: .milliseconds(20))

        #expect(chat.opener.openCount == 1)
        #expect(chat.opener.closeCount == 0)
    }

    @Test("with keep-ready on, a deleted model is closed and a new one replaces it")
    func modelChangeFollowsSetting() async throws {
        let setup = try harness()
        defer { setup.cleanup() }
        let chat = setup.chat
        await chat.service.setKeepsModelReady(true)
        try await loadAheadEnded(chat)

        chat.world.hasModel = false
        await chat.service.activeModelDidChange()
        #expect(chat.opener.closeCount == 1)

        chat.world.hasModel = true
        await chat.service.activeModelDidChange()
        try await loadAheadEnded(chat)
        #expect(chat.opener.openCount == 2)
    }

    // MARK: - Loading on focus

    @Test("focus loads the model; with no question it closes after the idle keep-alive")
    func focusLoadsThenIdleCloses() async throws {
        let setup = try harness()
        defer { setup.cleanup() }
        let chat = setup.chat
        let (meetingID, _) = try await chat.meetingWithTranscript()

        chat.service.questionFieldDidTakeFocus(meetingID: meetingID)
        chat.service.questionFieldDidTakeFocus(meetingID: meetingID)
        try await loadAheadEnded(chat)
        #expect(chat.opener.openCount == 1)

        chat.service.questionFieldDidTakeFocus(meetingID: meetingID)
        try await loadAheadEnded(chat)
        #expect(chat.opener.openCount == 1, "already loaded")

        chat.fix.llmClock.advance(by: .seconds(180))
        try await waitUntil("the idle close") { chat.opener.closeCount == 1 }
    }

    @Test("focus loads nothing where chat is unavailable, during a wait-for-Stop, or while an answer runs")
    func focusLoadConditions() async throws {
        let setup = try harness(memory: 8 * gib, waitForStopMaximumMemory: 8 * gib)
        defer { setup.cleanup() }
        let chat = setup.chat
        let emptyID = try await chat.meeting()
        chat.service.questionFieldDidTakeFocus(meetingID: emptyID)
        #expect(chat.service.loadAheadTask == nil, "no transcript")

        let (meetingID, _) = try await chat.meetingWithTranscript()
        chat.world.hasModel = false
        chat.service.questionFieldDidTakeFocus(meetingID: meetingID)
        #expect(chat.service.loadAheadTask == nil, "no model")
        chat.world.hasModel = true

        let recordedID = try await chat.meeting()
        let engine = try await chat.startRecording(recordedID)
        try await chat.sendLiveRows(engine)
        chat.service.questionFieldDidTakeFocus(meetingID: recordedID)
        #expect(chat.service.loadAheadTask == nil, "questions wait for Stop")
        await chat.ask("What is on the back?", in: recordedID)
        try await waitUntil("waiting for the recording") { chat.status(in: recordedID) == .waitingForRecordingToEnd }
        await chat.stopRecording(recordedID)
        chat.service.questionFieldDidTakeFocus(meetingID: recordedID)
        #expect(chat.service.loadAheadTask == nil, "an answer waits")

        chat.service.stop()
        #expect(chat.opener.openCount == 0)
    }

    @Test("a question sent while the model loads ahead shows the load, then the dots, and reuses the model")
    func questionDuringLoadAhead() async throws {
        let setup = try harness()
        defer { setup.cleanup() }
        let chat = setup.chat
        let gate = Latch()
        chat.opener.openGate = gate
        let (meetingID, _) = try await chat.meetingWithTranscript()
        chat.service.questionFieldDidTakeFocus(meetingID: meetingID)
        try await waitUntil("the load") { chat.service.modelLoad != nil }

        await chat.ask("What did we decide?", in: meetingID)
        #expect(chat.status(in: meetingID) == .loadingModel)
        gate.open()
        try await chat.waitForAnswer(in: meetingID)
        try await loadAheadEnded(chat)

        #expect(try chat.lastAnswer(in: meetingID).state == .complete)
        #expect(chat.opener.openCount == 1)
        #expect(chat.service.modelLoad == nil)
    }

    // MARK: - Estimates

    @Test("each load's time is stored per model and is the next load's estimate")
    func loadTimeBecomesEstimate() async throws {
        let clock = TestClock()
        let setup = try harness(clock: clock)
        defer { setup.cleanup() }
        let chat = setup.chat
        let defaults = setup.defaults
        chat.opener.clock = clock
        chat.opener.openDelay = .seconds(20)
        let (meetingID, _) = try await chat.meetingWithTranscript()

        await chat.ask("What did we decide?", in: meetingID)
        try await waitUntil("the load") { chat.service.modelLoad != nil }
        #expect(chat.service.modelLoad?.estimate == nil, "no earlier load")
        #expect(chat.status(in: meetingID) == .loadingModel)
        try await advanceWhenWaiting(clock, by: .seconds(20))
        try await chat.waitForAnswer(in: meetingID)
        #expect(chat.service.modelLoad == nil)
        #expect(defaults.double(forKey: ChatModelRecords.loadKey(ChatHarness.model)) == 20)

        await chat.fix.llmBroker.closeWhenIdle()
        chat.service.questionFieldDidTakeFocus(meetingID: meetingID)
        try await waitUntil("the second load") { chat.service.modelLoad != nil }
        #expect(chat.service.modelLoad?.estimate == .seconds(20))
        try await advanceWhenWaiting(clock, by: .seconds(31))
        try await loadAheadEnded(chat)
        #expect(ChatModelRecords(defaults: defaults).lastLoadDuration(of: ChatHarness.model) == .seconds(31))
    }

    @Test("a load that fails stores no time and leaves no load showing")
    func failedLoadStoresNothing() async throws {
        let setup = try harness()
        defer { setup.cleanup() }
        let chat = setup.chat
        let defaults = setup.defaults
        chat.opener.openErrors = [LLMServiceError.connectionClosed]
        let (meetingID, _) = try await chat.meetingWithTranscript()

        try await chat.askAndWait("What did we decide?", in: meetingID)

        #expect(try chat.lastAnswer(in: meetingID).state == .failed("The AI model couldn't start."))
        #expect(chat.service.modelLoad == nil)
        #expect(defaults.object(forKey: ChatModelRecords.loadKey(ChatHarness.model)) == nil)
    }
}
