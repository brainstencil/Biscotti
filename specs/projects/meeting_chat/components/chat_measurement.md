---
status: draft
---

# Component: Chat measurement

## Purpose and Scope

Measures chat beside the live transcript on real hardware, and sets `ChatResourcePolicy`'s thresholds from the results. It answers three questions from the functional spec: does an answer fit in memory beside the live transcript, does it slow the live text, and how fast are answers?

It runs in Biscotti Dev itself, so every real path is measured together: the transcriber worker, the LLM XPC service, the broker and the hold. That matches how the live transcript was validated, with a recorded meeting played through the speakers.

Not its job: quality of answers in general (the `make test-ai` chat test covers grounding on a fixed transcript), or the upstream PR. The load driver is a development tool and stays on the development branch, like the live transcript's debug launch options.

## Parts

1. **Load driver** (`MeetingChat/Debug/ChatLoadDriver.swift`, `#if DEBUG`), started by the launch argument `-chatLoadTest <plan.json>`.
   - **Plan:** it reads a plan with a forced policy mode (`concurrent` or `hold`), a start delay, an interval, and a list of questions.
   - **Asking:** once a recording starts, it asks the plan's questions through `MeetingChatService` at the interval, one at a time.
   - **Load log:** it writes one `Logger` line (category `chat-load`) per event: ask, lease start, first token, done, hold start and release, with the prompt token count, context size, `isPartial`, and the outcome.
   - **Memory sampling:** every second it samples the physical footprint (`proc_pid_rusage`, `RUSAGE_INFO_V4`, `ri_phys_footprint`) of the app, `BiscottiTranscriber` and `BiscottiLLM`, finding their PIDs by bundle identifier, and logs them.
   - **Driver-only override:** a `ChatResourcePolicy.override(mode:)` used only by the driver.
2. **Plans** (`Tools/chat_bench/plans/*.json`):
   - `baseline`: no questions.
   - `concurrent`: 8 questions, every 60 s, from minute 2.
   - `hold`: the same, in hold mode.
   - `after-stop`: 4 questions asked right after Stop, while the final transcript is made.
   - **Question set:** questions written for the soak fixture's content. They mix "what did they decide about X", "what did Y say about Z", "list the action items so far" and one question whose answer is not in the meeting.
3. **Analysis** (`Tools/chat_bench/analyze.py`, run with `uv`).
   - **Inputs:** it reads `log show --predicate 'subsystem == "net.scosman.biscotti"' --info` for the run's time range. It joins the `chat-load` lines with the live transcript's existing latency lines (`LiveRecordingSession` latency signposts, chunk taken to text shown).
   - **Outputs:** it writes `results/<run>.json` and one Markdown table per run, with:
     - Peak and median footprint per process, and their sum.
     - Live delay (median and 95th percentile) inside answer windows (lease start to done) and outside them.
     - Time to first token, cold (first question, model loading) and warm (later questions), and tokens per second after it.
     - In hold mode, catch-up time after each release: from release until the store reports `.live` again.
     - Citation validity: the share of cited times that became chips.
     - Answers that failed or were partial.

## Procedure

On the M1 Max (64 GB), with Biscotti Dev built from this branch and the AI model (Gemma 4 E2B) downloaded:

1. Start Biscotti Dev with the plan's launch argument.
2. Start a recording. Play the live-bench soak fixture (`soak/mixed.wav`, 45 minutes) through the speakers from the start, as in the live transcript's hardware validation.
3. Let the plan run. Stop the recording after 15 minutes (`after-stop`: Stop at 15 minutes, then the plan asks).
4. Run `analyze.py` for the run's time range.

Order: `baseline`, `concurrent`, `hold`, `after-stop`. Repeat `concurrent` with Gemma 4 12B selected, since 24 GB Macs and up use it.

## Decision Rule

**Memory budget per tier:** the Mac's memory minus 5 GB, for macOS, the call app and a browser. That gives 3 GB on 8 GB Macs, 11 GB on 16 GB and 19 GB on 24 GB. On an 8 GB or 16 GB Mac this is an estimate; a single run on such a Mac, if one is available, replaces it.

For each tier, with that tier's model:
- **Concurrent** if the summed peak footprint in the `concurrent` run fits the tier's budget, **and** the 95th-percentile live delay inside answer windows is at most 1.5× the baseline's.
- Otherwise **hold**, if the summed peak in the `hold` run fits the budget **and** the median catch-up after release is under 30 s.
- Otherwise **wait for Stop**.

The results set `concurrentMinimumMemory` and `waitForStopMaximumMemory` in `ChatResourcePolicy`, replacing the defaults. They are recorded in `specs/projects/meeting_chat/research/chat_measurement/README.md`, with the tables, the hardware and the model versions.

## Test Plan

- `ChatLoadDriverTests` (`MeetingChatTests`, DEBUG):
  - `planParses`: the four plans decode.
  - `driverAsksOnSchedule`: with a test clock and a scripted model, the driver asks at the plan's times and never while an answer runs.
  - `overrideForcesMode`: the plan's mode overrides the policy.
- `Tools/chat_bench/test_analyze.py` (pytest through `uv run`): parses a recorded log excerpt into the expected windows, latencies and catch-up times.
