"""Run the gated live-bench schedule unattended, one run at a time.

    uv run python overnight.py --plan        # print the schedule and its duration
    uv run python overnight.py --dry-run     # check every code path in minutes
    uv run python overnight.py               # run it (resumes where it stopped)

Reads BENCH_LIVE_MODELS, BENCH_LIVE_FIXTURES and BENCH_LIVE_OUT like
`make bench-live`, or the matching flags. Start it from a shell set up for
the package build (Xcode, SwiftPM caches); it builds live-bench in release
first.

What it does:

- Refuses uncommitted changes and untracked files (`--allow-dirty`
  overrides), so every run records a clean commit, and refuses to resume a
  schedule started from other code (commit and source fingerprint, the same
  value live-bench writes to each manifest).
- Refuses to start on battery or in Low Power Mode, and logs the power
  state before each run.
- Copies the built live-bench to a private folder on the startup disk and
  runs that copy: a binary paged back in from an external USB disk under
  memory pressure crashed twice with SIGBUS (KERN_MEMORY_ERROR). Models,
  fixtures and results stay where they are.
- Keeps the Mac awake with `caffeinate -i` while it runs.
- Before each run, waits until the median CPU idle over QUIET_WINDOW_SECONDS
  is at least QUIET_CPU_IDLE: the BUSY_CPU_IDLE limit report.py applies to a
  run's baseline, plus the share of the CPU the simulated call load takes in
  that baseline (the check runs before live-bench starts it), plus
  QUIET_MARGIN; about 67% on this 10-core Mac. CPU idle is sampled once a
  second from host_statistics, as live-bench's ResourceSampler samples it.
  The 1-minute load average is logged beside it, at the start of a wait,
  every QUIET_LOG_SECONDS during it and before each run, but does not decide:
  it counts runnable threads; Spotlight and mediaanalysisd run at background
  priority, which on Apple silicon uses only the two efficiency cores, so
  their queue raises it while the performance cores stay idle. At night,
  Spotlight (mds_stores, corespotlightd) and mediaanalysisd kept it at 15 to
  20 for hours while the CPU stayed 65 to 75% idle, and a wait on the load
  average started no run in 45 minutes.
- Runs the steps in priority order, options interleaved: each option's own
  load on one smoke clip; the cost check and the final-pass baseline;
  validation of every option, twice, the second round in reverse order; a
  soak for every option; whisper-small's interval recheck; the back-to-back
  arm; the other real-time calibration rechecks; then the extended
  calibration block (EXTENDED_CALIBRATION), most informative first. A step
  that would end after the deadline (`--hours` after the first start, kept
  across restarts unless `--reset-deadline`) is skipped. The default of 7.5
  hours ends before the extended block; `--hours 24` runs all of it.
- Stops a run that takes more than twice its estimate plus ten minutes,
  retries a failed run once, scores each run as it finishes (score.py), and
  records every step in <out>/overnight/state.json, so a second start skips
  what is done. A second runner on the same folder refuses to start while
  the first holds <out>/overnight/runner.lock. A step that cannot be scored
  is recorded as such and the night goes on. Logs go to <out>/overnight/.
- At the end writes three reports there, each with the final-pass baseline
  and headed by the steps that did not finish or needed a retry:
  report-gated.md (validation and soak), report-own-load.md (each option on
  one smoke clip on the quiet Mac) and report-diagnostics.md (back-to-back,
  calibration rechecks and the extended calibration block).

`--dry-run` runs the same steps through the same code in the same order,
each cut short (DryRun): one clip per run, a few seconds of each clip, a
minute of the soak, a 1 s baseline and one timed decode per cost length,
into its own folder (<out>/dry-runs/<time>/). It kills the schedule while a
validation run is under way and starts it again, forces one run past a
tiny timeout and one scoring failure, and measures CPU idle over a few
seconds and logs it instead of waiting for a quiet Mac. Then it checks the
outcome and prints a pass or fail per check. Its reports are labeled as
plumbing only.

SpeechAnalyzer runs with and without `.fastResults` in validation. The soak
and the back-to-back arm use one of the two, chosen by SPEECH_VARIANT_RULE
from the validation runs.

Settings (interval, prompt, mode) were chosen before the night from the cost
check, virtual-clock calibration runs and provisional real-time runs on a
busy Mac (specs/research/live_transcription/README.md). The rechecks compare
each Whisper option's chosen interval, its runner-up and mixed mode on half
the calibration clips in real time.
"""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import functools
import hashlib
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

import report
import score
from make_fixtures import read_json, verify_lock

REPO = Path(__file__).resolve().parents[2]
PACKAGE = REPO / "Packages" / "Transcription"
# A run starts once the median CPU idle over the window is at least
# QUIET_CPU_IDLE. The check runs before live-bench starts, so without the
# simulated call load (`--load call`, every gated run) that the run's 30 s
# baseline includes: SimulatedCallLoad keeps two threads busy 60% of the time
# (cpuThreads, cpuDutyCycle), 1.2 cores, or 12 points of all-core idle on
# this 10-core Mac. The limit is report.BUSY_CPU_IDLE plus that share plus
# QUIET_MARGIN, about 67% here, so a run that starts at the limit has a
# baseline about 5 points above the busy limit. CPU idle, not the load
# average: see the module docstring. Each check takes the window, which also
# paces the wait.
CALL_LOAD_CPU_THREADS = 2  # SimulatedCallLoad.cpuThreads
CALL_LOAD_CPU_DUTY_CYCLE = 0.6  # SimulatedCallLoad.cpuDutyCycle
CALL_LOAD_CPU_SHARE = CALL_LOAD_CPU_THREADS * CALL_LOAD_CPU_DUTY_CYCLE / (os.cpu_count() or 1)
QUIET_MARGIN = 0.05
QUIET_CPU_IDLE = report.BUSY_CPU_IDLE + CALL_LOAD_CPU_SHARE + QUIET_MARGIN
QUIET_WINDOW_SECONDS = 30
# A long wait logs the CPU idle and load average this often.
QUIET_LOG_SECONDS = 600
DEFAULT_HOURS = 7.5
ATTEMPTS = 2

CALIBRATION = [
    "cal-es2011a-long-turn", "cal-es2011a-fast-turns", "cal-is1003b-sparse",
    "cal-is1003b-numbers", "cal-ts3010a-sparse-long-turn", "cal-ts3010a-negations",
]
VALIDATION = [
    "val-es2009a-long-turn", "val-es2009a-fast-turns-names", "val-ib4003-numbers",
    "val-ib4003-names-negations", "val-ts3012a-long-turn", "val-ts3012a-sparse",
]
SOAK = ["soak"]
# Rechecks use half the calibration clips, so six fit after the gated steps:
# fast turn-taking, a monologue with numbers, and sparse speech with a long turn.
RECHECK_CLIPS = ["cal-es2011a-fast-turns", "cal-is1003b-numbers", "cal-ts3010a-sparse-long-turn"]
LARGE = "openai_whisper-large-v3-v20240930_626MB"
SMALL = "openai_whisper-small"

# Every gated run: two tracks, simulated call load, no vocabulary.
COMMON = ["--mode", "two-track", "--load", "call", "--vocabulary-off"]
# The live options and their chosen settings. Whisper decodes unprompted
# (LiveDecoderPrompt.none): with argmax-oss-swift 1.1.0, a prompted decode on
# a multilingual model runs without WhisperKit's timestamp rules, and on a
# trial clip the spec's prompt gave 38% WER against 26% without a prompt.
# Intervals: the session decodes through one lane, one decode at a time for
# both tracks (WhisperLiveSession.runScheduledWork), so in two-track mode an
# interval holds two decodes whenever both tracks have speech. With the cost
# check's median decode of a 10 s window (large-v3 1.5 s, small 0.65 s),
# large-v3 needs about 3 s per round and small about 1.3 s, so neither keeps
# its interval below 4 s and 2 s while both tracks talk; one track at a time
# fits within 2 s and 1 s. Of the intervals that fit one track, the best
# latency tier on the calibration clips, then the lowest WER: virtual-clock
# runs for small, where 1 s beat 2 s on both; real-time runs on a busy Mac
# for large-v3, where 2 s beat 4 s on latency. The rechecks and the extended
# calibration block measure the cost the virtual clock cannot see.
OPTIONS = {
    "whisper-current": ["--option", "whisper-current", "--whisper-prompt", "none", "--interval", "2"],
    "whisper-small": ["--option", "whisper-small", "--whisper-prompt", "none", "--interval", "1"],
    "speechanalyzer": ["--option", "speechanalyzer", "--interval", "2"],
    "speechanalyzer-fast": ["--option", "speechanalyzer", "--fast-results", "--interval", "2"],
}
# Calibration rechecks: each Whisper option's runner-up interval and mixed mode.
RECHECKS = {
    "whisper-small": ["--option", "whisper-small", "--whisper-prompt", "none", "--interval", "2"],
    "whisper-current": ["--option", "whisper-current", "--whisper-prompt", "none", "--interval", "4"],
}
# The calibration clips the rechecks leave out.
REST_OF_CALIBRATION = [clip for clip in CALIBRATION if clip not in RECHECK_CLIPS]
MIXED = [token if token != "two-track" else "mixed" for token in COMMON]


def whisper(option: str, interval: int) -> list[str]:
    return ["--option", option, "--whisper-prompt", "none", "--interval", str(interval)]


SPEECH = {
    "standard": ["--option", "speechanalyzer", "--interval", "2"],
    "fast": ["--option", "speechanalyzer", "--fast-results", "--interval", "2"],
}
# Real-time calibration on all six calibration clips for the spec's
# candidates: Whisper at 1, 2 and 4 s, two-track or mixed; SpeechAnalyzer
# two-track or mixed, with or without fast results. A combination its recheck
# measured on three clips gets only the other three, and the report pools both
# runs (and notes that it was measured in parts); when the recheck did not count
# (not done, or busy), the completion runs all six. Most informative first: the
# chosen and runner-up Whisper intervals, then SpeechAnalyzer's mode and fast
# results, then mixed mode for the chosen Whisper settings, then the settings
# no one chose. Two of the sixteen combinations are left out because a kept run
# answers the same question: large-v3 every 1 s, kept in two-track mode, shows
# how far it falls behind when it cannot finish a decode per interval, which
# mixed mode would show again with one track; and small every 4 s, kept in
# two-track mode, is small's slowest setting, which mixed mode would repeat.
# Each entry: name, arguments, clips, and the recheck it completes.
EXTENDED_CALIBRATION = [
    ("whisper-current-i2-two-track", [*whisper("whisper-current", 2), *COMMON], REST_OF_CALIBRATION, "calibration-whisper-current-chosen"),
    ("whisper-small-i1-two-track", [*whisper("whisper-small", 1), *COMMON], REST_OF_CALIBRATION, "calibration-whisper-small-chosen"),
    ("whisper-current-i4-two-track", [*whisper("whisper-current", 4), *COMMON], REST_OF_CALIBRATION, "calibration-whisper-current-runner-up"),
    ("whisper-small-i2-two-track", [*whisper("whisper-small", 2), *COMMON], REST_OF_CALIBRATION, "calibration-whisper-small-runner-up"),
    ("speechanalyzer-two-track", [*SPEECH["standard"], *COMMON], CALIBRATION, None),
    ("speechanalyzer-fast-two-track", [*SPEECH["fast"], *COMMON], CALIBRATION, None),
    ("speechanalyzer-mixed", [*SPEECH["standard"], *MIXED], CALIBRATION, None),
    ("speechanalyzer-fast-mixed", [*SPEECH["fast"], *MIXED], CALIBRATION, None),
    ("whisper-current-i2-mixed", [*whisper("whisper-current", 2), *MIXED], REST_OF_CALIBRATION, "calibration-whisper-current-mixed"),
    ("whisper-small-i1-mixed", [*whisper("whisper-small", 1), *MIXED], REST_OF_CALIBRATION, "calibration-whisper-small-mixed"),
    ("whisper-small-i4-two-track", [*whisper("whisper-small", 4), *COMMON], CALIBRATION, None),
    ("whisper-current-i1-two-track", [*whisper("whisper-current", 1), *COMMON], CALIBRATION, None),
    ("whisper-small-i2-mixed", [*whisper("whisper-small", 2), *MIXED], CALIBRATION, None),
    ("whisper-current-i4-mixed", [*whisper("whisper-current", 4), *MIXED], CALIBRATION, None),
]
SPEECH_CHOSEN = "speechanalyzer-chosen"
SPEECH_VARIANT_RULE = (
    "Of SpeechAnalyzer with and without fast results, the one whose quiet validation runs (all of them when none is quiet) "
    "have the better latency result (pass, then slower tier, then fail), then the better accuracy result, then the higher "
    "of the smaller of its two fast-tier shares (shown within 3 s, settled within 5 s); without fast results on a tie."
)
DEFAULT_SPEECH_VARIANT = "speechanalyzer"
# Seconds a run spends beyond its clips: the 30 s memory baseline, model load,
# hashing the model, finishing each clip and scoring.
RUN_OVERHEAD_SECONDS = 75
CLIP_OVERHEAD_SECONDS = 4
ALONGSIDE_LEAD_SECONDS = 20
# A run that takes longer than twice its estimate plus this is stopped.
TIMEOUT_MARGIN_SECONDS = 600


@dataclass
class DryRun:
    """How --dry-run cuts the schedule short and which failures it forces."""

    clip_seconds: float = 4
    soak_seconds: float = 60
    baseline_seconds: int = 1
    alongside_lead_seconds: float = 5
    quiet_window_seconds: float = 3
    kill_step: str = "validation-1-whisper-small"
    timeout_step: str = "calibration-whisper-small-chosen"
    forced_timeout_seconds: float = 1
    score_failure_step: str = "calibration-whisper-current-mixed"
    label: str = "DRY RUN: plumbing only. Every clip was cut to a few seconds; nothing in this report is a result."

    def step(self, step: Step) -> Step:
        """`step` cut short: its first clip only (the final pass keeps three
        clips; a cut final pass is never the baseline, so it only has to run)."""
        if step.group == "cost":
            return Step(step.id, step.group, [*step.arguments, "--decodes", "1"], step.clips, step.alongside)
        clips = ["smoke", VALIDATION[0], RECHECK_CLIPS[0]] if step.group == "baseline" else step.clips[:1]
        arguments = list(step.arguments)
        arguments[arguments.index("--clips") + 1] = ",".join(clips)
        seconds = self.soak_seconds if clips == SOAK else self.clip_seconds
        arguments += ["--clip-seconds", f"{seconds:g}"]
        if step.group != "baseline":
            arguments += ["--baseline-seconds", str(self.baseline_seconds)]
        return Step(step.id, step.group, arguments, clips, step.alongside, step.completes, step.fallback_clips[:1])

    def durations(self, durations: dict[str, float]) -> dict[str, float]:
        return {clip: min(duration, self.soak_seconds if clip == "soak" else self.clip_seconds) for clip, duration in durations.items()}


@dataclass
class Step:
    id: str
    group: str
    arguments: list[str]
    clips: list[str] = field(default_factory=list)
    alongside: bool = False
    # An extended-calibration completion: the recheck whose clips it adds to,
    # and the clips it runs instead when that recheck does not count.
    completes: str | None = None
    fallback_clips: list[str] = field(default_factory=list)

    def resolved(self, speech_variant: str) -> list[str]:
        return [token for argument in self.arguments for token in (OPTIONS[speech_variant] if argument == SPEECH_CHOSEN else [argument])]

    def with_clips(self, clips: list[str]) -> Step:
        arguments = list(self.arguments)
        arguments[arguments.index("--clips") + 1] = ",".join(clips)
        return Step(self.id, self.group, arguments, list(clips), self.alongside, self.completes, self.fallback_clips)


def schedule() -> list[Step]:
    """Every step, in the order and priority it runs."""
    steps = [
        Step(f"own-load-{option}", "own-load", ["run", *OPTIONS[option], *COMMON, "--clips", "smoke"], ["smoke"])
        for option in OPTIONS
    ]
    steps += [
        Step("cost-large", "cost", ["cost", "--model", LARGE, "--whisper-prompt", "none"]),
        Step("cost-small", "cost", ["cost", "--model", SMALL, "--whisper-prompt", "none"]),
        Step("final-pass", "baseline", ["final-pass", "--clips", ",".join(["smoke", *CALIBRATION, *VALIDATION])], ["smoke", *CALIBRATION, *VALIDATION]),
    ]
    order = list(OPTIONS)
    for round_number, options in ((1, order), (2, list(reversed(order)))):
        steps += [
            Step(f"validation-{round_number}-{option}", "validation", ["run", *OPTIONS[option], *COMMON, "--clips", ",".join(VALIDATION)], VALIDATION)
            for option in options
        ]
    for option in ("whisper-current", SPEECH_CHOSEN, "whisper-small"):
        arguments = [SPEECH_CHOSEN] if option == SPEECH_CHOSEN else OPTIONS[option]
        steps.append(Step(f"soak-{option}", "soak", ["run", *arguments, *COMMON, "--clips", "soak"], SOAK))

    def recheck(name: str, arguments: list[str]) -> Step:
        return Step(f"calibration-{name}", "calibration", ["run", *arguments, "--clips", ",".join(RECHECK_CLIPS)], RECHECK_CLIPS)

    # whisper-small's interval was chosen in virtual time, which cannot see
    # decode cost, so its recheck comes before the back-to-back arm.
    steps += [
        recheck("whisper-small-chosen", [*OPTIONS["whisper-small"], *COMMON]),
        recheck("whisper-small-runner-up", [*RECHECKS["whisper-small"], *COMMON]),
    ]
    for option in ("whisper-current", "whisper-small", SPEECH_CHOSEN):
        arguments = [SPEECH_CHOSEN] if option == SPEECH_CHOSEN else OPTIONS[option]
        steps.append(Step(
            f"back-to-back-{option}", "back-to-back",
            ["run", *arguments, *COMMON, "--clips", ",".join(VALIDATION), "--alongside", "final pass of soak"], VALIDATION, alongside=True,
        ))
    steps += [
        recheck("whisper-current-chosen", [*OPTIONS["whisper-current"], *COMMON]),
        recheck("whisper-current-runner-up", [*RECHECKS["whisper-current"], *COMMON]),
        recheck("whisper-current-mixed", [*OPTIONS["whisper-current"], *MIXED]),
        recheck("whisper-small-mixed", [*OPTIONS["whisper-small"], *MIXED]),
    ]
    steps += [
        Step(
            f"extended-{name}", "extended", ["run", *arguments, "--clips", ",".join(clips)], clips,
            completes=recheck_id, fallback_clips=CALIBRATION if recheck_id else [],
        )
        for name, arguments, clips, recheck_id in EXTENDED_CALIBRATION
    ]
    return steps


def estimate_seconds(step: Step, durations: dict[str, float]) -> float:
    if step.group == "cost":
        return 75.0
    if step.group == "baseline":
        # The final pass ran about ten times faster than real time on this Mac.
        return 20.0 + sum(durations.get(clip, 0) for clip in step.clips) / 10
    seconds = RUN_OVERHEAD_SECONDS + sum(durations.get(clip, 0) + CLIP_OVERHEAD_SECONDS for clip in step.clips)
    return seconds + (ALONGSIDE_LEAD_SECONDS if step.alongside else 0)


def timeout_seconds(estimate: float) -> float:
    return 2 * estimate + TIMEOUT_MARGIN_SECONDS


def clip_durations(fixtures: Path) -> dict[str, float]:
    return {folder.name: read_json(folder / "reference.json")["duration"] for folder in fixtures.iterdir() if (folder / "reference.json").exists()}


# MARK: - State


class State:
    """<out>/overnight/state.json: the code the schedule runs, its deadline and each step's outcome."""

    def __init__(self, path: Path, code: dict):
        self.path = path
        self.data = read_json(path) if path.exists() else {"code": code, "steps": {}}
        if self.data["code"] != code:
            raise RunnerError(
                f"{path} belongs to a schedule started from other code ({self.data['code']}); "
                f"this checkout is {code}. Move the overnight folder aside to start again."
            )

    def step(self, step_id: str) -> dict:
        return self.data["steps"].get(step_id, {})

    def is_done(self, step_id: str) -> bool:
        return self.step(step_id).get("status") == "done"

    def deadline(self, hours: float, reset: bool) -> datetime:
        """The deadline set at the first start, or a new one."""
        if reset or "deadline" not in self.data:
            self.data["deadline"] = (datetime.now() + timedelta(hours=hours)).isoformat(timespec="seconds")
            self.save()
        return datetime.fromisoformat(self.data["deadline"])

    def record(self, step_id: str, **values) -> None:
        self.data["steps"].setdefault(step_id, {}).update(values)
        self.save()

    def save(self) -> None:
        temporary = self.path.with_name(self.path.name + ".tmp")
        temporary.write_text(json.dumps(self.data, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(temporary, self.path)


class RunnerError(RuntimeError):
    pass


def lock_folder(folder: Path):
    """Holds <folder>/runner.lock for as long as the returned file stays open,
    so a second runner cannot share the state. A killed runner releases it."""
    lock = (folder / "runner.lock").open("w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise RunnerError(f"another overnight runner is using {folder}") from None
    return lock


# MARK: - Choosing the SpeechAnalyzer variant


def speech_variant(folders: dict[str, list[Path]], baseline: dict) -> str:
    """SPEECH_VARIANT_RULE over the scored validation folders of each variant."""
    tiers = {report.PASS: 2, report.SLOWER: 1}

    def rank(option: str) -> tuple:
        runs = [read_json(folder / "metrics.json") for folder in folders.get(option, [])]
        runs = [run for run in runs if report.busy_reason(run) is None] or runs
        if not runs:
            return (-1, -1, -1.0)
        clips = report.pooled(runs, soak=False)
        # checked() fails a gate whose sessions failed or stopped short.
        latency = report.checked(report.latency_gate(clips), clips, {})
        accuracy = report.checked(report.accuracy_gate(clips, baseline), clips, {})
        shares = latency.get("shares") or {}
        fast = min(shares.get("first") or 0, shares.get("settled") or 0)
        return (tiers.get(latency["result"], 0), 1 if accuracy["result"] == report.PASS else 0, fast)

    return "speechanalyzer-fast" if rank("speechanalyzer-fast") > rank("speechanalyzer") else "speechanalyzer"


# MARK: - Running


def load_average() -> float:
    return os.getloadavg()[0]


# host_statistics(HOST_CPU_LOAD_INFO) fills CPU_STATE_MAX tick counters,
# summed over all cores: user, system, idle, nice (<mach/machine.h>).
HOST_CPU_LOAD_INFO = 3
CPU_STATE_MAX = 4


@functools.cache
def host_statistics():
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_host_self.restype = ctypes.c_uint32
    system.mach_host_self.argtypes = []
    system.host_statistics.restype = ctypes.c_int
    system.host_statistics.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
    return system.mach_host_self(), system.host_statistics


def cpu_ticks() -> tuple[int, int] | None:
    """Busy and idle CPU ticks over all cores, read as live-bench's CPUTicks
    reads them: user, system and nice are busy. None when the call fails."""
    host, call = host_statistics()
    info = (ctypes.c_uint32 * CPU_STATE_MAX)()
    count = ctypes.c_uint32(CPU_STATE_MAX)
    if call(host, HOST_CPU_LOAD_INFO, info, ctypes.byref(count)) != 0:
        return None
    user, system, idle, nice = info
    return user + system + nice, idle


def idle_share(previous: tuple[int, int], current: tuple[int, int]) -> float | None:
    """The idle share of the ticks counted between two readings; None when
    none were, or a counter wrapped."""
    busy, idle = current[0] - previous[0], current[1] - previous[1]
    if busy < 0 or idle < 0 or busy + idle == 0:
        return None
    return idle / (busy + idle)


def median_cpu_idle(seconds: float, sleep=time.sleep, ticks=cpu_ticks) -> float | None:
    """The median CPU idle share of each second over `seconds`, as
    ResourceSampler samples it and score.py summarizes it; None when no
    second could be read. Takes `seconds` to return, even when none can."""
    shares = []
    previous = ticks()
    for _ in range(max(1, round(seconds))):
        sleep(1)
        current = ticks()
        if previous is not None and current is not None and (share := idle_share(previous, current)) is not None:
            shares.append(share)
        previous = current
    return statistics.median(shares) if shares else None


def power_state() -> dict:
    """Whether the Mac draws from AC power and whether Low Power Mode is on,
    from `pmset`; None for what it does not say."""
    battery = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, check=False).stdout
    settings = subprocess.run(["pmset", "-g"], capture_output=True, text=True, check=False).stdout
    return parse_power(battery, settings)


def parse_power(battery: str, settings: str) -> dict:
    lines = battery.splitlines()
    on_ac = ("'AC Power'" in lines[0]) if lines else None
    low_power = None
    for line in settings.splitlines():
        words = line.split()
        # `powermode 1` on Apple silicon (0 automatic, 2 high power); `lowpowermode 1` before.
        if len(words) >= 2 and words[0] in {"powermode", "lowpowermode"}:
            low_power = words[1] == "1"
    return {"ac_power": on_ac, "low_power_mode": low_power}


def describe_power(power: dict) -> str:
    source = {True: "AC power", False: "battery", None: "power source unknown"}[power.get("ac_power")]
    mode = {True: "Low Power Mode on", False: "Low Power Mode off", None: "Low Power Mode unknown"}[power.get("low_power_mode")]
    return f"{source}, {mode}"


def git(*arguments: str) -> str:
    return subprocess.run(["git", "-C", str(REPO), *arguments], check=True, capture_output=True, text=True).stdout.strip()


def git_bytes(*arguments: str) -> bytes:
    return subprocess.run(["git", "-C", str(REPO), *arguments], check=True, capture_output=True).stdout


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while block := file.read(1 << 20):
            digest.update(block)
    return digest.hexdigest()


class Runner:
    def __init__(
        self, models: Path, fixtures: Path, out: Path, binary: Path, log, deadline: datetime,
        clock=time.monotonic, sleep=time.sleep, load=load_average, dry: DryRun | None = None, power=power_state,
        cpu_idle=median_cpu_idle,
    ):
        self.models, self.fixtures, self.out, self.binary = models, fixtures, out, binary
        self.log, self.deadline = log, deadline
        self.clock, self.sleep, self.load = clock, sleep, load
        self.cpu_idle = cpu_idle
        self.dry = dry
        self.power = power
        self.folder = out / "overnight"
        # The median CPU idle the last quiet check measured.
        self.last_idle: float | None = None

    def folders(self) -> list[str]:
        return ["--models", str(self.models), "--fixtures", str(self.fixtures), "--out", str(self.out)]

    def quiet_window(self) -> float:
        return self.dry.quiet_window_seconds if self.dry else QUIET_WINDOW_SECONDS

    def describe_load(self) -> str:
        """The last quiet check's CPU idle and the 1-minute load average now."""
        idle = "unreadable" if self.last_idle is None else f"{self.last_idle:.1%}"
        return f"median CPU idle {idle} over {self.quiet_window():g} s, 1-minute load average {self.load():.1f}"

    def wait_for_quiet(self) -> bool:
        """Waits while the Mac is busy: until the median CPU idle over the
        quiet window is at least QUIET_CPU_IDLE, whatever the load average.
        An unreadable CPU idle counts as busy, as it does in report.py. A long
        wait logs the idle and load every QUIET_LOG_SECONDS, so the log shows
        the trend and a wait cannot be mistaken for a hang. False when the
        deadline passed meanwhile. A dry run only logs a busy Mac."""
        waited_since = logged = None
        while True:
            self.last_idle = self.cpu_idle(self.quiet_window())
            if self.last_idle is not None and self.last_idle >= QUIET_CPU_IDLE:
                break
            if self.dry:
                self.log(f"dry run: {self.describe_load()}, under the quiet limit of {QUIET_CPU_IDLE:.0%} CPU idle; a real run would wait here")
                return True
            if datetime.now() >= self.deadline:
                return False
            now = self.clock()
            if waited_since is None:
                self.log(f"waiting: {self.describe_load()}, under the quiet limit of {QUIET_CPU_IDLE:.0%} CPU idle")
                waited_since = logged = now
            elif now - logged >= QUIET_LOG_SECONDS:
                self.log(f"still waiting after {(now - waited_since) / 60:.0f} min: {self.describe_load()}")
                logged = now
        if waited_since is not None:
            self.log(f"quiet again: {self.describe_load()}")
        return True

    def live_bench(self, arguments: list[str], log_path: Path, timeout: float) -> tuple[int | str, Path | None]:
        """Runs live-bench and returns its exit status, or "timeout", and the
        results folder it named."""
        with log_path.open("a", encoding="utf-8") as log_file:
            try:
                status: int | str = subprocess.run(
                    [str(self.binary), *arguments, *self.folders()], cwd=REPO, stdout=log_file, stderr=subprocess.STDOUT, timeout=timeout,
                ).returncode
            except subprocess.TimeoutExpired:
                status = "timeout"
        folder = None
        for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("Results: "):
                folder = Path(line.removeprefix("Results: ").strip())
        return status, folder

    def run_alongside(self, arguments: list[str], log_path: Path, timeout: float) -> tuple[int | str, Path | None]:
        """The back-to-back arm: final passes of the soak clip, one after another
        in another process, for as long as the live run takes."""
        stop = threading.Event()
        current: list[subprocess.Popen] = []
        lock = threading.Lock()
        alongside_out = self.out / "overnight" / "alongside"
        alongside_out.mkdir(parents=True, exist_ok=True)
        folders = ["--models", str(self.models), "--fixtures", str(self.fixtures), "--out", str(alongside_out)]
        if self.dry:
            folders += ["--clip-seconds", f"{self.dry.soak_seconds:g}"]

        def final_passes() -> None:
            with (log_path.parent / (log_path.stem + "-alongside.log")).open("a", encoding="utf-8") as log_file:
                while not stop.is_set():
                    process = subprocess.Popen([str(self.binary), "final-pass", "--clips", "soak", *folders], cwd=REPO, stdout=log_file, stderr=subprocess.STDOUT)
                    with lock:
                        current[:] = [process]
                    # A pass started just as the run ended is stopped here.
                    if stop.is_set():
                        process.terminate()
                    process.wait()

        thread = threading.Thread(target=final_passes, daemon=True)
        thread.start()
        self.sleep(self.dry.alongside_lead_seconds if self.dry else ALONGSIDE_LEAD_SECONDS)
        try:
            return self.live_bench(arguments, log_path, timeout)
        finally:
            stop.set()
            with lock:
                for process in current:
                    process.terminate()
            thread.join(timeout=60)

    def is_complete(self, folder: Path | None, step: Step) -> bool:
        """live-bench finished every clip: the manifest lists a session for each."""
        if folder is None or not (folder / "manifest.json").exists():
            return False
        if step.group == "cost":
            return (folder / "cost.json").exists()
        sessions = {session["clip"] for session in read_json(folder / "manifest.json").get("sessions", [])}
        return set(step.clips) <= sessions

    def score(self, folder: Path) -> None:
        metrics = score.score_run(folder, self.fixtures)
        (folder / "metrics.json").write_text(json.dumps(metrics, indent=1, allow_nan=False, ensure_ascii=False) + "\n", encoding="utf-8")


def counts(state: State, step_id: str) -> bool:
    """True when the step finished, was scored and its run counts in the gates."""
    entry = state.step(step_id)
    if entry.get("status") != "done":
        return False
    try:
        return report.busy_reason(read_json(Path(entry["folder"]) / "metrics.json")) is None
    except Exception:  # noqa: BLE001 - an unreadable run does not count
        return False


def with_fallback(runner: Runner, state: State, step: Step) -> Step:
    """A completion whose recheck did not count runs all calibration clips, so
    its combination is never judged on three clips alone."""
    if not step.completes or counts(state, step.completes):
        return step
    runner.log(f"{step.id}: {step.completes} did not count, so this runs all {len(step.fallback_clips)} of its calibration clips")
    return step.with_clips(step.fallback_clips)


def run_schedule(runner: Runner, state: State, steps: list[Step], durations: dict[str, float]) -> None:
    for step in steps:
        entry = state.step(step.id)
        if entry.get("status") in {"done", "score-failed"}:
            runner.log(f"{step.id}: {entry['status']} earlier, skipped")
            continue
        if entry.get("attempts", 0) >= ATTEMPTS:
            runner.log(f"{step.id}: {entry.get('status')} after {entry['attempts']} attempts earlier, skipped")
            continue
        step = with_fallback(runner, state, step)
        estimate = estimate_seconds(step, durations)
        for attempt in range(entry.get("attempts", 0), ATTEMPTS):
            if not runner.wait_for_quiet():
                runner.log(f"{step.id}: the deadline passed while waiting for a quiet Mac; stopping")
                return
            if datetime.now() + timedelta(seconds=estimate) > runner.deadline:
                runner.log(f"{step.id}: skipped, it would end after the deadline ({estimate / 60:.0f} min)")
                state.record(step.id, status="skipped-deadline")
                break
            variant = choose_variant(runner, state)
            arguments = step.resolved(variant)
            if SPEECH_CHOSEN in step.arguments:
                runner.log(f"{step.id}: SpeechAnalyzer variant {variant}, by the rule")
            runner.log(
                f"{step.id}: attempt {attempt + 1}, {runner.describe_load()}, {describe_power(runner.power())}, "
                f"about {estimate / 60:.0f} min: live-bench {' '.join(arguments)}"
            )
            state.record(step.id, status="running", attempts=attempt + 1, started=datetime.now().isoformat(timespec="seconds"), arguments=arguments)
            log_path = runner.folder / "logs" / f"{step.id}.log"
            started = runner.clock()
            timeout = timeout_seconds(estimate)
            if runner.dry and step.id == runner.dry.timeout_step and attempt == 0:
                timeout = runner.dry.forced_timeout_seconds
            status, folder = (runner.run_alongside if step.alongside else runner.live_bench)(arguments, log_path, timeout)
            seconds = round(runner.clock() - started)
            if status == 0 and runner.is_complete(folder, step):
                try:
                    if runner.dry and step.id == runner.dry.score_failure_step:
                        raise RuntimeError("scoring failure forced by the dry run")
                    if step.group != "cost":
                        runner.score(folder)
                except Exception as error:  # noqa: BLE001 - one unscorable run must not end the night
                    state.record(step.id, status="score-failed", folder=str(folder), seconds=seconds, error=f"{type(error).__name__}: {error}")
                    runner.log(f"{step.id}: ran in {seconds / 60:.1f} min but could not be scored: {error}")
                    break
                state.record(step.id, status="done", folder=str(folder), seconds=seconds, ended=datetime.now().isoformat(timespec="seconds"))
                runner.log(f"{step.id}: done in {seconds / 60:.1f} min: {folder}")
                break
            outcome = "timeout" if status == "timeout" else "failed"
            state.record(step.id, status=outcome, folder=str(folder) if folder else None, exit=status, seconds=seconds)
            runner.log(f"{step.id}: {outcome} (exit {status}); see {log_path}")


def choose_variant(runner: Runner, state: State) -> str:
    """The SpeechAnalyzer variant for the soak and back-to-back steps, by
    SPEECH_VARIANT_RULE; DEFAULT_SPEECH_VARIANT when the rule cannot be applied."""
    try:
        folders: dict[str, list[Path]] = {}
        for option in ("speechanalyzer", "speechanalyzer-fast"):
            for round_number in (1, 2):
                entry = state.step(f"validation-{round_number}-{option}")
                if entry.get("status") == "done":
                    folders.setdefault(option, []).append(Path(entry["folder"]))
        final = state.step("final-pass")
        baseline = {}
        if final.get("status") == "done":
            baseline, _ = report.final_baseline([read_json(Path(final["folder"]) / "metrics.json")])
        return speech_variant(folders, baseline)
    except Exception as error:  # noqa: BLE001 - a fallback, logged, rather than the end of the night
        runner.log(f"could not apply the SpeechAnalyzer variant rule ({type(error).__name__}: {error}); using {DEFAULT_SPEECH_VARIANT}")
        return DEFAULT_SPEECH_VARIANT


def status_lines(state: State, steps: list[Step]) -> list[str]:
    """The steps that did not finish, or finished only on a retry (a crash
    that recurs shows here), for the head of each report."""
    lines = []
    for step in steps:
        entry = state.step(step.id)
        status = entry.get("status", "not started")
        if status == "done" and entry.get("attempts", 1) > 1:
            status = f"done on attempt {entry['attempts']}, after a failed attempt (see the log)"
        elif status == "done":
            continue
        detail = ", ".join(f"{key} {entry[key]}" for key in ("attempts", "exit", "folder", "error") if entry.get(key) is not None)
        lines.append(f"- {step.id}: {status}" + (f" ({detail})" if detail else ""))
    return lines


def write_reports(runner: Runner, state: State, steps: list[Step]) -> None:
    done = {step.id: Path(state.step(step.id)["folder"]) for step in steps if state.is_done(step.id) and step.group != "cost"}
    unfinished = status_lines(state, steps)
    header = [*([f"> {runner.dry.label}", ""] if runner.dry else []), "# Overnight runner status", "", *(unfinished or ["Every step finished."]), "", ""]
    reports = {
        "report-gated.md": ("final-pass", "validation-", "soak-"),
        # Alone: own-load runs share their configuration with the rechecks.
        "report-own-load.md": ("final-pass", "own-load-"),
        "report-diagnostics.md": ("final-pass", "back-to-back-", "calibration-", "extended-"),
    }
    for name, prefixes in reports.items():
        folders = [folder for step_id, folder in done.items() if step_id.startswith(prefixes)]
        if len(folders) < 2:
            continue
        try:
            (runner.folder / name).write_text("\n".join(header) + report.build_report(folders), encoding="utf-8")
            runner.log(f"wrote {runner.folder / name}")
        except Exception as error:  # noqa: BLE001 - the runs are on disk; score.py and report.py can be rerun by hand
            runner.log(f"could not write {name}: {type(error).__name__}: {error}")


# MARK: - Setup


def build_live_bench() -> Path:
    """Builds live-bench in release with the caller's toolchain set-up and returns it."""
    subprocess.run(["bash", "-c", f"swift build -c release --package-path '{PACKAGE}' --product live-bench"], cwd=REPO, check=True)
    return PACKAGE / ".build" / "release" / "live-bench"


def private_copy(binary: Path) -> Path:
    """A copy on the startup disk (see the module docstring)."""
    folder = Path(tempfile.mkdtemp(prefix="live-bench-overnight-", dir="/private/tmp"))
    copy = folder / "live-bench"
    shutil.copy2(binary, copy)
    return copy


def code_identity(allow_dirty: bool) -> dict:
    """The commit and a fingerprint of any uncommitted code, as live-bench's
    manifest records it: the diff against HEAD and every untracked file."""
    untracked = sorted(path for path in git("ls-files", "--others", "--exclude-standard").splitlines() if path)
    if (git("status", "--porcelain", "--untracked-files=no") or untracked) and not allow_dirty:
        raise RunnerError("the checkout has uncommitted changes or untracked files; commit them first (or pass --allow-dirty)")
    # The same value as RepoProbe.sourceFingerprint in live-bench's manifest.
    files = "".join(f"{path}\t{file_sha256(REPO / path)}\n" for path in untracked)
    diff = hashlib.sha256(git_bytes("diff", "HEAD", "--binary")).hexdigest()
    fingerprint = hashlib.sha256(f"{diff}\n{files}".encode()).hexdigest()
    return {"commit": git("rev-parse", "HEAD"), "source_fingerprint": fingerprint}


def print_plan(steps: list[Step], durations: dict[str, float], hours: float) -> None:
    total = 0.0
    for step in steps:
        seconds = estimate_seconds(step, durations)
        total += seconds
        marker = "" if total <= hours * 3600 else "  (after the deadline: skipped unless earlier steps run faster)"
        print(f"{total / 3600:5.2f} h  {seconds / 60:5.1f} min  {step.group:13s} {step.id}{marker}")
    print(f"total {total / 3600:.2f} h for {len(steps)} steps; deadline {hours:g} h; waits for a quiet Mac come on top")
    fallback = sum(estimate_seconds(step.with_clips(step.fallback_clips), durations) - estimate_seconds(step, durations) for step in steps if step.completes)
    if fallback:
        print(f"up to {fallback / 60:.0f} min more if completions run all calibration clips because their recheck did not count")


def run_night(args: argparse.Namespace, dry: DryRun | None) -> int:
    """The schedule, in this process: the real night, or one dry-run worker."""
    steps = schedule()
    durations = clip_durations(args.fixtures)
    if dry:
        steps, durations = [dry.step(step) for step in steps], dry.durations(durations)
    try:
        power = power_state()
        if power["ac_power"] is not True or power["low_power_mode"] is not False:
            raise RunnerError(f"the Mac must run on AC power with Low Power Mode off ({describe_power(power)})")
        verify_lock(args.fixtures)
        code = code_identity(args.allow_dirty)
        folder = args.out / "overnight"
        (folder / "logs").mkdir(parents=True, exist_ok=True)
        lock = lock_folder(folder)  # held open until the process ends
        state = State(folder / "state.json", code)
    except RunnerError as error:
        print(f"overnight: {error}", file=sys.stderr)
        return 1

    log_file = (folder / "overnight.log").open("a", encoding="utf-8")

    def log(message: str) -> None:
        line = f"{datetime.now():%H:%M:%S} {message}"
        print(line, flush=True)
        log_file.write(line + "\n")
        log_file.flush()

    caffeinate = subprocess.Popen(["caffeinate", "-i", "-w", str(os.getpid())])
    try:
        deadline = state.deadline(args.hours, args.reset_deadline)
        log(f"{'dry run ' if dry else ''}started at {code['commit'][:12]} (source fingerprint {code['source_fingerprint'][:12]}), deadline {deadline:%H:%M}")
        built = args.live_bench or build_live_bench()
        binary = private_copy(built)
        log(f"live-bench: {binary} (SHA-256 {file_sha256(binary)[:12]}, from {built})")
        with (folder / "logs" / "speech-assets.log").open("a", encoding="utf-8") as assets_log:
            subprocess.run(
                [str(binary), "speech-assets", "--install", "--models", str(args.models), "--fixtures", str(args.fixtures), "--out", str(args.out)],
                cwd=REPO, check=False, stdout=assets_log, stderr=subprocess.STDOUT,
            )
        runner = Runner(args.models, args.fixtures, args.out, binary, log, deadline, dry=dry)
        run_schedule(runner, state, steps, durations)
        write_reports(runner, state, steps)
        log("finished")
    finally:
        caffeinate.terminate()
        log_file.close()
    return 0


def dry_run(args: argparse.Namespace) -> int:
    """Runs the cut schedule in a worker, kills it during DryRun.kill_step,
    runs it again to the end, and checks what the night would rely on."""
    dry = DryRun()
    root = args.out / "dry-runs" / datetime.now().strftime("%Y%m%d-%H%M%S")
    (root / "overnight").mkdir(parents=True)
    worker = [
        sys.executable, str(Path(__file__).resolve()), "--dry-run-worker",
        "--models", str(args.models), "--fixtures", str(args.fixtures), "--out", str(root),
        *(["--allow-dirty"] if args.allow_dirty else []), *(["--live-bench", str(args.live_bench)] if args.live_bench else []),
    ]
    state_path = root / "overnight" / "state.json"
    started = time.monotonic()
    print(f"dry run in {root}", flush=True)

    first = subprocess.Popen(worker, cwd=Path(__file__).resolve().parent, start_new_session=True)
    killed_during = None
    while first.poll() is None:
        steps = read_json(state_path)["steps"] if state_path.exists() else {}
        if steps.get(dry.kill_step, {}).get("status") == "running":
            time.sleep(2)
            killed_during = read_json(state_path)["steps"][dry.kill_step]["status"]
            os.killpg(first.pid, signal.SIGKILL)
            first.wait()
            break
        time.sleep(0.5)
    print(f"dry run: first worker {'killed during ' + dry.kill_step if killed_during else 'ended by itself (exit ' + str(first.returncode) + ')'}", flush=True)
    second = subprocess.run(worker, cwd=Path(__file__).resolve().parent, check=False)
    minutes = (time.monotonic() - started) / 60

    checks = dry_run_checks(root, dry, killed_during, second.returncode)
    for passed, description in checks:
        print(f"{'PASS' if passed else 'FAIL'}  {description}")
    print(f"dry run took {minutes:.1f} min; {sum(passed for passed, _ in checks)} of {len(checks)} checks passed; folder {root}")
    return 0 if all(passed for passed, _ in checks) else 1


def dry_run_checks(root: Path, dry: DryRun, killed_during: str | None, exit_status: int) -> list[tuple[bool, str]]:
    """What a dry run must show before the night: every step type ran, and
    every failure path did what it should."""
    folder = root / "overnight"
    state = read_json(folder / "state.json")["steps"] if (folder / "state.json").exists() else {}
    log = (folder / "overnight.log").read_text(encoding="utf-8", errors="replace") if (folder / "overnight.log").exists() else ""
    ids = [step.id for step in schedule()]
    expected = {step_id: ("score-failed" if step_id == dry.score_failure_step else "done") for step_id in ids}
    wrong = [f"{step_id} {state.get(step_id, {}).get('status', 'missing')}" for step_id, status in expected.items() if state.get(step_id, {}).get("status") != status]
    reports = [folder / name for name in ("report-gated.md", "report-own-load.md", "report-diagnostics.md")]
    alongside = [path for path in (folder / "alongside").glob("*-final-pass*") if (path / "manifest.json").exists()]
    groups = {step.group for step in schedule()}
    return [
        (exit_status == 0, "the second worker finished (exit 0)"),
        (not wrong, "every step done, the forced scoring failure recorded" + (f"; wrong: {', '.join(wrong)}" if wrong else "")),
        (killed_during == "running" and state.get(dry.kill_step, {}).get("attempts") == 2, f"killed during {dry.kill_step}, which the restart ran again"),
        ("done earlier, skipped" in log, "the restart skipped the steps done before the kill"),
        (f"{dry.timeout_step}: timeout" in log and state.get(dry.timeout_step, {}).get("attempts") == 2, f"{dry.timeout_step} timed out once and passed on its retry"),
        (f"{dry.score_failure_step}: ran in" in log, f"{dry.score_failure_step}'s scoring failure was logged and the night went on"),
        ("SpeechAnalyzer variant" in log, "the SpeechAnalyzer variant rule chose a variant"),
        (f"{dry.score_failure_step} did not count, so this runs all" in log, "a completion whose recheck did not count ran all its calibration clips"),
        (
            "median CPU idle" in log and "CPU idle unreadable" not in log and "load average" in log,
            "CPU idle was measured, and logged with the load average, before each run",
        ),
        (bool(alongside), f"final passes ran alongside the back-to-back arm ({len(alongside)} started)"),
        ((folder / "logs" / "speech-assets.log").exists(), "speech-assets --install ran and was logged"),
        (all(path.exists() and path.read_text(encoding="utf-8").startswith(f"> {dry.label}") for path in reports), "all three reports were written and are labeled as a dry run"),
        ("AC power, Low Power Mode off" in log, "the power state was checked at the start and logged before each run"),
        (groups == {"own-load", "cost", "baseline", "validation", "soak", "calibration", "back-to-back", "extended"}, "the schedule has every step type"),
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--models", type=Path, default=os.environ.get("BENCH_LIVE_MODELS"))
    parser.add_argument("--fixtures", type=Path, default=os.environ.get("BENCH_LIVE_FIXTURES"))
    parser.add_argument("--out", type=Path, default=os.environ.get("BENCH_LIVE_OUT"))
    parser.add_argument("--hours", type=float, default=DEFAULT_HOURS, help="start no step that would end later than this after the first start")
    parser.add_argument("--reset-deadline", action="store_true", help="count --hours from now instead of from the first start")
    parser.add_argument("--plan", action="store_true", help="print the schedule and its estimated duration, and run nothing")
    parser.add_argument("--dry-run", action="store_true", help="check the whole schedule end to end in minutes, in <out>/dry-runs/")
    parser.add_argument("--dry-run-worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--allow-dirty", action="store_true", help="run with uncommitted changes or untracked files")
    parser.add_argument("--live-bench", type=Path, help="a release live-bench built from this checkout, instead of building one")
    args = parser.parse_args(argv)
    if not (args.models and args.fixtures and args.out):
        parser.error("set BENCH_LIVE_MODELS, BENCH_LIVE_FIXTURES and BENCH_LIVE_OUT, or pass --models, --fixtures and --out")
    if args.plan:
        print_plan(schedule(), clip_durations(args.fixtures), args.hours)
        return 0
    if args.dry_run:
        return dry_run(args)
    return run_night(args, DryRun() if args.dry_run_worker else None)


if __name__ == "__main__":
    sys.exit(main())
