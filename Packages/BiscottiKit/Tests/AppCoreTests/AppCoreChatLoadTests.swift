#if DEBUG
    import BiscottiTestSupport
    import Foundation
    import MeetingChat
    import Testing
    @testable import AppCore
    @testable import TranscriptionService

    @Suite("AppCore -- chat load controls")
    @MainActor
    struct AppCoreChatLoadTests {
        @Test("The launch wait ends when onLaunch does, and returns at once after it")
        func launchWaitEndsWithOnLaunch() async throws {
            let fix = try makeCoreFixture(testName: "AppCoreChatLoadTests")
            defer { fix.cleanup() }
            let controls = fix.core.chatLoadControls(settle: .zero)
            let launch = LaunchWait()
            let waiter = Task {
                await controls.waitForLaunch()
                launch.ended = true
            }
            await Task.yield()
            #expect(!launch.ended)

            await fix.core.onLaunch()
            await waiter.value

            #expect(launch.ended)
            await controls.waitForLaunch()
        }

        @Test("The launch wait lasts while a speech model is prepared, and a settle after it")
        func launchWaitFollowsModelPreparation() async throws {
            let fix = try makeCoreFixture(testName: "AppCoreChatLoadTests")
            defer { fix.cleanup() }
            fix.core.transcription.modelsBeingPrepared = ["openai_whisper-small"]
            let wait = LaunchWait()
            let waiter = Task {
                await fix.core.waitUntilModelsPrepared(settle: .milliseconds(30), poll: .milliseconds(5))
                wait.ended = true
            }

            try await Task.sleep(for: .milliseconds(100))
            #expect(!wait.ended, "a model is being prepared")

            fix.core.transcription.modelsBeingPrepared = []
            await waiter.value
            #expect(wait.ended)
        }

        @Test("A sleep that overruns during a compile is followed by a check, so the launch wait outlasts the compile")
        func launchWaitChecksAfterStalledSleep() async throws {
            let fix = try makeCoreFixture(testName: "AppCoreChatLoadTests")
            defer { fix.cleanup() }
            let clock = TestClock()
            fix.core.transcription.modelsBeingPrepared = ["openai_whisper-large-v3"]
            let wait = startLaunchWait(fix, clock: clock)

            // A 0.5 s sleep that lasts 4 s: the process stalled during the compile.
            try await advanceWhenSleeping(clock, by: .seconds(4))
            try await waitUntil("the next sleep, or the end") { clock.pendingSleepCount == 1 || wait.waited != nil }
            try #require(wait.waited == nil, "the check after the stall found the compile")

            // The compile ends at 4 s; the checks from 4.5 s find none.
            fix.core.transcription.modelsBeingPrepared = []
            for _ in 0 ..< 6 {
                try await advanceWhenSleeping(clock, by: .milliseconds(500))
            }
            try await waitUntil("the sleep after the check at 7 s, or the end") { clock.pendingSleepCount == 1 || wait.waited != nil }
            #expect(wait.waited == nil, "2.5 s of checks that found none")

            try await advanceWhenSleeping(clock, by: .milliseconds(500))
            try await waitUntil("the end of the wait") { wait.waited != nil }
            #expect(wait.waited == .milliseconds(7500), "3 s after the first check that found none")
        }

        @Test("A compile that starts during a stalled sleep is seen before the launch wait can end")
        func launchWaitSeesCompileStartedDuringStall() async throws {
            let fix = try makeCoreFixture(testName: "AppCoreChatLoadTests")
            defer { fix.cleanup() }
            let clock = TestClock()
            let wait = startLaunchWait(fix, clock: clock)

            // Idle at 0 s; the final pass's model starts compiling during a 4 s stall.
            try await waitUntil("the first sleep") { clock.pendingSleepCount == 1 }
            fix.core.transcription.modelsBeingPrepared = ["openai_whisper-large-v3"]
            clock.advance(by: .seconds(4))
            try await waitUntil("the next sleep, or the end") { clock.pendingSleepCount == 1 || wait.waited != nil }
            try #require(wait.waited == nil, "the check after the stall found the compile")

            fix.core.transcription.modelsBeingPrepared = []
            for _ in 0 ..< 7 {
                try await advanceWhenSleeping(clock, by: .milliseconds(500))
            }
            try await waitUntil("the end of the wait") { wait.waited != nil }
            #expect(wait.waited == .milliseconds(7500), "3 s after the first check that found none, at 4.5 s")
        }

        @Test("A plan's model is selected as Settings selects it, and only once downloaded")
        func selectModelAsSettings() async throws {
            // The fixture's download is the catalog's first model, Gemma 4 12B.
            let fix = try makeCoreFixture(modelDownloaded: true, testName: "AppCoreChatLoadTests")
            defer { fix.cleanup() }
            let controls = fix.core.chatLoadControls(settle: .zero)

            #expect(await controls.selectModel("gemma-4-e2b") == false, "not downloaded")
            #expect(await controls.selectModel("gemma-4-12b"))
            #expect(try await fix.store.settings().selectedModelID == "gemma-4-12b")

            await fix.core.modelManager.downloadModel(id: "gemma-4-e2b")
            #expect(await controls.selectModel("gemma-4-e2b"))
            #expect(fix.core.modelManager.activeModelURL()?.lastPathComponent == "gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf")
            #expect(try await fix.store.settings().selectedModelID == "gemma-4-e2b")
        }

        @Test("The controls record through AppCore's Record and Stop paths")
        func recordAndStop() async throws {
            let fix = try makeCoreFixture(testName: "AppCoreChatLoadTests")
            defer { fix.cleanup() }
            let controls = fix.core.chatLoadControls(settle: .zero)

            await controls.startRecording()
            let meetingID = try #require(fix.core.recording.state.meetingID)
            #expect(fix.core.runState == .recording(meetingID))

            await controls.stopRecording()
            #expect(!fix.core.recording.state.isRecording)
            #expect(fix.core.runState == .idle)
            await fix.core.awaitPendingTranscription()
        }
    }

    @MainActor
    private final class LaunchWait {
        var ended = false
        /// What the wait returned, once it ended.
        var waited: Duration?
    }

    /// Starts the launch wait at its defaults (3 s settle, 0.5 s poll) on `clock`.
    @MainActor
    private func startLaunchWait(_ fix: CoreFixture, clock: TestClock) -> LaunchWait {
        let wait = LaunchWait()
        Task {
            wait.waited = await fix.core.waitUntilModelsPrepared(clock: clock)
        }
        return wait
    }

    /// Advances `clock` once the launch wait sleeps on it.
    @MainActor
    private func advanceWhenSleeping(_ clock: TestClock, by duration: Duration) async throws {
        try await waitUntil("a sleep on the clock") { clock.pendingSleepCount > 0 }
        clock.advance(by: duration)
    }
#endif
