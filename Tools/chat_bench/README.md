# chat_bench

Tools for the meeting chat measurement (`specs/projects/meeting_chat/components/chat_measurement.md`). They measure chat beside the live transcript in Biscotti Dev while a recorded meeting plays.

- `plans/`: the measurement plans.
  - `baseline` asks nothing.
  - `concurrent-e2b` and `concurrent-12b` ask the same 8 questions, every 60 s from minute 2 of the recording. They differ in what happens to the AI model after each answer (see [Plans and models](#plans-and-models)).
  - `after-stop` asks 4 questions right after Stop.
- `run.sh`: runs one measurement with nobody at the Mac, from the app's start to the analysis.
- `analyze.py`: reads a capture of the unified log and writes `results/<run>.json` and `results/<run>.md`.
- `test_analyze.py`, `testdata/`: the analysis tests.

The load driver is in the app: `Packages/BiscottiKit/Sources/MeetingChat/Debug/ChatLoadDriver.swift`. It exists only in debug builds, and it runs only when the app starts with `-chatLoadTest <plan>`.

## Run one measurement with `run.sh`

Build Biscotti Dev from this branch with `make build-development`. The AI models the plans name must be downloaded; the plan selects its model. When another branch also builds Biscotti Dev, build into a folder of your own, so that the other build cannot replace it. `run.sh` runs the app in the same folder (`BISCOTTI_DEV_APP` overrides the app's path):

```sh
export BISCOTTI_DEV_DERIVED_DATA=/Volumes/Data/projects/Developer/biscotti/DerivedData/Development-meeting-chat
make build-development
```

A new build has a new ad-hoc signature, so macOS asks again for the microphone and system-audio permissions at its first recording. Then:

```sh
Tools/chat_bench/run.sh concurrent-e2b concurrent-e2b
```

The first argument names the result files; the second is a plan's name in `plans/` or a path to a plan. The script refuses a name whose capture (`results/RUN.ndjson`) already exists: move the old capture first. A run takes about 17 minutes (`after-stop` a few more). The script does steps 2 to 10 below:

- It stops if production Biscotti runs: it never quits it. It quits Biscotti Dev and waits until no process of its bundle runs.
- It starts the capture into `results/RUN.ndjson`, waits 2 s, and starts Biscotti Dev with the plan's absolute path.
- The app's launch counts as done once no speech model has been prepared for 3 s. A new build, or a Core ML cache that macOS purged under low disk space, compiles the speech models for minutes first; a recording started meanwhile would hold its live transcript until the live model's compile ends, which is not what a user who opens the app ahead of a meeting sees. The driver then selects the plan's model, writes its `plan` line, and starts the recording itself 10 s later (the plan's `record`). The script waits up to 20 minutes for the `plan` line.
- Once the capture holds `recording-started`, the script plays `soak/mixed.wav` with `afplay`, at the current volume and output device. If no recording starts within 90 s of the `plan` line, it stops: a permission prompt may be waiting, and the script answers none.
- The app stops the recording after 15 minutes and writes `plan-done` once the recording has stopped and the plan's questions are answered. The script waits one more minute, stops the playback and the capture, quits Biscotti Dev, and runs `analyze.py`.
- It stops early, with exit status 2, when the driver writes an `abort` line, the app's driver cannot record (its `plan` line has no `record=`: an older build), Biscotti Dev quits, production Biscotti starts, or `plan-done` has not come 35 minutes after the `plan` line. Exit status 1 means it could not start, and 3 that the analysis failed.

Nobody opens the live transcript drawer in such a run, so the "to drawn" live delay may have no chunks (see step 5). Run the script outside the agent sandbox, because `log` does not run inside it. No step needs sudo.

## Run one measurement by hand

No step needs sudo. Run `log`, `open` and `pgrep` outside the agent sandbox: `log` does not run inside it. With a plan that has a `record` block (all four plans have one), the app starts and stops the recording itself: skip the recording in steps 5 and 7.

1. Build Biscotti Dev from this branch with `Tools/development.sh build`. Make sure the AI model for the run is downloaded. A plan with a `model` selects it; otherwise select it in Settings.
2. Quit Biscotti Dev, and Biscotti if it runs. Make sure that this command prints nothing:

   ```sh
   pgrep -fl 'Biscotti Dev.app'
   ```

   A copy that still runs keeps its workers: their memory is added to the run's figures, and their log lines cannot be told apart from the run's lines.
3. Start the capture. The driver writes its plan and worker lines when the app starts, so the capture must start first.

   ```sh
   mkdir -p Tools/chat_bench/results
   /usr/bin/log stream --style ndjson --level info \
     --predicate 'subsystem == "net.scosman.biscotti" AND processImagePath CONTAINS "Biscotti Dev.app"' \
     > Tools/chat_bench/results/RUN.ndjson
   ```

   Replace `RUN` with the run's name, for example `concurrent-e2b`. To stop the capture automatically, add `--timeout 30m`; if the run is not finished by then, the result is undetermined.
4. Wait 2 seconds, so that `log stream` is attached. Then start the app with the plan. The path must be absolute, because an app that `open` starts runs in `/`.

   ```sh
   open "/Volumes/Data/projects/Developer/biscotti/DerivedData/Development/Build/Products/Debug/Biscotti Dev.app" \
     --args -chatLoadTest "$PWD/Tools/chat_bench/plans/concurrent-e2b.json"
   ```

   If you built with `BISCOTTI_DEV_DERIVED_DATA`, use `$BISCOTTI_DEV_DERIVED_DATA/Build/Products/Debug/Biscotti Dev.app` instead.

5. Start a recording and open the live transcript drawer. Each question the driver asks opens the chat card in the drawer's place, so the "to drawn" live delay is measured only while the drawer shows: before the first question, or after the drawer is reopened. The contention rule does not use it, and the "to update" delay is measured throughout.
6. Play the live-bench soak fixture (`soak/mixed.wav`) through the speakers from its start.
7. Stop the recording after 15 minutes. For `after-stop`, the questions start at Stop.
8. Wait until the capture holds `plan-done` (`grep -c plan-done Tools/chat_bench/results/RUN.ndjson`). Then wait one more minute, so that the live session's "whole session" summary line is captured. Stop the capture with Ctrl-C.
9. Quit Biscotti Dev.
10. Analyze the capture:

    ```sh
    uv run Tools/chat_bench/analyze.py RUN --log Tools/chat_bench/results/RUN.ndjson
    ```

## Plan fields

| Field | Meaning |
|---|---|
| `name` | The plan's name, in the `plan` line. `analyze.py` warns when a name with `e2b` or `12b` loaded no model file with that tag. |
| `mode` | `concurrent` or `waitForStop`, forced on the resource policy for the run. |
| `model` | Optional. The catalog model to select, as Settings does (`gemma-4-e2b`, `gemma-4-12b`). It changes the development data's model setting. If the model is not downloaded, the plan aborts. |
| `record` | Optional. `startAfterSeconds`: from the end of the app's launch (and of its speech models' preparation) to Record. `durationSeconds`: from the recording's start to Stop. The app records through the Record and Stop buttons' paths. The plan aborts if the live transcript is off or its model is missing, or if no recording starts. |
| `closeModelAfterAnswer` | Optional. Forces whether the model closes after each answer during a recording. |
| `startAfter` | `recordingStart` or `recordingStop`: the event that starts the questions' clock. |
| `startDelaySeconds`, `intervalSeconds` | When the first question is due after that event, and the time between two questions' due times. |
| `questions` | The questions, asked one at a time. |

The driver writes its `plan` line once the app's launch is done, with the active model's file (`model=`), the recording (`record=` start delay+duration) and whether a recording gets a live transcript (`live=on`). A plan that cannot run writes `abort reason=` (`modelNotSelected`, `liveTranscriptOff`, `liveModelMissing`, `recordingDidNotStart`, `noAppControls`) and no `plan-done`.

## Plans and models

The memory and contention figures must show what the Macs that use each model do. Below 24 GB the app recommends Gemma 4 E2B, and those Macs close the AI model after each answer during a recording. From 24 GB the app recommends Gemma 4 12B, and those Macs keep the model loaded between answers. This Mac (64 GB) would keep it loaded, so the E2B plan forces the close (`"closeModelAfterAnswer": true`).

| Run | Plan | Model (the plan's `model`) |
|---|---|---|
| Baseline | `baseline.json` | Gemma 4 E2B |
| Concurrent, E2B | `concurrent-e2b.json` | Gemma 4 E2B |
| After Stop | `after-stop.json` | Gemma 4 E2B |
| Concurrent, 12B | `concurrent-12b.json` | Gemma 4 12B |
| Concurrent, Low Power Mode on | `concurrent-e2b.json` | Gemma 4 E2B |

Do the runs in this order, which is the component doc's order. The Low Power Mode run stands in for a slower chip, and slower Macs use E2B. Name a Low Power Mode run with `lowpower` (for example `lowpower-e2b`): the analysis then warns if the live transcript updated every second, which means Low Power Mode was off.

## Why `log stream`

- `log stream` keeps every line for the whole run, and it needs no sudo. It does not carry signposts.
- Without a logging configuration, macOS keeps info lines only briefly. Signposts that are not persisted are readable with `log show` for a few minutes only.
- For this reason, debug builds write the live transcript's figures as info lines in the `live.latency` category, in addition to the existing signposts:
  - each update's decode time (`decode ms=`);
  - each chunk's delay to its update and to its drawing (`chunks to=update|drawn s=`);
  - the chunks that are never measured (`chunks dropped=`).

## Alternative: the log store (needs sudo)

Persist the subsystem's info lines once. This also keeps its signposts, for Instruments; the analysis does not read signposts:

```sh
sudo log config --subsystem net.scosman.biscotti --mode "level:info,persist:info,signpost-persisted:on"
```

Then read the run's time range from the log store:

```sh
uv run Tools/chat_bench/analyze.py RUN --start '2026-10-29 10:00:00' --end '2026-10-29 10:20:00'
```

The script saves the `log show` output as `results/RUN.ndjson` first.

## Read the result

### Contention rule

The result is "passes", "fails" or "undetermined". Do not take an undetermined result as a pass. It is undetermined when the run ended early or a figure the rule needs is missing:

- no `plan` line (the capture started after the app), or no `plan-done` line;
- fewer questions asked, skipped or not sent than the plan has;
- a question with no `done` line (the app quit, or the capture ended early);
- no live status lines in the capture;
- no decode lines inside the answer windows;
- an answer with no live status before its `done`, so its catch-up is unknown;
- an answer that ended stopped or failed: "question 4 failed (<error>)". The driver never presses the chat's Stop, so such an answer is a fault in the run.

Two plans are normally undetermined, and that is not a capture fault:

- `baseline` asks nothing: "undetermined (no answers)".
- `after-stop` answers after Stop, when the live transcript is off: usually "undetermined (no live decode lines in the answer windows)". The live transcript finishes its last words for up to 10 s after Stop. If those decodes fall in the first answer's window, the result passes or fails on them alone. A watchdog reset at Stop also fails it: the watchdog acts only when a live session ends.

### Live text

The rule does not use these rows. They show whether the live text lost anything:

- **Live gaps**: audio missing from the live text, from each live session's end line. The saved transcript still has it.
- **Rejected live updates** and **Live finish after Stop**: text the live transcript could not keep.
- **Live update interval**: from the speech worker. It is 2 s in Low Power Mode and 1 s otherwise.

### Warnings

The table and the standard error output list problems with the capture. Each one means that some figures may be wrong or missing. Examples:

- the first three reasons above that make the rule undetermined (the run ended early); the others show only in the contention row;
- no `recording-started` line, so the memory figures cover the whole capture;
- an `abort` line: the plan could not run;
- a plan whose name says `e2b` or `12b` while the run loaded another model;
- a run named `lowpower…` whose live transcript updated every second;
- answers the driver did not ask: someone used the chat in the app during the run;
- lines from more than one Biscotti Dev process;
- a missing worker, or a worker whose memory was never read while it had to run;
- a model load without its broker line (info lines are missing);
- dropped messages, a capture line that did not decode, or fewer chunks or decodes than the live session counted.

The last capture line is often cut off when the capture is stopped with Ctrl-C. That warning alone is not a problem.

### Watchdog resets

Every reset in the capture counts, and the table places each one: "at 14:58, 312 s after q8's done". The time is from the recording's start. "N s after Stop" follows when the reset came after Stop, then where it fell against the nearest answer: inside it, before its lease (or its ask, when it never got the model), or after its `done`. The watchdog acts only when a live session ends, so a reset at Stop is not an answer's doing, but the rule still counts it.

### Memory

The memory figures and the model-load count cover the recording only: from the driver's `recording-started` line to its `recording-stopped` line. After Stop, the final pass and the summary use memory whether or not anyone asks a question, so they are not part of the rule. The table shows the rule's figure after Stop on its own row, for reference.

The sampler records two figures per process, every second:

- The **footprint** is what Activity Monitor shows as Memory. It leaves out the model weights, which llama.cpp maps from the GGUF file.
- The **resident size** includes those weights. It also includes the shared system libraries, once in each process, so the summed resident size overstates.

The memory rule uses neither sum. It uses the footprints' sum plus the AI worker's resident size minus its footprint: the mapped weights, counted once. The table shows this figure as "Memory for the rule", and compares its peak with each tier's budget (the Mac's memory minus 5 GB).

Use the budget rows that match the run's model. The table marks them "this run's model":

| Plan | Model | Budget rows that apply |
|---|---|---|
| `concurrent-e2b` | Gemma 4 E2B | 8 GB Mac (3 GB) and 16 GB Mac (11 GB): Macs under 24 GB use E2B |
| `concurrent-12b` | Gemma 4 12B | 24 GB Mac (19 GB): Macs with 24 GB or more use 12B |

After the first model load, also compare the AI worker's resident size minus its footprint with the GGUF file's size. They should be close.

### Live delay

Chunks that are more than 64 s behind, or that belong to an engine that was replaced, are never measured. The table counts them as "Live chunks not measured". Under heavy contention, many of them make the live delay's p95 too low. The contention rule does not use p95.

`results/*.ndjson` captures are large, and git ignores them. The `.json` and `.md` results can be committed with the research notes.

## Tests

```sh
uv run --with pytest pytest Tools/chat_bench
```

The driver's tests are `ChatLoadDriverTests` in `Packages/BiscottiKit/Tests/MeetingChatTests`.
