# Chat measurement

Results of the chat measurement ([components/chat_measurement.md](../../components/chat_measurement.md)), run in phase 6 on 28 October 2026. Chat answered questions in Biscotti Dev while the live transcript ran beside a recording of the soak fixture, played through the speakers. The tools and the procedure are in `Tools/chat_bench` (`README.md`). Each run's files are in `Tools/chat_bench/results`: `<run>.json` and `<run>.md` are committed, and the `.ndjson` captures are git-ignored.

## Summary

- **Contention: the default fails on the Low Power Mode run.** That run stands in for a slower chip. One live decode inside an answer took 5.16 s, over the rule's 5 s limit, so the contention rule fails, and phase 7 (the live hold, and the higher-watchdog-limit remedy) applies. There was no watchdog reset, and the live transcript caught up at once after every answer. At normal power both concurrent runs pass: `concurrent-e2b` (longest decode in an answer 3.25 s) and `concurrent-12b` (2.83 s), with no reset and a catch-up of 0 s after every answer.
- **Memory:** 16 GB Macs (E2B) and 24 GB Macs (12B) fit their budgets with room to spare, so chat runs during recordings there. 8 GB Macs (E2B) peaked at 2.96 GB against a 3 GB budget. That passes the rule by 0.04 GB, less than the figure's known error.
- **Thresholds, proposed for the user's review:** `ChatResourcePolicy.waitForStopMaximumMemory` is 8 GB (it was 0), so 8 GB Macs answer after Stop. This departs from the rule, which would let them answer during recordings; see [Memory against each tier's budget](#memory-against-each-tiers-budget). `closeAfterAnswerBelowMemory` stays at 24 GB.
- **Not run here:** `make test-ai`, which is for the user.

## Hardware and software

| | |
|---|---|
| Mac | MacBook Pro (MacBookPro18,2), Apple M1 Max, 10 CPU cores (8 performance, 2 efficiency), 32 GPU cores, 64 GB |
| macOS | 26.6.2 (25G83). Power mode automatic (Low Power Mode off), except for the Low Power Mode run, where the user turned it on (`pmset` powermode 1) |
| Builds | Biscotti Dev, debug, from `codex/meeting-chat` at 8863826 plus this phase's changes. `baseline` and `concurrent-e2b` ran the 14:55 build in `DerivedData/Development`. The other runs ran a 17:5x build in `DerivedData/Development-meeting-chat`, after another branch's build replaced the first one. The second build adds only the 8 GB policy default, which the plans override |
| Speech | Live transcript: `openai_whisper-small`. Final pass: `openai_whisper-large-v3-v20240930_626MB` |
| AI models | `gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf`, 2,620,370,976 bytes (SHA-256 `e531007218dfab99…`). `gemma-4-12b-it-UD-Q4_K_XL.gguf`, 7,366,423,360 bytes (SHA-256 `90fd944d227e9d9b…`) |
| Fixture | `live_bench/fixtures/soak/mixed.wav` (AMI TS3006d), played with `afplay` at the current volume and output device. The recording stops after 15 minutes |
| Disk | The startup disk had 7.2 GB free. The app reported that "the final pass's model load is slow and the disk is low on space", and the speech models were compiled again after each new build |

"GB" in the tables means GiB (2^30 bytes), as in `analyze.py`.

## Runs

| Run | Model | Contention rule | Rule's memory peak (recording) | Longest decode in answers | Catch-up | Resets |
|---|---|---|---|---|---|---|
| `baseline` | none loaded | undetermined (no answers), as expected | 0.27 GB | – (outside answers: 4.76 s) | – | 0 |
| `concurrent-e2b` | E2B, closed after each answer | **passes** | 2.96 GB | 3.25 s | 0 s after each | 0 |
| `lowpower-e2b` (Low Power Mode on, plan `concurrent-e2b`) | E2B, closed after each answer | **fails**: a decode inside an answer took 5.16 s | 3.04 GB | 5.16 s | 0 s after each | 0 |
| `after-stop` | E2B | undetermined (no live decode lines in the answer windows), as expected | 0.25 GB (no model during the recording) | – | 0 s after each | 0 |
| `concurrent-12b` | 12B, kept loaded | **passes** | 9.78 GB | 2.83 s | 0 s after each | 0 |

Every run asked all of its questions. Every answer completed, none was partial, and no warning was raised.

### baseline

| Measure | Value |
|---|---|
| Plan | baseline, mode concurrent, model closed after each answer: as this Mac's policy |
| Questions asked | 0 of 0 |
| Model loads | 0 during the recording, 0 outside it: no model file named (closes: none) |
| Memory during the recording, app | footprint peak 0.17 GB, median 0.11 GB; resident peak 0.27 GB, median 0.21 GB |
| Memory during the recording, speech worker | footprint peak 0.12 GB, median 0.09 GB; resident peak 0.16 GB, median 0.10 GB |
| Memory during the recording, AI worker | footprint peak –, median –; resident peak –, median – |
| Memory during the recording, sum | footprint peak 0.27 GB, median 0.22 GB; resident peak 0.38 GB, median 0.35 GB |
| Memory for the rule (footprints + AI worker's mapped weights) | peak 0.27 GB, median 0.22 GB |
| Same figure after Stop (final pass and summary; not for the rule) | peak 0.60 GB, median 0.59 GB |
| Rule figure's peak against budgets | 8 GB Mac, E2B (3 GB): fits; 16 GB Mac, E2B (11 GB): fits; 24 GB Mac, 12B (19 GB): fits |
| Live delay inside answers, to drawn | no chunks |
| Live delay outside answers, to drawn | median 1.3 s, p95 2.6 s (2022 chunks) |
| Live delay inside answers, to update | no chunks |
| Live delay outside answers, to update | median 0.8 s, p95 2.2 s (7185 chunks) |
| Live chunks not measured | none |
| Longest live decode inside answers | – |
| Longest live decode outside answers | 4.76 s |
| Watchdog resets | 0 |
| Live engine restarts / failures | 0 / 0 |
| Catch-up after answers | median –; per answer (s): – |
| Time to first token, cold | – |
| Time to first token, warm | median – (0 answers) |
| Tokens per second | – |
| Citation validity | 0 of 0 |
| Failed / partial answers | 0 failed, 0 partial |
| Warnings | none |
| Contention rule | undetermined (no answers) |

### concurrent-e2b

| Measure | Value |
|---|---|
| Plan | concurrent-e2b, mode concurrent, model closed after each answer: yes |
| Questions asked | 8 of 8 |
| Model loads | 8 during the recording, 0 outside it: gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf (closes: lease ended 8) |
| Memory during the recording, app | footprint peak 0.16 GB, median 0.10 GB; resident peak 0.21 GB, median 0.16 GB |
| Memory during the recording, speech worker | footprint peak 0.11 GB, median 0.08 GB; resident peak 0.12 GB, median 0.09 GB |
| Memory during the recording, AI worker | footprint peak 0.34 GB, median 0.26 GB; resident peak 2.76 GB, median 2.65 GB |
| Memory during the recording, sum | footprint peak 0.55 GB, median 0.18 GB; resident peak 3.01 GB, median 0.26 GB |
| Memory for the rule (footprints + AI worker's mapped weights) | peak 2.96 GB, median 0.18 GB |
| Same figure after Stop (final pass and summary; not for the rule) | peak 0.40 GB, median 0.27 GB |
| Rule figure's peak against budgets | 8 GB Mac, E2B (3 GB): fits (this run's model); 16 GB Mac, E2B (11 GB): fits (this run's model); 24 GB Mac, 12B (19 GB): fits |
| Live delay inside answers, to drawn | no chunks |
| Live delay outside answers, to drawn | median 1.3 s, p95 2.5 s (441 chunks) |
| Live delay inside answers, to update | median 1.0 s, p95 2.8 s (841 chunks) |
| Live delay outside answers, to update | median 0.8 s, p95 2.1 s (6345 chunks) |
| Live chunks not measured | none |
| Longest live decode inside answers | 3.25 s |
| Longest live decode outside answers | 4.75 s |
| Watchdog resets | 0 |
| Live engine restarts / failures | 0 / 0 |
| Catch-up after answers | median 0.0 s; per answer (s): 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 |
| Time to first token, cold | 6.4 s, 2.8 s, 5.3 s, 8.6 s, 11.1 s, 11.5 s, 11.7 s, 13.1 s |
| Time to first token, warm | median – (0 answers) |
| Tokens per second | median 51.9 |
| Citation validity | 49 of 49 (100%) |
| Failed / partial answers | 0 failed, 0 partial |
| Warnings | none |
| Contention rule | passes |

Per answer, with times in seconds after the recording started. Every answer loaded the model, because the plan closes it after each one, as on Macs under 24 GB:

| Question | Asked | Window | Prompt tokens | Context | Time to first token | Tokens per second | Cited / linked |
|---|---|---|---|---|---|---|---|
| 1 | 120 | 10.2 s | 751 | 4,096 | 6.4 s | 64.1 | 6 / 6 |
| 2 | 180 | 4.2 s | 1,227 | 4,096 | 2.8 s | 86.6 | 4 / 4 |
| 3 | 240 | 8.7 s | 1,610 | 4,096 | 5.3 s | 53.9 | 4 / 4 |
| 4 | 300 | 19.6 s | 2,034 | 4,096 | 8.6 s | 50.6 | 10 / 10 |
| 5 | 360 | 13.1 s | 2,728 | 8,192 | 11.1 s | 35.3 | 2 / 2 |
| 6 | 420 | 22.4 s | 3,026 | 8,192 | 11.5 s | 46.8 | 19 / 19 |
| 7 | 480 | 14.1 s | 3,686 | 8,192 | 11.7 s | 53.3 | 4 / 4 |
| 8 | 540 | 13.9 s | 3,837 | 8,192 | 13.1 s | 32.1 | 0 / 0 |

The model loads took 1.4 to 6.7 s. The AI worker's resident size minus its footprint (the mapped weights) peaked at 2.44 GB, the GGUF file's size.

### lowpower-e2b

The `concurrent-e2b` plan, with Low Power Mode on.

| Measure | Value |
|---|---|
| Plan | concurrent-e2b, mode concurrent, model closed after each answer: yes |
| Questions asked | 8 of 8 |
| Model loads | 8 during the recording, 0 outside it: gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf (closes: lease ended 8) |
| Memory during the recording, app | footprint peak 0.17 GB, median 0.13 GB; resident peak 0.23 GB, median 0.19 GB |
| Memory during the recording, speech worker | footprint peak 0.12 GB, median 0.08 GB; resident peak 0.16 GB, median 0.10 GB |
| Memory during the recording, AI worker | footprint peak 0.35 GB, median 0.32 GB; resident peak 2.79 GB, median 2.75 GB |
| Memory during the recording, sum | footprint peak 0.61 GB, median 0.21 GB; resident peak 3.12 GB, median 0.30 GB |
| Memory for the rule (footprints + AI worker's mapped weights) | peak 3.04 GB, median 0.21 GB |
| Same figure after Stop (final pass and summary; not for the rule) | peak 0.43 GB, median 0.30 GB |
| Rule figure's peak against budgets | 8 GB Mac, E2B (3 GB): over (this run's model); 16 GB Mac, E2B (11 GB): fits (this run's model); 24 GB Mac, 12B (19 GB): fits |
| Live delay inside answers, to drawn | no chunks |
| Live delay outside answers, to drawn | median 2.0 s, p95 3.3 s (843 chunks) |
| Live delay inside answers, to update | median 1.9 s, p95 5.4 s (1167 chunks) |
| Live delay outside answers, to update | median 1.6 s, p95 2.9 s (6008 chunks) |
| Live chunks not measured | none |
| Longest live decode inside answers | 5.16 s |
| Longest live decode outside answers | 3.19 s |
| Watchdog resets | 0 |
| Live engine restarts / failures | 0 / 0 |
| Catch-up after answers | median 0.0 s; per answer (s): 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 |
| Time to first token, cold | 19.7 s, 4.2 s, 6.4 s, 8.8 s, 15.9 s, 17.8 s, 15.8 s, 13.9 s |
| Time to first token, warm | median – (0 answers) |
| Tokens per second | median 49.0 |
| Citation validity | 50 of 50 (100%) |
| Failed / partial answers | 0 failed, 0 partial |
| Warnings | none |
| Contention rule | fails (a decode inside an answer took 5.2 s) |

The failing decode took 5.16 s. It ended 317.1 s into the recording, inside question 4's answer (window 300.1 to 319.6 s). The next longest decodes inside answers were 4.25 s and 2.81 s, both in the same window. Outside answers the longest was 3.19 s. Compared with `concurrent-e2b`, the live delay to the update was about twice as long (median 1.9 s inside answers and 1.6 s outside, against 1.0 s and 0.8 s), and its p95 inside answers was 5.4 s. The catch-up was still 0 s after every answer. The live transcript updates half as often in Low Power Mode, so each decode covers more audio. Times to first token were 4.2 to 19.7 s; the first includes a 17.5 s model load. The prompts were larger than in `concurrent-e2b` (1,089 to 5,497 tokens).

### after-stop

The questions start at Stop, while the final pass runs.

| Measure | Value |
|---|---|
| Plan | after-stop, mode concurrent, model closed after each answer: as this Mac's policy |
| Questions asked | 4 of 4 |
| Model loads | 0 during the recording, 1 outside it: gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf (closes: none) |
| Memory during the recording, app | footprint peak 0.14 GB, median 0.11 GB; resident peak 0.24 GB, median 0.21 GB |
| Memory during the recording, speech worker | footprint peak 0.11 GB, median 0.08 GB; resident peak 0.15 GB, median 0.10 GB |
| Memory during the recording, AI worker | footprint peak –, median –; resident peak –, median – |
| Memory during the recording, sum | footprint peak 0.25 GB, median 0.20 GB; resident peak 0.39 GB, median 0.31 GB |
| Memory for the rule (footprints + AI worker's mapped weights) | peak 0.25 GB, median 0.20 GB |
| Same figure after Stop (final pass and summary; not for the rule) | peak 3.21 GB, median 3.03 GB |
| Rule figure's peak against budgets | 8 GB Mac, E2B (3 GB): fits (this run's model); 16 GB Mac, E2B (11 GB): fits (this run's model); 24 GB Mac, 12B (19 GB): fits |
| Live delay inside answers, to drawn | no chunks |
| Live delay outside answers, to drawn | median 1.3 s, p95 2.5 s (3447 chunks) |
| Live delay inside answers, to update | no chunks |
| Live delay outside answers, to update | median 0.8 s, p95 1.9 s (7188 chunks) |
| Live chunks not measured | none |
| Longest live decode inside answers | – |
| Longest live decode outside answers | 4.07 s |
| Watchdog resets | 0 |
| Live engine restarts / failures | 0 / 0 |
| Catch-up after answers | median 0.0 s; per answer (s): 0.0, 0.0, 0.0, 0.0 |
| Time to first token, cold | 8.8 s |
| Time to first token, warm | median 0.7 s (3 answers) |
| Tokens per second | median 80.3 |
| Citation validity | 23 of 28 (82%) |
| Failed / partial answers | 0 failed, 0 partial |
| Warnings | none |
| Contention rule | undetermined (no live decode lines in the answer windows) |

The first answer loaded the model (5.2 s; 8.8 s to the first token), and the next three found it loaded (0.7 s to the first token). The answers came from the live draft, with prompts of 3,707 to 5,082 tokens. With the final pass and the loaded AI model, the rule's figure after Stop peaked at 3.21 GB. In question 3's answer, 4 of 9 cited times became links (23 of 28 over the run). The answer windows came after the live transcript had finished, so the rule has no decode to judge, as the procedure expects.

### concurrent-12b

| Measure | Value |
|---|---|
| Plan | concurrent-12b, mode concurrent, model closed after each answer: no |
| Questions asked | 8 of 8 |
| Model loads | 1 during the recording, 0 outside it: gemma-4-12b-it-UD-Q4_K_XL.gguf (closes: idle 1) |
| Memory during the recording, app | footprint peak 0.15 GB, median 0.11 GB; resident peak 0.21 GB, median 0.17 GB |
| Memory during the recording, speech worker | footprint peak 0.09 GB, median 0.08 GB; resident peak 0.14 GB, median 0.09 GB |
| Memory during the recording, AI worker | footprint peak 2.81 GB, median 1.49 GB; resident peak 9.58 GB, median 8.26 GB |
| Memory during the recording, sum | footprint peak 3.03 GB, median 1.67 GB; resident peak 9.83 GB, median 8.51 GB |
| Memory for the rule (footprints + AI worker's mapped weights) | peak 9.78 GB, median 8.44 GB |
| Same figure after Stop (final pass and summary; not for the rule) | peak 0.43 GB, median 0.42 GB |
| Rule figure's peak against budgets | 8 GB Mac, E2B (3 GB): over; 16 GB Mac, E2B (11 GB): fits; 24 GB Mac, 12B (19 GB): fits (this run's model) |
| Live delay inside answers, to drawn | no chunks |
| Live delay outside answers, to drawn | median 1.2 s, p95 2.1 s (449 chunks) |
| Live delay inside answers, to update | median 0.9 s, p95 2.2 s (793 chunks) |
| Live delay outside answers, to update | median 0.8 s, p95 2.0 s (6392 chunks) |
| Live chunks not measured | none |
| Longest live decode inside answers | 2.83 s |
| Longest live decode outside answers | 4.32 s |
| Watchdog resets | 0 |
| Live engine restarts / failures | 0 / 0 |
| Catch-up after answers | median 0.0 s; per answer (s): 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 |
| Time to first token, cold | 17.7 s |
| Time to first token, warm | median 4.0 s (7 answers) |
| Tokens per second | median 11.4 |
| Citation validity | 27 of 27 (100%) |
| Failed / partial answers | 0 failed, 0 partial |
| Warnings | none |
| Contention rule | passes |

The model loaded once, in 13.4 s, for question 1 (17.7 s to the first token), and stayed loaded until 180 s after the last answer. The warm answers took 1.9 to 5.9 s to the first token, except question 8: 27.1 s, at 3.5 tokens per second, the only 12B answer that needed the 8,192-token context. The mapped weights peaked at 6.80 GB, against the GGUF file's 6.86 GB.

## Memory against each tier's budget

The budget is the Mac's memory minus 5 GB. The rule's figure is the sum of the footprints of the app, the speech worker and the AI worker, plus the AI worker's resident size beyond its footprint (the model weights that llama.cpp maps from the GGUF file). It is sampled every second during the recording.

| Tier | Model there | Budget | Peak during the recording | Decision |
|---|---|---|---|---|
| 8 GB | E2B | 3 GB | 2.96 GB (`concurrent-e2b`); 3.04 GB with Low Power Mode on | **Proposed: wait for Stop** (`waitForStopMaximumMemory` = 8 GB). The rule says chat runs during recordings |
| 16 GB | E2B | 11 GB | 2.96 GB (`concurrent-e2b`) | Chat runs during recordings |
| 24 GB | 12B | 19 GB | 9.78 GB (`concurrent-12b`) | Chat runs during recordings |

**The 8 GB tier departs from the decision rule, and waits for the user's review.** By the rule, 2.96 GB is under 3 GB, so 8 GB Macs would answer during recordings. The proposal makes them wait for Stop:

- The margin is 0.04 GB (1.4%), and the figure undercounts by more than that. The speech worker's footprint was 0.08 to 0.12 GB, but the live Whisper model is mostly memory that the Neural Engine wires outside the process. The app measured it at about 0.2 to 0.3 GB when it chose to keep the live model loaded (25 October 2026).
- Samples are one second apart, so a shorter peak is missed. With Low Power Mode on, the same plan peaked at 3.04 GB, over the budget.
- An 8 GB Mac starts with the live transcript off (`liveTranscriptMemoryLimit`), so chat during a recording there needs the user to turn the live transcript on first. Waiting for Stop costs those Macs little.

The figures for 8 GB and 16 GB Macs are estimates from this Mac. A run on such a Mac would replace them. The speech worker and the app need the same memory on any Apple-silicon Mac, and the AI worker's figure is the model file, mapped.

## Contention

The rule fails on the Low Power Mode run. Per the component doc, the contingency starts: phase 7 builds the [live hold](../../components/live_hold.md) and the `.holdLiveTranscript` mode, runs `concurrent` again with it, and measures the other remedy, a higher watchdog limit while an answer runs. The user chooses between them. This phase builds neither.

What the data says for that choice:

- The failure is one decode 0.16 s over the limit. The 5 s limit is half of the watchdog's 10 s, and no run reset the worker.
- At normal power the live transcript alone came close to the limit: the longest decode outside answers was 4.76 s in `baseline`, 4.75 s in `concurrent-e2b` and 4.32 s in `concurrent-12b`. Inside answers it stayed lower: 3.25 s with E2B and 2.83 s with 12B.
- The live text never fell behind for long: the catch-up was 0 s after every answer in every run.

## Notes on the runs

- **The first `baseline` run is discarded** (`results/baseline-discarded.*`). Two questions were asked in the app during it, not by the driver (at 4:34 and 5:40 of the recording), so it loaded the model. Also, the new build's live model was compiled when the recording started, so the live transcript started 2 minutes late. The run was repeated after the launch wait below was added, and the analysis now warns about answers the driver did not ask.
- **Launch wait.** A new build, or a Core ML cache that macOS purged under low disk space, compiles the speech models first: here 139 s for the live model and 244 s for the final pass's model. A recording started meanwhile holds its live transcript until the live model's compile ends. The driver therefore starts the recording only once no speech model has been prepared for 3 s, as for a user who opens the app ahead of a meeting. The launch took 6 to 7 s when nothing had to compile, and up to 416 s in `lowpower-e2b`, where the final pass's model compiled (409 s) with Low Power Mode on.
- **Permission prompts.** Biscotti Dev is ad-hoc signed, so each new build lost its microphone and system-audio grants. The agent answered no prompt. After the 14:55 build, the repeated `baseline` run's Record raised a prompt, and the user answered it at 15:02:45. The 17:5x build asked for the microphone (`tccd`: `kTCCServiceMicrophone`, for `DerivedData/Development-meeting-chat/…/Biscotti Dev.app`). The second Low Power Mode attempt (17:58) therefore started no recording within 90 s (`results/lowpower-e2b-aborted-1.ndjson`). The user granted access, and the third attempt ran.
- **Another branch's build.** At 16:58 another session rebuilt `DerivedData/Development` from `worktrees/people-management`, which has no chat load driver. The Low Power Mode attempt at 17:42 ran that app and wrote no `chat-load` line. The user's permission change then quit it (`results/lowpower-e2b-aborted.ndjson`, not analyzed). `Tools/development.sh` now takes `BISCOTTI_DEV_DERIVED_DATA`, so this branch builds into a folder of its own.
- **Production Biscotti** ran from 15:36 to about 17:41. `run.sh` never touches it and refuses to start while it runs, so the later runs waited.
- **"To drawn" live delay.** Each question opens the chat card in the live drawer's place, so no chunk was drawn inside an answer. The rule does not use this figure.

## What remains

For the user:

- **Review the 8 GB proposal** above. The strict reading of the rule (2.96 GB under 3 GB) lets 8 GB Macs answer during recordings.
- **Choose how to proceed on contention**, after phase 7 measures the live hold and the higher watchdog limit.
- **Run `make test-ai`**, which includes the `MeetingChatAITests` suite.
