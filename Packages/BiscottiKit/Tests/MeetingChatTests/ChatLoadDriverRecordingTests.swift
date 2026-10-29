#if DEBUG
    import BiscottiTestSupport
    import Foundation
    import Testing
    @testable import MeetingChat

    /// Plans that run with nobody at the Mac: the driver selects the model and
    /// records through the app's controls.
    @Suite("ChatLoadDriver -- unattended runs")
    @MainActor
    struct ChatLoadDriverRecordingTests {
        @Test("A plan with a recording selects its model after the launch, records for its duration, and ends after Stop")
        func planRecordsMeeting() async throws {
            let clock = TestClock()
            let chat = try ChatHarness()
            defer { chat.fix.cleanup() }
            let app = try await FakeChatLoadApp(chat, launched: false)
            let plan = ChatLoadPlan.test(model: "gemma-4-e2b", record: .init(startAfterSeconds: 5, durationSeconds: 30), delay: 2, questions: ["What is on the back?"])
            let driver = ChatLoadDriver(plan: plan, chat: chat.service, clock: clock, app: app.controls)
            driver.start(sampler: nil)
            defer { driver.stop() }

            try await waitUntil("the launch wait") { app.isWaitingForLaunch }
            #expect(driver.lines.isEmpty, "nothing runs before the launch ends")
            app.finishLaunch()
            try await advanceWhenWaiting(clock, by: .seconds(5))
            try await waitUntil("the recording") { app.starts == 1 }
            #expect(app.selected == ["gemma-4-e2b"])
            #expect(driver.lines.first == "plan name=test mode=concurrent closeModelAfterAnswer=- startAfter=recordingStart delay=2.0 interval=0.0 questions=1 model=chat.gguf record=5.0+30.0 live=on")

            try await advanceWhenWaiting(clock, by: .seconds(2))
            try await waitUntil("the answer") { driver.results.count == 1 }
            #expect(driver.askTimes == [.seconds(2)], "after the recording's start")
            #expect(!driver.lines.contains("plan-done"), "the recording still runs")
            #expect(app.stops == 0)

            clock.advance(by: .seconds(28))
            await driver.planTask?.value

            #expect(app.stops == 1)
            #expect(driver.results.map(\.outcome) == ["complete"])
            #expect(driver.lines.filter { !$0.hasPrefix("lease") && !$0.hasPrefix("first-token") && !$0.hasPrefix("done") }.dropFirst() == [
                "recording-started", "ask q=1 t=2.0", "recording-stopped", "plan-done"
            ])
        }

        @Test("An after-Stop plan with a recording asks once its own Stop comes")
        func afterStopPlanRecords() async throws {
            let clock = TestClock()
            let chat = try ChatHarness()
            defer { chat.fix.cleanup() }
            let app = try await FakeChatLoadApp(chat)
            let plan = ChatLoadPlan.test(record: .init(startAfterSeconds: 0, durationSeconds: 10), startAfter: .recordingStop, questions: ["What is on the back?"])
            let driver = ChatLoadDriver(plan: plan, chat: chat.service, clock: clock, app: app.controls)
            driver.start(sampler: nil)
            defer { driver.stop() }

            try await waitUntil("the recording") { app.starts == 1 }
            try await advanceWhenWaiting(clock, by: .seconds(10))
            await driver.planTask?.value

            #expect(app.selected.isEmpty, "the plan keeps the model selected in Settings")
            #expect(app.stops == 1)
            #expect(driver.askTimes == [.zero])
            #expect(driver.results.map(\.outcome) == ["complete"])
            #expect(driver.lines.last == "plan-done")
            #expect(try await chat.storedThread(in: app.meetingID).messages.last?.basis == .draft)
        }

        @Test(
            "A plan that cannot run aborts, records nothing and asks nothing",
            arguments: ["modelNotSelected", "liveTranscriptOff", "liveModelMissing", "recordingDidNotStart", "noAppControls"]
        )
        func planAborts(reason: String) async throws {
            let chat = try ChatHarness(liveEnabled: reason != "liveTranscriptOff", liveModelPresent: reason != "liveModelMissing")
            defer { chat.fix.cleanup() }
            let app = try await FakeChatLoadApp(chat)
            app.downloaded = reason == "modelNotSelected" ? [] : ["gemma-4-12b"]
            app.recordingStarts = reason != "recordingDidNotStart"
            // Without app controls the driver can select no model either, so that plan names none.
            let plan = ChatLoadPlan.test(
                model: reason == "noAppControls" ? nil : "gemma-4-12b",
                record: .init(startAfterSeconds: 0, durationSeconds: 10),
                questions: ["What is on the back?"]
            )
            let driver = ChatLoadDriver(plan: plan, chat: chat.service, clock: TestClock(), app: reason == "noAppControls" ? nil : app.controls)
            driver.start(sampler: nil)
            defer { driver.stop() }

            await driver.planTask?.value

            #expect(driver.lines.count == 2)
            #expect(driver.lines.first?.hasPrefix("plan name=test") == true)
            #expect(driver.lines.last == "abort reason=\(reason)")
            #expect(app.starts == (reason == "recordingDidNotStart" ? 1 : 0))
            #expect(app.stops == 0)
            #expect(driver.askTimes.isEmpty)
        }
    }

    /// App controls that record through the harness, as AppCore's go through
    /// the Record and Stop buttons' paths, with models "downloaded" by name.
    @MainActor
    private final class FakeChatLoadApp {
        let chat: ChatHarness
        let meetingID: UUID
        var downloaded: Set<String> = ["gemma-4-e2b"]
        var recordingStarts = true
        private(set) var selected: [String] = []
        private(set) var starts = 0
        private(set) var stops = 0
        private var launched: Bool
        private var launchWaiter: CheckedContinuation<Void, Never>?

        init(_ chat: ChatHarness, launched: Bool = true) async throws {
            self.chat = chat
            self.launched = launched
            meetingID = try await chat.meeting()
        }

        var isWaitingForLaunch: Bool {
            launchWaiter != nil
        }

        var controls: ChatLoadAppControls {
            ChatLoadAppControls(
                waitForLaunch: { await self.waitForLaunch() },
                selectModel: { id in
                    self.selected.append(id)
                    return self.downloaded.contains(id)
                },
                startRecording: { await self.startRecording() },
                stopRecording: { await self.stopRecording() }
            )
        }

        func finishLaunch() {
            launched = true
            launchWaiter?.resume()
            launchWaiter = nil
        }

        private func waitForLaunch() async {
            guard !launched else { return }
            await withCheckedContinuation { launchWaiter = $0 }
        }

        private func startRecording() async {
            starts += 1
            guard recordingStarts else { return }
            if let engine = try? await chat.startRecording(meetingID) {
                try? await chat.sendLiveRows(engine)
            }
            await chat.service.recordingDidStart()
        }

        private func stopRecording() async {
            stops += 1
            await chat.stopRecording(meetingID)
            await chat.service.recordingDidStop(meetingID: meetingID)
        }
    }
#endif
