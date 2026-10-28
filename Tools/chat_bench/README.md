# chat_bench

Tools for the meeting chat measurement (`specs/projects/meeting_chat/components/chat_measurement.md`). They measure chat beside the live transcript in Biscotti Dev while a recorded meeting plays.

- `plans/`: the measurement plans.
  - `baseline` asks nothing.
  - `concurrent-e2b` and `concurrent-12b` ask the same 8 questions, every 60 s from minute 2 of the recording. They differ in what happens to the AI model after each answer (see [Plans and models](#plans-and-models)).
  - `after-stop` asks 4 questions right after Stop.
- `analyze.py`: reads a capture of the unified log and writes `results/<run>.json` and `results/<run>.md`.
- `test_analyze.py`, `testdata/`: the analysis tests.

The load driver is in the app: `Packages/BiscottiKit/Sources/MeetingChat/Debug/ChatLoadDriver.swift`. It exists only in debug builds, and it runs only when the app starts with `-chatLoadTest <plan>`.

## Run one measurement

No step needs sudo. Run `log`, `open` and `pgrep` outside the agent sandbox: `log` does not run inside it.

1. Build Biscotti Dev from this branch with `Tools/development.sh build`. Make sure the AI model for the run is downloaded and selected in Settings.
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

5. Start a recording and open the live transcript drawer. Each question the driver asks opens the chat card in the drawer's place, so the "to drawn" live delay is measured only while the drawer shows: before the first question, or after the drawer is reopened. The contention rule does not use it, and the "to update" delay is measured throughout.
6. Play the live-bench soak fixture (`soak/mixed.wav`) through the speakers from its start.
7. Stop the recording after 15 minutes. For `after-stop`, the questions start at Stop.
8. Wait until the capture holds `plan-done` (`grep -c plan-done Tools/chat_bench/results/RUN.ndjson`). Then wait one more minute, so that the live session's "whole session" summary line is captured. Stop the capture with Ctrl-C.
9. Quit Biscotti Dev.
10. Analyze the capture:

    ```sh
    uv run Tools/chat_bench/analyze.py RUN --log Tools/chat_bench/results/RUN.ndjson
    ```

## Plans and models

The memory and contention figures must show what the Macs that use each model do. Below 24 GB the app recommends Gemma 4 E2B, and those Macs close the AI model after each answer during a recording. From 24 GB the app recommends Gemma 4 12B, and those Macs keep the model loaded between answers. This Mac (64 GB) would keep it loaded, so the E2B plan forces the close (`"closeModelAfterAnswer": true`).

| Run | Plan | Model selected in Settings |
|---|---|---|
| Baseline | `baseline.json` | Gemma 4 E2B |
| Concurrent, E2B | `concurrent-e2b.json` | Gemma 4 E2B |
| After Stop | `after-stop.json` | Gemma 4 E2B |
| Concurrent, 12B | `concurrent-12b.json` | Gemma 4 12B |
| Concurrent, Low Power Mode on | `concurrent-e2b.json` | Gemma 4 E2B |

Do the runs in this order, which is the component doc's order. The Low Power Mode run stands in for a slower chip, and slower Macs use E2B.

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
- an answer with no live status before its `done`, so its catch-up is unknown.

Two plans are normally undetermined, and that is not a capture fault:

- `baseline` asks nothing: "undetermined (no answers)".
- `after-stop` answers after Stop, when the live transcript is off: usually "undetermined (no live decode lines in the answer windows)". The live transcript finishes its last words for up to 10 s after Stop. If those decodes fall in the first answer's window, the result passes or fails on them alone. A watchdog reset at Stop also fails it: the watchdog acts only when a live session ends.

### Warnings

The table and the standard error output list problems with the capture. Each one means that some figures may be wrong or missing. Examples:

- the reasons above that make the rule undetermined;
- no `recording-started` line, so the memory figures cover the whole capture;
- lines from more than one Biscotti Dev process;
- a missing worker, or a worker whose memory was never read while it had to run;
- a model load without its broker line (info lines are missing);
- dropped messages, a capture line that did not decode, or fewer chunks or decodes than the live session counted.

The last capture line is often cut off when the capture is stopped with Ctrl-C. That warning alone is not a problem.

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
