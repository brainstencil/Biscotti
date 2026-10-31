---
status: complete
---

# Phase 6: Run the chat measurement

## Overview

Runs [chat_measurement](../components/chat_measurement.md) on this Mac, unattended: `baseline`, `concurrent-e2b`, `after-stop` and `concurrent-12b` in Biscotti Dev, with the soak fixture played through the speakers. Nobody clicks, so debug builds first gain a way for a plan to choose the AI model and to start and stop the recording itself, and a script runs README steps 2 to 10. The analysis gets three fixes from phase 5's review. The results go in `research/chat_measurement/README.md`, and `ChatResourcePolicy`'s thresholds are set from them by the decision rule.

The Low Power Mode run and `make test-ai` need the user and are left for them. Phase 7 is not built here, whatever the contention rule says.

## Steps

1. **Plan fields** (`MeetingChat/Debug/ChatLoadPlan.swift`):
   - `model: String?`: a catalog model id (`gemma-4-e2b`, `gemma-4-12b`) selected for the run.
   - `record: Recording?`, `struct Recording: Decodable { startAfterSeconds: Double; durationSeconds: Double }`: the driver starts a recording `startAfterSeconds` after the app's launch and stops it `durationSeconds` after it started.
   - The four plans get `"model"` and `"record": { "startAfterSeconds": 10, "durationSeconds": 900 }`; `concurrent-12b` selects `gemma-4-12b`, the others `gemma-4-e2b`.

2. **App controls** (`MeetingChat/Debug/ChatLoadDriver.swift`): `public struct ChatLoadAppControls` with `@MainActor` closures `waitForLaunch() async`, `selectModel(String) async -> Bool` (true when that model is now the active one), `startRecording() async` and `stopRecording() async`. `ChatLoadDriver.init(plan:chat:clock:app:)` and `startIfRequested(chat:app:arguments:)` take it (nil in tests that do not need it).

3. **Driver flow** (`ChatLoadDriver`):
   - `start(sampler:)` still forces the policy, installs the observer and starts the memory log at once. One task then: waits for the launch (with app controls), selects the plan's model, writes the `plan` line with `model=<active model file or ->` and `record=<startAfter>+<duration>` (or `-`), then runs the recording and the questions side by side, and writes `plan-done` once both end.
   - It aborts the plan, with an `abort reason=<reason>` line and no `plan-done`, when the plan's model could not be selected (`modelNotSelected`), the live transcript cannot start (`liveTranscriptOff`: `chat.live.canStartLive` is false), or `startRecording` returned without a `recording-started` event (`recordingDidNotStart`).
   - The recording: sleeps `startAfterSeconds`, calls `startRecording`, sleeps until `durationSeconds` after the `recording-started` event, calls `stopRecording`.
   - DEBUG test record: `private(set) var lines: [String]`, every line the driver writes except the memory lines.

4. **AppCore** (DEBUG only):
   - `AppCore.swift`: `@ObservationIgnored` `launchWaiters` and `hasFinishedLaunch`; `onLaunch()` resumes the waiters when it returns (both the onboarding and the home path); `waitUntilLaunched()`.
   - `AppCore+Live.swift`: `chatLoadControls` passes `waitUntilLaunched`, `modelManager.selectModel(id:)` (the Settings picker's path) then `modelManager.activeModelID == id`, `startRecording()` and `stopRecording()` (the Record and Stop buttons' paths); `startChatLoadDriverIfRequested` passes them.

5. **`Tools/chat_bench/run.sh RUN PLAN`** (bash; PLAN is a plan name or a path): refuses to run while production Biscotti runs; quits Biscotti Dev with `osascript` and waits for every `Biscotti Dev.app` process to end; starts `log stream` into `results/RUN.ndjson`; waits 2 s; `open`s Biscotti Dev with the plan's absolute path; waits for `recording-started` (aborts after 90 s, or at once on an `abort` line); starts `afplay soak/mixed.wav`; waits for `plan-done` and 60 s more (35-minute overall limit; aborts if Biscotti Dev quits or production Biscotti starts); stops `afplay` and the capture; quits Biscotti Dev; runs `analyze.py`. A trap cleans up on every exit path.

6. **`analyze.py`**:
   - Each answer whose outcome is not `complete` adds a reason that makes the verdict undetermined: `question 4 failed (<error>)`, `question 2 stopped`.
   - A warning when the plan's name carries `e2b` or `12b`, models were loaded, and no loaded file carries that tag.
   - Watchdog resets keep their count, and each gets a description, in `watchdogResetTimes` and the table: `at 14:58, 312 s after q8's done` (time since the recording started; `N s after Stop` when after it; `inside q3's answer` or `N s before q3's lease` otherwise).
   - An `abort` line becomes a warning.

7. **README**: the run script, the `model` and `record` plan fields, and the `abort` line.

8. **Measure**: `make build-development`, then `run.sh` for `baseline`, `concurrent-e2b`, `after-stop`, `concurrent-12b`, in the background. Keep `results/*.json` and `*.md`.
   - `Tools/development.sh` takes an optional `BISCOTTI_DEV_DERIVED_DATA` (default `$BUILD_ROOT/DerivedData/Development`, from which `APP` is derived), so this branch builds into `DerivedData/Development-meeting-chat` and another session's build cannot replace it; `run.sh` runs that app through `BISCOTTI_DEV_APP`.

9. **Write up and thresholds**: `research/chat_measurement/README.md` (hardware, model files, each run's table and verdict, memory against each tier's budget, each tier's decision, what remains for the user). `ChatResourcePolicy.waitForStopMaximumMemory` (and `closeAfterAnswerBelowMemory` if the data says so) from the decision rule; `MeetingChatPolicyTests` updated.

10. **Driver test from the post-merge review**: `promptTooLongEndsOnce` after `driverRecordsAnswerFigures`.

## Tests

- `ChatLoadDriverTests.planParses`: the four plans' models and recordings.
- `planRecordsMeeting`: with fake app controls and a test clock, the driver waits for the launch, selects the model, logs it in the plan line, starts the recording after `startAfterSeconds`, asks on the recording's schedule, stops after `durationSeconds`, and writes `plan-done` only after the stop.
- `afterStopPlanRecords`: an after-stop plan with a recording asks once the driver's own Stop comes.
- `planAbortsWhenModelNotSelected`, `planAbortsWhenLiveTranscriptOff`, `planAbortsWhenRecordingDoesNotStart`: an `abort` line, no recording (or no stop), no questions, no `plan-done`.
- `promptTooLongEndsOnce`: as given by the review.
- `AppCoreChatLoadTests`: `waitForLaunch` returns once `onLaunch()` ends; `selectModel` selects a downloaded model and refuses one that is not downloaded; `startRecording` and `stopRecording` start and stop a recording through AppCore.
- `test_analyze.py`: outcomes other than complete make the verdict undetermined, and complete outcomes let it pass; the model warning for a plan whose tag no loaded file carries, and none when one does or when no model loaded; reset descriptions after an answer, inside one, before one and after Stop; the table's reset row; an abort warning.
