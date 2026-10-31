#if DEBUG
    import BiscottiTestSupport
    import DataStore
    import Foundation
    import Testing
    @testable import MeetingChat

    private let gib: UInt64 = 1 << 30

    @Suite("ChatLoadDriver")
    @MainActor
    struct ChatLoadDriverTests {
        static let plans = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MeetingChatTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // BiscottiKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // the repository
            .appending(path: "Tools/chat_bench/plans")

        @Test("The four plans decode, and the plan file is read from the launch arguments")
        func planParses() throws {
            let names = ["baseline", "concurrent-e2b", "concurrent-12b", "after-stop"]
            let plans = try names.map { try ChatLoadPlan.load(from: Self.plans.appending(path: "\($0).json")) }

            #expect(plans.map(\.name) == names)
            #expect(plans.map(\.mode) == [.concurrent, .concurrent, .concurrent, .concurrent])
            // Macs that use E2B (under 24 GB) close the model after each answer during a recording.
            #expect(plans.map(\.closeModelAfterAnswer) == [nil, true, false, nil])
            #expect(plans.map(\.startAfter) == [.recordingStart, .recordingStart, .recordingStart, .recordingStop])
            #expect(plans.map(\.questions.count) == [0, 8, 8, 4])
            #expect(plans.map(\.model) == ["gemma-4-e2b", "gemma-4-e2b", "gemma-4-12b", "gemma-4-e2b"])
            #expect(plans.allSatisfy { $0.record == ChatLoadPlan.Recording(startAfterSeconds: 10, durationSeconds: 900) })
            #expect(plans[1].questions == plans[2].questions)
            #expect(plans[1].dueTime(ofQuestion: 0) == .seconds(120))
            #expect(plans[1].dueTime(ofQuestion: 7) == .seconds(540))
            #expect(plans[3].dueTime(ofQuestion: 3) == .zero)

            #expect(ChatLoadPlan.path(in: ["Biscotti Dev", "-chatLoadTest", "/plans/concurrent.json"]) == "/plans/concurrent.json")
            #expect(ChatLoadPlan.path(in: ["Biscotti Dev", "-chatLoadTest"]) == nil)
            #expect(ChatLoadPlan.path(in: ["Biscotti Dev"]) == nil)
        }

        @Test("Without the launch argument, or with an unreadable plan, no driver starts")
        func noDriverWithoutPlan() throws {
            let chat = try ChatHarness()
            defer { chat.fix.cleanup() }

            #expect(ChatLoadDriver.startIfRequested(chat: chat.service, arguments: ["Biscotti Dev"]) == nil)
            #expect(ChatLoadDriver.startIfRequested(chat: chat.service, arguments: ["Biscotti Dev", "-chatLoadTest", "/no/such/plan.json"]) == nil)
            #expect(chat.service.loadObserver == nil)
        }

        @Test("The driver asks at the plan's times, and never while an answer runs")
        func driverAsksOnSchedule() async throws {
            let clock = TestClock()
            let tokens = TestClock()
            let chat = try ChatHarness()
            defer { chat.fix.cleanup() }
            chat.script.streams = [
                ScriptedStream(["The ", "first."], tokenDelay: .seconds(1), clock: tokens),
                ScriptedStream(["The second."]),
                ScriptedStream(["The third."])
            ]
            let meetingID = try await chat.meeting()
            try await chat.sendLiveRows(chat.startRecording(meetingID))
            let driver = ChatLoadDriver(plan: .test(delay: 2, interval: 3, questions: ["First?", "Second?", "Third?"]), chat: chat.service, clock: clock)
            driver.start(sampler: nil)
            defer { driver.stop() }

            await chat.service.recordingDidStart()
            try await advanceWhenWaiting(clock, by: .seconds(2))
            try await waitUntil("the first answer to stream") { tokens.pendingSleepCount > 0 }
            // The second question comes due at 5 s while the first answer runs.
            clock.advance(by: .seconds(4))
            #expect(driver.askTimes == [.seconds(2)])

            try await advanceWhenWaiting(tokens)
            try await advanceWhenWaiting(tokens)
            try await waitUntil("the second answer") { driver.results.count == 2 }
            try await advanceWhenWaiting(clock, by: .seconds(2))
            try await waitUntil("the third answer") { driver.results.count == 3 }

            #expect(driver.askTimes == [.seconds(2), .seconds(6), .seconds(8)])
            #expect(driver.results.map(\.question) == [1, 2, 3])
            #expect(driver.results.map(\.outcome) == ["complete", "complete", "complete"])
            let thread = try await chat.storedThread(in: meetingID)
            #expect(thread.messages.map(\.text) == ["First?", "The first.", "Second?", "The second.", "Third?", "The third."])
        }

        @Test("An answer's figures come from its prompt, tokens and citations")
        func driverRecordsAnswerFigures() async throws {
            let chat = try ChatHarness()
            defer { chat.fix.cleanup() }
            chat.script.tokenCount = 120
            chat.script.streams = [ScriptedStream(["They picked ", "blue [0:20] ", "at [0:21, 9:00]."])]
            let (meetingID, _) = try await chat.meetingWithTranscript()
            let driver = ChatLoadDriver(plan: .test(startAfter: .recordingStop, questions: ["What did we decide?"]), chat: chat.service, clock: TestClock())
            driver.start(sampler: nil)
            defer { driver.stop() }

            await chat.service.recordingDidStop(meetingID: meetingID)
            try await waitUntil("the answer") { driver.results.count == 1 }

            let result = try #require(driver.results.first)
            let context = ChatPromptBuilder.contextSize(promptTokens: 120)
            #expect(result.question == 1)
            #expect(result.outcome == "complete")
            #expect(result.promptTokens == 120)
            #expect(result.contextSize == context)
            #expect(result.isPartial == false)
            #expect(result.tokens == 3)
            #expect(result.generatedTokens == 1, "the scripted model's count")
            #expect(result.generationSeconds == 0)
            #expect(result.citedTimes == 3)
            #expect(result.linkedTimes == 2)
            #expect(result.error == nil)
            #expect(result.logLine == "done q=1 outcome=complete promptTokens=120 context=\(context) partial=false tokens=3 generated=1 generationSeconds=0.000 cited=3 linked=2")
        }

        @Test("A prompt too long for the context ends once, failed, with the model kept loaded")
        func promptTooLongEndsOnce() async throws {
            let chat = try ChatHarness()
            defer { chat.fix.cleanup() }
            chat.script.tokenCount = 1_000_000
            let (meetingID, _) = try await chat.meetingWithTranscript()
            let driver = ChatLoadDriver(plan: .test(startAfter: .recordingStop, questions: ["What did we decide?"]), chat: chat.service, clock: TestClock())
            driver.start(sampler: nil)
            defer { driver.stop() }

            await chat.service.recordingDidStop(meetingID: meetingID)
            try await waitUntil("the answer") { driver.results.count == 1 }
            await Task.yield()

            let result = try #require(driver.results.first)
            #expect(driver.results.count == 1)
            #expect(result.outcome == "failed")
            #expect(result.error == ChatErrorText.tooLong)
            #expect(result.promptTokens == nil)
            #expect(result.tokens == 0)
            #expect(chat.opener.closeCount == 0)
        }

        @Test("A plan that starts after Stop asks nothing during the recording, then answers from the draft")
        func afterStopPlanStartsAtStop() async throws {
            let clock = TestClock()
            let chat = try ChatHarness()
            defer { chat.fix.cleanup() }
            let meetingID = try await chat.meeting()
            try await chat.sendLiveRows(chat.startRecording(meetingID))
            let driver = ChatLoadDriver(plan: .test(startAfter: .recordingStop, questions: ["What is on the back?", "And the front?"]), chat: chat.service, clock: clock)
            driver.start(sampler: nil)
            defer { driver.stop() }

            await chat.service.recordingDidStart()
            clock.advance(by: .seconds(60))
            #expect(driver.askTimes.isEmpty)

            await chat.stopRecording(meetingID)
            await chat.service.recordingDidStop(meetingID: meetingID)
            try await waitUntil("both answers") { driver.results.count == 2 }

            #expect(driver.askTimes == [.zero, .zero])
            #expect(driver.results.map(\.outcome) == ["complete", "complete"])
            #expect(try await chat.storedThread(in: meetingID).messages.last?.basis == .draft)
        }

        @Test("A question chat cannot take is skipped, and the next one is asked on time")
        func unavailableQuestionIsSkipped() async throws {
            let clock = TestClock()
            let chat = try ChatHarness(liveEnabled: false)
            defer { chat.fix.cleanup() }
            let meetingID = try await chat.meeting()
            chat.world.recordingID = meetingID
            let driver = ChatLoadDriver(plan: .test(interval: 1, questions: ["Skipped?", "Asked?"]), chat: chat.service, clock: clock)
            driver.start(sampler: nil)
            defer { driver.stop() }

            await chat.service.recordingDidStart()
            try await waitUntil("the second question's wait") { clock.pendingSleepCount > 0 }
            #expect(driver.askTimes.isEmpty, "the live transcript is off")

            await chat.live.setEnabled(true)
            clock.advance(by: .seconds(1))
            try await waitUntil("the second answer") { driver.results.count == 1 }

            #expect(driver.askTimes == [.seconds(1)])
            #expect(driver.results.map(\.question) == [2])
            #expect(driver.results.first?.outcome == "failed")
            #expect(driver.results.first?.error == ChatErrorText.noTranscript)
        }

        @Test("The plan's mode overrides the resource policy")
        func overrideForcesMode() async throws {
            let waits = ChatResourcePolicy(physicalMemory: 8 * gib, waitForStopMaximumMemory: 8 * gib)
            let answers = ChatResourcePolicy(physicalMemory: 64 * gib)
            #expect(waits.override(mode: .concurrent).mode() == .concurrent)
            #expect(answers.override(mode: .waitForStop).mode() == .waitForStop)
            #expect(answers.override(mode: .waitForStop).keepAlive(isRecording: true) == answers.keepAlive(isRecording: true))
            #expect(answers.override(mode: .concurrent, closesAfterAnswer: true).keepAlive(isRecording: true) == .close)
            #expect(answers.override(mode: .concurrent, closesAfterAnswer: true).keepAlive(isRecording: false) == .keepOpen(.seconds(180)))
            #expect(waits.override(mode: .concurrent, closesAfterAnswer: false).keepAlive(isRecording: true) == .keepOpen(.seconds(180)))

            let chat = try ChatHarness()
            defer { chat.fix.cleanup() }
            let meetingID = try await chat.meeting()
            try await chat.sendLiveRows(chat.startRecording(meetingID))
            let driver = ChatLoadDriver(plan: .test(mode: .waitForStop, questions: ["What is on the back?"]), chat: chat.service, clock: TestClock())
            driver.start(sampler: nil)
            defer { driver.stop() }
            #expect(chat.service.policy.mode() == .waitForStop)

            await chat.service.recordingDidStart()
            try await waitUntil("the question to wait") { chat.status(in: meetingID) == .waitingForRecordingToEnd }
            await chat.stopRecording(meetingID)
            await chat.service.recordingDidStop(meetingID: meetingID)
            try await waitUntil("the answer") { driver.results.count == 1 }

            #expect(driver.results.first?.outcome == "complete")
        }

        @Test(
            "A plan can close the model after each answer during a recording, or keep it, whatever this Mac's memory",
            arguments: [(true, 32 * gib, 1), (false, 16 * gib, 0)]
        )
        func planForcesCloseAfterAnswer(close: Bool, memory: UInt64, closes: Int) async throws {
            let chat = try ChatHarness(policy: ChatResourcePolicy(physicalMemory: memory))
            defer { chat.fix.cleanup() }
            let meetingID = try await chat.meeting()
            try await chat.sendLiveRows(chat.startRecording(meetingID))
            let driver = ChatLoadDriver(plan: .test(closeModelAfterAnswer: close, questions: ["What is on the back?"]), chat: chat.service, clock: TestClock())
            driver.start(sampler: nil)
            defer { driver.stop() }

            await chat.service.recordingDidStart()
            try await waitUntil("the answer") { driver.results.count == 1 }

            #expect(chat.opener.closeCount == closes)
        }

        @Test("The service reports the recording, the lease, the first token and the end")
        func serviceReportsMilestones() async throws {
            let clock = TestClock()
            let chat = try ChatHarness()
            defer { chat.fix.cleanup() }
            chat.opener.clock = clock
            chat.opener.openDelay = .seconds(1)
            chat.script.streams = [ScriptedStream(["One ", "two."])]
            let meetingID = try await chat.meeting()
            try await chat.sendLiveRows(chat.startRecording(meetingID))
            let events = EventLog()
            chat.service.loadObserver = { events.append($0) }

            await chat.service.recordingDidStart()
            await chat.ask("What is on the back?", in: meetingID)
            try await advanceWhenWaiting(clock)
            try await chat.waitForAnswer(in: meetingID)
            await chat.stopRecording(meetingID)
            await chat.service.recordingDidStop(meetingID: meetingID)

            #expect(events.names == ["recording-started", "lease loading", "lease", "first-token", "ended", "recording-stopped"])
        }

        @Test("Citations count each bracketed time; linked ones are near evidence")
        func citationCounts() {
            let counts = ChatLoadResult.citations(
                in: "Blue [0:20]. Also [0:21, 9:00] and [1:00–1:10], not [soon] or 2:00.",
                evidenceTimes: [0, 20, 60]
            )

            #expect(counts.cited == 4)
            #expect(counts.linked == 3)
        }
    }

    /// The service's load events, by name.
    @MainActor
    private final class EventLog {
        private(set) var names: [String] = []

        func append(_ event: ChatLoadEvent) {
            switch event {
            case .recordingStarted: names.append("recording-started")
            case .recordingStopped: names.append("recording-stopped")
            case let .leaseStarted(_, loadingModel): names.append(loadingModel ? "lease loading" : "lease")
            case .firstToken: names.append("first-token")
            case .ended: names.append("ended")
            }
        }
    }

    extension ChatLoadPlan {
        static func test(
            mode: Mode = .concurrent,
            closeModelAfterAnswer: Bool? = nil,
            model: String? = nil,
            record: Recording? = nil,
            startAfter: Start = .recordingStart,
            delay: Double = 0,
            interval: Double = 0,
            questions: [String]
        ) -> ChatLoadPlan {
            ChatLoadPlan(
                name: "test", mode: mode, startAfter: startAfter, closeModelAfterAnswer: closeModelAfterAnswer,
                startDelaySeconds: delay, intervalSeconds: interval, questions: questions, model: model, record: record
            )
        }
    }
#endif
