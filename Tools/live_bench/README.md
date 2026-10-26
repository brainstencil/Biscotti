# Live transcript replay harness

This is the benchmark that chose Biscotti's live transcript engine. It replays
recorded meetings at real-time speed through the same live session code the
app ships, and scores what the session shows and when. It is kept on this
reference branch, not in the app's source. The method, the full results and the
decision are in
[`specs/research/live_transcription/README.md`](../../specs/research/live_transcription/README.md).

## What it measures

- **Latency:** for each reference word, the time from the end of the spoken
  word to its first correct display and to its settled display.
- **Accuracy:** word error rate on non-overlapping speech, compared with the
  app's final pass on the same clips, and how many critical words (names,
  numbers and negations) survive.
- **Gap behaviour:** overflow and silence gaps, corrections per 100 words, the
  longest rewritten tail, and text shown during silence.
- **Endurance:** over a 45-minute recording, whether the live text falls
  further behind, how much system memory it adds, and the thermal state.
- **Back-to-back load:** live text while final passes of another recording run
  in a second process. `overnight.py` starts those passes (`run_alongside`);
  `live-bench run --alongside` only labels the run (its folder name and manifest).

The four gates (latency, accuracy, endurance and recording safety) and their
thresholds are frozen in `GATES` in `report.py`. Recording safety is measured by
`LiveBranchSafetyTests` in `Packages/AudioCapture`, not here.

## How a replay works

- `live-bench` (`Packages/Transcription/Sources/live-bench`) reads a clip's
  16 kHz tracks and releases them in 100 ms steps on a real clock, or as fast as
  the session takes them with `--virtual-clock`. It sends 250 ms chunks per
  track, as the app's pump does, to `WhisperLiveSession` with
  `WhisperKitLiveDecoder`, or to `SpeechAnalyzerLiveSession` on macOS 26.
- `--load call` adds a simulated call load in the same process: two threads at
  60% duty and a Metal loop that keeps the GPU about 30% busy.
- Every update goes to `events.jsonl` with its source and monotonic times. The
  run also writes `final.json`, `resources.jsonl` (system memory once a second,
  against a 30 s baseline) and `manifest.json` (commit, model hashes, machine,
  options, fixture hashes, power and thermal state).
- `live-bench final-pass` transcribes each clip the way the app's final pass
  does, for the accuracy baseline. `live-bench cost` times decodes of 2, 10 and
  30 s.
- `live-bench` refuses any `--models`, `--fixtures` or `--out` folder inside
  `~/Library/Application Support/Biscotti` or `/Applications/Biscotti.app`, and
  never downloads model weights.

## Running it

You need Xcode 26.3, `uv`, about 2 GB for the AMI cache, and a model folder
that holds `argmaxinc/whisperkit-coreml/<model>` and the matching
`openai/whisper-<size>` tokenizer, for example a copy of the app's model cache.

1. Fetch the AMI annotations and the headset tracks of the meetings in
   `clips.json`:

   ```sh
   cd Tools/live_bench
   uv run python fetch_ami.py --cache "$AMI_CACHE" \
     --meetings ES2009a,ES2011a,IB4003,IS1003b,TS3006d,TS3010a,TS3012a
   ```

2. Cut the fixtures. The lock is written once; `--verify` checks a fixture
   folder against it. `fixtures.lock.json` in this folder is the lock the
   published results used.

   ```sh
   uv run python make_fixtures.py --ami "$AMI_CACHE" --clips clips.json --out "$BENCH_LIVE_FIXTURES"
   uv run python make_fixtures.py --verify "$BENCH_LIVE_FIXTURES"
   ```

3. Run, score and report. `make bench-live` reads the three folders from the
   environment:

   ```sh
   export BENCH_LIVE_MODELS=/path/to/models BENCH_LIVE_FIXTURES=/path/to/fixtures BENCH_LIVE_OUT=/path/to/results
   make bench-live ARGS="run --option whisper-small --interval 1 --mode two-track --clips smoke --load call --vocabulary-off --whisper-prompt none"
   uv run python score.py --run "$BENCH_LIVE_OUT/<run folder>" --fixtures "$BENCH_LIVE_FIXTURES"
   uv run python report.py --runs "$BENCH_LIVE_OUT/<run folder>" ... --out report.md
   ```

   `--whisper-prompt none` matches what the app ships; the default is the
   spec's original prompt. `speech-assets --install` installs the SpeechAnalyzer
   locale once before the first `--option speechanalyzer` run.

4. For the full gated schedule, `overnight.py --plan` prints it, `--dry-run`
   checks every code path in minutes, and `overnight.py` runs it unattended,
   one run at a time, resuming where it stopped.

Tests: `uv run pytest` here, and `swift test --package-path Packages/Transcription --filter LiveBenchTests`.

## Headline results

One MacBook Pro (M1 Max, 64 GB, macOS 26.6.2), six validation clips, two quiet
runs each, two-track, simulated call load, no custom vocabulary. The final pass
scores 11.3% WER and keeps 92.5% of critical words on the same clips.

| Option | Shown within 3 s | Settled within 5 s | WER | Critical words |
|---|---|---|---|---|
| whisper-current (large-v3, every 2 s) | 45.6% | 24.4% | 11.9% | 90.2% |
| **whisper-small (every 1 s, chosen)** | **97.2%** | **93.6%** | **12.7%** | **84.1%** |
| SpeechAnalyzer | 71.6% | 58.5% | 14.0% | 91.6% |
| SpeechAnalyzer, fast results | 97.9% | 76.3% | 13.8% | 87.9% |

No option passed every gate as frozen. whisper-small is the only option in a
latency tier (the slower one: 99.7% shown within 5 s, 98.8% settled within
8 s), it kept that tier for 45 minutes, and it runs on macOS 15. Its cost is
critical words. A Whisper final pass running beside Whisper live slows both, so
the app holds final passes until a recording stops. See the research note for
the soak, back-to-back and vocabulary results and the known limits.

## AMI Meeting Corpus

The fixtures are cut from the AMI Meeting Corpus
(https://groups.inf.ed.ac.uk/ami/corpus/), licensed under
[Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).
Citation: Jean Carletta et al., "The AMI Meeting Corpus: A Pre-announcement",
Machine Learning for Multimodal Interaction (MLMI 2005), LNCS 3869, Springer,
2006. `fetch_ami.py` downloads the files unchanged from the official mirror and
writes this attribution to `ATTRIBUTION.txt` in the cache. The fixtures
(cropped and summed headset tracks, word lists) are adaptations and carry the
same attribution, and so does `clips.json`, whose name lists come from the AMI
annotations. No AMI audio is stored in this repository.
