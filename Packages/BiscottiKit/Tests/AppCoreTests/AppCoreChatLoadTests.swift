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
    }
#endif
