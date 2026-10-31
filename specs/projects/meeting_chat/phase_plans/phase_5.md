---
status: complete
---

# Phase 5: Measurement tools

## Overview

Builds the tools of [chat_measurement](../components/chat_measurement.md): the DEBUG `ChatLoadDriver` that asks a plan's questions through `MeetingChatService` during a recording and logs each answer's milestones and the three processes' memory, the three plans, and `Tools/chat_bench/analyze.py`, which joins the driver's lines with the live transcript's and the broker's log lines and writes one result per run. Nothing is measured in this phase (phase 6 runs it on hardware).

The live transcript's logs hold no per-decode duration: decode times reach the app in each update (`LiveTrackUpdate.decodeMilliseconds`) but are only logged as 5-minute summaries. The decision rule needs the longest single decode inside answer windows, so `LiveLatency` gains one `Decode` signpost event per update, beside its existing `Live chunk` signposts. This is in `BiscottiKit/LiveTranscriptionService`, not `Packages/Transcription`, so no manual tests are reset.

## Steps

1. **Service milestones** (`MeetingChat`).
   - New `ChatLoadEvent.swift`: `enum ChatLoadEvent { recordingStarted(meetingID:), recordingStopped(meetingID:), leaseStarted(AnswerRun, loadingModel: Bool), firstToken(AnswerRun), ended(AnswerRun) }` and `MeetingChatService.report(_:)`, which calls `loadObserver` in DEBUG builds and does nothing in release builds.
   - `MeetingChatService`: `#if DEBUG @ObservationIgnored var loadObserver: (@MainActor (ChatLoadEvent) -> Void)?`; `policy` becomes `@ObservationIgnored var` so the driver can force its mode; `stopwatch(on:)` becomes internal for the driver.
   - Reports: `recordingDidStart()` (the recording meeting), `recordingDidStop(meetingID:)`, `apply(.loadingModel)` (`loadingModel: true`), the lease body's start (`loadingModel: false`), the first `.token` in `read` (`AnswerRun.tokenCount` counts tokens), and `end(_:)` (every ended run: finished, stopped while waiting, or discarded).

2. **`MeetingChat/Debug/ChatLoadPlan.swift`** (`#if DEBUG`):
   - `public struct ChatLoadPlan: Decodable`: `name`, `mode` (`concurrent` | `waitForStop`), `startAfter` (`recordingStart` | `recordingStop`), `startDelaySeconds`, `intervalSeconds`, `questions`; `dueTime(ofQuestion:) -> Duration`; `load(from: URL)`; `path(in arguments:)` reads the value after `-chatLoadTest`.
   - `ChatResourcePolicy.override(mode:) -> ChatResourcePolicy`: sets `waitForStopMaximumMemory` to `.max` or `0`, so `mode()` returns the forced mode on any Mac.

3. **`MeetingChat/Debug/FootprintSampler.swift`** (`#if DEBUG`): `ProcessFootprints` (app, transcriber, llm; bytes, nil when not running) and `FootprintSampler`.
   - `forApp(_ bundle: Bundle = .main)`: finds the XPC services in `Contents/XPCServices` whose bundle identifiers are the app's plus `.BiscottiTranscriber` and `.BiscottiLLM`, and keeps their executable paths.
   - `sample()`: lists all PIDs (`proc_listallpids`), matches `proc_pidpath` against those paths, and sums each worker's `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint`; the app is `getpid()`.

4. **`MeetingChat/Debug/ChatLoadDriver.swift`** (`#if DEBUG`), `@MainActor public final class ChatLoadDriver`:
   - `init(plan:chat:clock:)`; `start(sampler: FootprintSampler?)` forces the plan's mode on `chat.policy`, installs `chat.loadObserver`, logs the plan, starts the schedule task and, with a sampler, a detached task that logs footprints every second; `stop()` cancels both.
   - `public static func startIfRequested(chat:arguments:)` reads `-chatLoadTest <plan.json>`, starts a driver with `FootprintSampler.forApp()` and keeps it for the app's life (a static).
   - Schedule: wait for the plan's start event (recording start or stop) and take its meeting; for each question, sleep until `start + dueTime`, wait for any running answer to end, skip with the reason if chat is not available, otherwise put the question in the meeting's draft, `ask`, and wait for the answer's `.ended`. One question at a time, so a question whose time comes while an answer runs waits for it.
   - Log lines, `Logger(subsystem: "net.scosman.biscotti", category: "chat-load")`, `.notice`, all values public: `plan name= mode= startAfter= delay= interval= questions=`, `recording-started`, `recording-stopped`, `ask q= t=`, `skip q= reason=`, `not-sent q=`, `lease q= loading=`, `first-token q=`, `done q= outcome= promptTokens= context= partial= tokens= cited= linked= [error=<message>]`, `plan-done`, `memory app= transcriber= llm=` (MiB, `-` when not running).
   - `ChatLoadResult`: one answer's figures from its `AnswerRun` (outcome from the final view state, prompt tokens, context size, `isPartial`, token count, cited and linked times); `citations(in:evidenceTimes:)` counts bracketed times and those the parser links.
   - Internal `askTimes` and `results` for tests.

5. **AppCore**: `AppCore.live` calls `ChatLoadDriver.startIfRequested(chat: core.chat)` under `#if DEBUG`.

6. **`LiveLatency.updateApplied`**: emit a `Decode` signpost event ("812 ms") for each update with `decodeMilliseconds`; the type's doc lists it.

7. **Plans** (`Tools/chat_bench/plans/`): `baseline.json` (no questions), `concurrent.json` (8 questions, from 120 s after the recording starts, every 60 s), `after-stop.json` (4 questions right after Stop, one after another). Questions are written for the soak fixture's first 15 minutes (AMI TS3006d: shape, buttons, speech recognition, scroll-wheel, power source, special colour), mixing "what did they decide about X", "what did I say about Z" (the mic speaker is "Me"), "list the action items so far", and one question whose answer is not in the meeting.

8. **`Tools/chat_bench/analyze.py`** (stdlib only, inline `uv` script metadata):
   - `analyze.py RUN (--start S --end E | --log FILE) [--out DIR] [--process "Biscotti Dev.app"]`. Without `--log` it runs `/usr/bin/log show --style ndjson --info --signpost` with the predicate `subsystem == "net.scosman.biscotti" AND processImagePath CONTAINS <process>`, and saves the raw output as `results/<RUN>.ndjson` (git-ignored) so the run can be analyzed again after the log store rotates.
   - Parses: `chat-load` lines; `llm-broker` "Model opened:" and "Closing model connection:"; `live` "Live status: …", "A live decode has not returned" (watchdog reset) and "Restarting the live engine"; `live.latency` signposts "Live chunk" (begin, "Covered" event, end with or without reason) and "Decode".
   - Computes: answer windows (lease, or ask when there was no lease, to done); per process and summed footprint peak and median, and whether the summed peak fits each tier's budget (3, 11 and 19 GB); live delay (chunk taken to drawn, or to the covering update when not drawn) median and p95 inside and outside windows, by the chunk's taken time; longest decode overlapping a window and outside them; watchdog resets and engine restarts; catch-up after each answer (if catching up at done, the time to the next "live", otherwise 0; never caught up → null); time to first token cold (the lease loaded the model, or a model opened between ask and first token) and warm; tokens per second after the first token; citation validity; failed and partial answers; model loads and closes; the contention rule's verdict.
   - Writes `results/<RUN>.json` and `results/<RUN>.md` (one Markdown table) and prints the table. Refuses a range holding more than one plan.
   - `.gitignore`: `Tools/chat_bench/results/*.ndjson`.

## Tests

`MeetingChatTests/ChatLoadDriverTests.swift` (`#if DEBUG`), through `ChatHarness`:
- `planParses`: the three plan files decode with their names, modes, start events, timings and question counts; a plan path is read from the launch arguments, and none without the argument.
- `driverAsksOnSchedule`: with a test clock for the driver and a test clock holding the first answer's tokens, the questions are asked at 2 s, then at 6 s (due at 5 s, but the first answer ran until 6 s), then at 8 s; the stored thread holds all three questions with complete answers, so none was asked while an answer ran.
- `driverRecordsAnswerFigures`: one answered question yields a `done` result with outcome, prompt tokens, context size, token count and citation counts.
- `afterStopPlanStartsAtStop`: a plan that starts after Stop asks nothing during the recording and asks once `recordingDidStop` is reported, answering from the draft.
- `unavailableQuestionIsSkipped`: with the live transcript off during the recording, the question is skipped, not asked.
- `overrideForcesMode`: `override(mode:)` forces `.concurrent` on a Mac that waits and `.waitForStop` on one that does not; a driver with a `waitForStop` plan parks a question asked during the recording.
- `citationCounts`: bracketed times, groups and ranges are counted, and only those near evidence count as linked.
- `footprintSamplerReadsThisProcess`: this process's footprint is read, and the sampler finds this process by its executable path.

`Tools/chat_bench/test_analyze.py` (pytest through `uv run --with pytest`), on a recorded log excerpt (`Tools/chat_bench/testdata/excerpt.ndjson`):
- answer windows, cold and warm time to first token, tokens per second;
- live delay inside and outside windows (drawn, covered-only and unmeasured chunks);
- longest decode inside and outside windows; watchdog reset and engine restart counts;
- catch-up times (zero, a measured catch-up, never caught up);
- memory peaks, medians, sums and budgets; model loads; citation validity; failed and partial counts; the contention verdict;
- a range with two plans is refused; lines from another process are ignored; the Markdown table lists every measure.
