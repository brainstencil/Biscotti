# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Analyze one chat measurement run from a capture of the unified log.

Biscotti Dev runs a plan from `plans/` when it starts with the launch argument
`-chatLoadTest <absolute path to plan.json>` (`ChatLoadDriver`, debug builds).
This script joins the driver's `chat-load` lines with the live transcript's
and the LLM broker's log lines, and writes `results/<RUN>.json` and
`results/<RUN>.md` (one Markdown table, also printed). README.md has the whole
procedure.

Capture (no sudo). Quit every copy of Biscotti Dev, start the capture, wait
two seconds, then start the app. Stop the capture with Ctrl-C after the driver
logs `plan-done` and the recording has stopped:

    /usr/bin/log stream --style ndjson --level info \\
      --predicate 'subsystem == "net.scosman.biscotti" AND processImagePath CONTAINS "Biscotti Dev.app"' \\
      > Tools/chat_bench/results/RUN.ndjson

    uv run Tools/chat_bench/analyze.py RUN --log Tools/chat_bench/results/RUN.ndjson

`log stream` carries no signposts, so the live transcript's figures come from
the info lines that debug builds of `LiveLatency` write. Run it outside the
agent sandbox (`log` refuses to run inside it).

Alternative, with sudo: persist info lines (and the signposts, for Instruments)
once, then read the range from the log store:

    sudo log config --subsystem net.scosman.biscotti --mode "level:info,persist:info,signpost-persisted:on"
    uv run Tools/chat_bench/analyze.py RUN --start '2026-10-29 10:00:00' --end '2026-10-29 10:20:00'

This saves the `log show` output as `results/<RUN>.ndjson` first.

Joined lines (subsystem `net.scosman.biscotti`):
- `chat-load`: the driver's plan, worker, recording, ask, skip, lease,
  first-token, done and memory lines (MiB).
- `llm-broker`: "Model opened: …" (a model load) and "Closing model connection: <reason>".
- `live`: "Live status: <status>", "A live decode has not returned …" (the
  stuck-decode watchdog ends the worker), "Restarting the live engine", "The
  live engine failed again" (live transcription stops) and "Live latency,
  whole session: …" (the session's counts, to check the capture is whole).
- `live.latency` (debug builds): `decode ms=<n>` per update,
  `chunks to=update|drawn s=<delays>` (each chunk's delay since it was taken,
  to the update that covered it or to the drawing that showed it), and
  `chunks dropped=<n> reason=<reason>` for chunks never measured.

Answer windows run from the lease's start (or the ask, when the answer never
got the model) to done. Memory is in GiB; "GB" in the budgets means GiB. The
memory rule uses the footprints' sum plus the AI worker's resident pages
beyond its footprint (`decision_memory`), during the recording only.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

SUBSYSTEM = "net.scosman.biscotti"
DEFAULT_PROCESS = "Biscotti Dev.app"
RESULTS = Path(__file__).resolve().parent / "results"

# The contention rule (components/chat_measurement.md, Decision Rule).
DECODE_LIMIT_MS = 5000
CATCH_UP_LIMIT_S = 30
# The live transcript reports catching up only once it is 10 s behind, so a
# catch-up that starts this soon after done (and before the next ask) counts.
CATCH_UP_GRACE_S = 10
# Each tier's memory budget (the Mac's memory minus 5 GB) and the model the
# app recommends there, as a tag in its GGUF file name: E2B below 24 GB.
BUDGETS = (("8 GB", 3, "e2b"), ("16 GB", 11, "e2b"), ("24 GB", 19, "12b"))
# A catch-up with no live status before its done.
UNKNOWN = "unknown"

PROCESSES = ("app", "transcriber", "llm")
MEASURES = ("footprint", "resident")
STAGES = ("drawn", "update")
KEY_VALUE = re.compile(r"(\w+)=(\S+)")
SESSION_COUNT = re.compile(r"(chunk to update|worker decode) (?:none|p50 [^;]*\((\d+)\))")
MODEL_OPENED = re.compile(r"Model opened: (.+) in \d+ ms")


class AnalysisError(Exception):
    pass


@dataclass
class Entry:
    """One log line (`kind == "log"`), a loss event (`"loss"`), or a capture
    line that did not decode (`"unreadable"`)."""

    time: float
    category: str
    message: str
    process: str = ""
    kind: str = "log"
    pid: int | None = None


@dataclass
class Answer:
    question: int
    ask: float
    lease: float | None = None
    loading: bool = False
    first_token: float | None = None
    done: float | None = None
    fields: dict[str, str] = field(default_factory=dict)
    error: str | None = None

    @property
    def window(self) -> tuple[float, float] | None:
        if self.done is None:
            return None
        return (self.ask if self.lease is None else self.lease, self.done)

    def number(self, key: str) -> float | None:
        value = self.fields.get(key, "-")
        return None if value == "-" else float(value)

    def count(self, key: str) -> int | None:
        value = self.number(key)
        return None if value is None else int(value)


# MARK: - Reading


def parse_time(text: str) -> float:
    return datetime.strptime(text, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()


def parse_entries(lines, process: str = DEFAULT_PROCESS) -> list[Entry]:
    """The subsystem's log lines from `log stream` or `log show`
    (`--style ndjson`), from processes whose image path contains `process`
    (all when empty), in time order; and every loss event and line that did
    not decode, such as the last line of a capture stopped mid-write."""
    entries = []
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            entries.append(Entry(time=0.0, category="", message="", kind="unreadable"))
            continue
        event_type = record.get("eventType")
        if event_type == "lossEvent":
            # Its shape in `log stream` is not documented: only the count matters.
            time = parse_time(record["timestamp"]) if "timestamp" in record else 0.0
            entries.append(Entry(time=time, category="", message=record.get("eventMessage", ""), kind="loss"))
            continue
        path = record.get("processImagePath", "")
        if event_type != "logEvent" or record.get("subsystem") != SUBSYSTEM or (process and process not in path):
            continue
        entries.append(Entry(
            time=parse_time(record["timestamp"]),
            category=record.get("category", ""),
            message=record.get("eventMessage", ""),
            process=path,
            pid=record.get("processID"),
        ))
    return sorted(entries, key=lambda entry: entry.time)


def read_log(start: str, end: str, process: str) -> str:
    """The alternative source: the log store, which keeps info lines only
    after `sudo log config … persist:info`."""
    predicate = f'subsystem == "{SUBSYSTEM}"'
    if process:
        predicate += f' AND processImagePath CONTAINS "{process}"'
    command = ["/usr/bin/log", "show", "--style", "ndjson", "--info",
               "--start", start, "--end", end, "--predicate", predicate]
    return subprocess.run(command, capture_output=True, text=True, check=True).stdout


def key_value_line(message: str) -> tuple[str, dict[str, str], str | None]:
    """A `chat-load` or `live.latency` line's kind, its key=value fields,
    and the text after `error=` or `path=` (both run to the end of the line)."""
    kind, _, rest = message.partition(" ")
    for key in ("error=", "path="):
        before, marker, tail = rest.partition(key)
        if marker:
            return kind, dict(KEY_VALUE.findall(before)), tail
    return kind, dict(KEY_VALUE.findall(rest)), None


# MARK: - Parsing


@dataclass
class Run:
    plans: list[dict[str, str]] = field(default_factory=list)
    workers: dict[str, str] = field(default_factory=dict)
    answers: dict[int, Answer] = field(default_factory=dict)
    skips: list[tuple[int, str]] = field(default_factory=list)
    not_sent: list[int] = field(default_factory=list)
    # (time, sample) pairs.
    memory: list[tuple[float, dict[str, float | None]]] = field(default_factory=list)
    # The first recording's start and stop, from the driver.
    recording_started: float | None = None
    recording_stopped: float | None = None
    statuses: list[tuple[float, str]] = field(default_factory=list)
    # Per stage: (time the chunk was taken, its delay in seconds).
    delays: dict[str, list[tuple[float, float]]] = field(default_factory=lambda: {stage: [] for stage in STAGES})
    decodes: list[tuple[float, float]] = field(default_factory=list)
    model_opens: list[float] = field(default_factory=list)
    model_closes: dict[str, int] = field(default_factory=dict)
    watchdog_resets: int = 0
    engine_restarts: int = 0
    engine_failures: int = 0
    # What the live sessions counted, from their "whole session" summaries.
    session_counts: dict[str, int] = field(default_factory=dict)
    # Chunks the live transcript never measured, by reason.
    dropped_chunks: dict[str, int] = field(default_factory=dict)
    model_files: list[str] = field(default_factory=list)
    plan_done: bool = False
    # The main app's processes (not its XPC workers) that wrote lines.
    app_pids: set[int] = field(default_factory=set)
    losses: int = 0
    unreadable: int = 0


def collect(entries: list[Entry]) -> Run:
    run = Run()
    for entry in entries:
        if entry.kind == "loss":
            run.losses += 1
            continue
        if entry.kind == "unreadable":
            run.unreadable += 1
            continue
        if entry.pid is not None and "/XPCServices/" not in entry.process:
            run.app_pids.add(entry.pid)
        if entry.category == "chat-load":
            collect_chat_load(run, entry)
        elif entry.category == "live.latency":
            collect_latency(run, entry)
        elif entry.category == "llm-broker":
            if match := MODEL_OPENED.match(entry.message):
                run.model_opens.append(entry.time)
                if match.group(1) not in run.model_files:
                    run.model_files.append(match.group(1))
            elif entry.message.startswith("Closing model connection: "):
                reason = entry.message.removeprefix("Closing model connection: ")
                run.model_closes[reason] = run.model_closes.get(reason, 0) + 1
        elif entry.category == "live":
            collect_live(run, entry)
    return run


def collect_live(run: Run, entry: Entry) -> None:
    message = entry.message
    if message.startswith("Live status: "):
        run.statuses.append((entry.time, message.removeprefix("Live status: ")))
    elif message.startswith("A live decode has not returned"):
        run.watchdog_resets += 1
    elif message.startswith("Restarting the live engine"):
        run.engine_restarts += 1
    elif message.startswith("The live engine failed again"):
        run.engine_failures += 1
    elif message.startswith("Live latency, whole session: "):
        for figure, count in SESSION_COUNT.findall(message):
            run.session_counts[figure] = run.session_counts.get(figure, 0) + int(count or 0)


def collect_latency(run: Run, entry: Entry) -> None:
    kind, fields, _ = key_value_line(entry.message)
    if kind == "decode" and "ms" in fields:
        run.decodes.append((entry.time, float(fields["ms"])))
    elif kind == "chunks" and fields.get("to") in STAGES:
        for delay in map(float, fields.get("s", "").split(",")):
            run.delays[fields["to"]].append((entry.time - delay, delay))
    elif kind == "chunks" and "dropped" in fields:
        reason = fields.get("reason", "?")
        run.dropped_chunks[reason] = run.dropped_chunks.get(reason, 0) + int(fields["dropped"])


def collect_chat_load(run: Run, entry: Entry) -> None:
    kind, fields, tail = key_value_line(entry.message)
    question = int(fields["q"]) if fields.get("q", "-") != "-" else None
    answer = run.answers.get(question) if question is not None else None
    match kind:
        case "plan":
            run.plans.append(fields)
        case "plan-done":
            run.plan_done = True
        case "recording-started" if run.recording_started is None:
            run.recording_started = entry.time
        case "recording-stopped" if run.recording_started is not None and run.recording_stopped is None:
            run.recording_stopped = entry.time
        case "worker":
            run.workers[fields.get("name", "?")] = tail or "missing"
        case "memory":
            keys = [*PROCESSES, *(f"{name}Resident" for name in PROCESSES)]
            run.memory.append((entry.time, {key: None if fields.get(key, "-") == "-" else float(fields[key]) for key in keys}))
        case "ask" if question is not None:
            run.answers[question] = Answer(question=question, ask=entry.time)
        case "skip" if question is not None:
            run.skips.append((question, fields.get("reason", "?")))
        case "not-sent" if question is not None:
            # Its question was never saved, so it was not asked.
            run.answers.pop(question, None)
            run.not_sent.append(question)
        case "lease" if answer is not None:
            answer.lease = entry.time
            answer.loading = fields.get("loading") == "true"
        case "first-token" if answer is not None:
            answer.first_token = entry.time
        case "done" if answer is not None:
            answer.done = entry.time
            answer.fields = fields
            answer.error = tail


# MARK: - Measures


def median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def percentile(values: list[float], fraction: float) -> float | None:
    """Nearest rank."""
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(1, math.ceil(fraction * len(ordered))) - 1]


def next_live(after: float, statuses: list[tuple[float, str]]) -> float | None:
    return next((time for time, status in statuses if time > after and status == "live"), None)


def catch_up(done: float, statuses: list[tuple[float, str]], until: float) -> float | str | None:
    """Seconds from done until the live transcript is live again.

    Zero when it was live (or off, after Stop) at done and did not start
    catching up between done and `until`. Otherwise the time to the next
    "live"; None when that never comes in the range. `UNKNOWN` when no
    status came before done."""
    before = [status for time, status in statuses if time <= done]
    if not before:
        return UNKNOWN
    if before[-1] in ("live", "off"):
        started = next((time for time, status in statuses if done < time <= until and status == "catchingUp"), None)
        if started is None:
            return 0.0
        live = next_live(started, statuses)
    else:
        live = next_live(done, statuses)
    return None if live is None else live - done


def distribution(values: list[float]) -> dict:
    return {"median": median(values), "p95": percentile(values, 0.95), "count": len(values)}


def memory_summary(samples: list[dict[str, float | None]]) -> dict:
    """Per measure (footprint, resident): each process's and the sum's peak
    and median, in MiB."""
    summary = {}
    for measure in MEASURES:
        keys = {name: name if measure == "footprint" else f"{name}Resident" for name in PROCESSES}
        figures = {}
        for name, key in keys.items():
            values = [sample[key] for sample in samples if sample[key] is not None]
            figures[name] = {"peakMiB": max(values, default=None), "medianMiB": median(values)}
        sums = [sum(sample[key] for key in keys.values() if sample[key] is not None) for sample in samples]
        figures["sum"] = {"peakMiB": max(sums, default=None), "medianMiB": median(sums)}
        summary[measure] = figures
    decision = [decision_memory(sample) for sample in samples]
    summary["decision"] = {"peakMiB": max(decision, default=None), "medianMiB": median(decision)}
    summary["samples"] = len(samples)
    return summary


def decision_memory(sample: dict[str, float | None]) -> float:
    """The figure the memory rule uses: the footprints' sum plus the AI
    worker's resident pages beyond its footprint. Those are the model weights
    llama.cpp maps from the GGUF file, which the footprint leaves out. Summed
    resident sizes would count the shared system libraries three times."""
    footprints = sum(sample[name] for name in PROCESSES if sample[name] is not None)
    llm, llm_resident = sample["llm"], sample["llmResident"]
    mapped = max(0.0, llm_resident - llm) if llm is not None and llm_resident is not None else 0.0
    return footprints + mapped


def analyze(entries: list[Entry], run_name: str) -> dict:
    run = collect(entries)
    if len(run.plans) > 1:
        raise AnalysisError(f"the range holds {len(run.plans)} chat load plans; narrow it to one run")
    plan = run.plans[0] if run.plans else {}
    answers = sorted(run.answers.values(), key=lambda answer: answer.question)
    windows = [answer.window for answer in answers if answer.window]

    def inside(start: float, end: float) -> bool:
        return any(start <= window_end and end >= window_start for window_start, window_end in windows)

    # The engine's start and its first backlog are not the steady state.
    first_live = next_live(-math.inf, run.statuses)
    settled = (lambda time: time >= first_live) if first_live is not None else (lambda time: True)
    live_delay = {}
    for stage in STAGES:
        delays = [(taken, delay) for taken, delay in run.delays[stage] if settled(taken)]
        live_delay[stage] = {
            "inside": distribution([delay for taken, delay in delays if inside(taken, taken)]),
            "outside": distribution([delay for taken, delay in delays if not inside(taken, taken)]),
        }
    decodes = [(time - ms / 1000, time, ms) for time, ms in run.decodes if settled(time)]
    decodes_inside = [ms for start, end, ms in decodes if inside(start, end)]
    decodes_outside = [ms for start, end, ms in decodes if not inside(start, end)]

    rows = [answer_row(answer, answers, run) for answer in answers]
    catch_ups = [row["catchUpSeconds"] for row in rows if row["done"]]
    # An unknown catch-up is not "never": it is left out of the median.
    known = [math.inf if value is None else value for value in catch_ups if value != UNKNOWN]
    catch_up_median = median(known)
    # The memory rule is about the recording: the final pass and the summary
    # after Stop run whether or not anyone asks.
    memory = memory_summary([sample for time, sample in run.memory if during_recording(time, run)])
    after_stop = memory_summary([sample for time, sample in run.memory if after_stop_time(time, run)])
    cited = sum(answer.count("cited") or 0 for answer in answers)
    linked = sum(answer.count("linked") or 0 for answer in answers)
    longest_inside = max(decodes_inside, default=None)
    missing = incomplete(run, answers, plan)
    if not run.statuses:
        missing.append("no live status lines in the range")
    else:
        missing += [f"the catch-up after question {row['question']} is unknown: no live status came before its done"
                    for row in rows if row["catchUpSeconds"] == UNKNOWN]
    if windows and not decodes_inside:
        missing.append("no live decode lines in the answer windows")

    return {
        "run": run_name,
        "plan": plan,
        "range": range_of(entries),
        "questions": {
            "planned": int(plan.get("questions", len(answers))),
            "asked": len(answers),
            "skipped": [{"question": question, "reason": reason} for question, reason in run.skips],
            "notSent": run.not_sent,
        },
        "answers": rows,
        "recording": {"started": run.recording_started is not None, "stopped": run.recording_stopped is not None},
        "memory": memory,
        "memoryAfterStop": {"decision": after_stop["decision"], "samples": after_stop["samples"]},
        "memoryBudgets": memory_budgets(memory["decision"]["peakMiB"], run.model_files),
        "liveDelaySeconds": live_delay,
        "liveChunksDropped": run.dropped_chunks,
        "longestDecodeMs": {"inside": longest_inside, "outside": max(decodes_outside, default=None)},
        "watchdogResets": run.watchdog_resets,
        "engineRestarts": run.engine_restarts,
        "engineFailures": run.engine_failures,
        "catchUpSeconds": {"median": "never" if catch_up_median == math.inf else catch_up_median, "perAnswer": catch_ups},
        "timeToFirstTokenSeconds": {
            "cold": [row["timeToFirstTokenSeconds"] for row in rows if row["cold"] and row["timeToFirstTokenSeconds"] is not None],
            "warm": [row["timeToFirstTokenSeconds"] for row in rows if not row["cold"] and row["timeToFirstTokenSeconds"] is not None],
        },
        "tokensPerSecond": {"median": median([row["tokensPerSecond"] for row in rows if row["tokensPerSecond"] is not None])},
        "citations": {"cited": cited, "linked": linked, "validity": linked / cited if cited else None},
        "outcomes": {"failed": sum(row["outcome"] == "failed" for row in rows), "partial": sum(row["partial"] is True for row in rows)},
        "model": {
            "loadsDuringRecording": sum(during_recording(time, run) for time in run.model_opens),
            "loadsOutsideRecording": sum(not during_recording(time, run) for time in run.model_opens),
            "files": run.model_files,
            "closes": run.model_closes,
        },
        "warnings": warnings(run, answers, plan),
        "contention": contention(
            answers, resets=run.watchdog_resets, engine_failures=run.engine_failures,
            longest_decode_ms=longest_inside, catch_up_median=catch_up_median, missing=missing,
        ),
    }


def during_recording(time: float, run: Run) -> bool:
    """Inside the driver's first recording; the whole capture when its start
    is not in the capture."""
    started = run.recording_started if run.recording_started is not None else -math.inf
    stopped = run.recording_stopped if run.recording_stopped is not None else math.inf
    return started <= time <= stopped


def after_stop_time(time: float, run: Run) -> bool:
    return run.recording_stopped is not None and time > run.recording_stopped


def incomplete(run: Run, answers: list[Answer], plan: dict[str, str]) -> list[str]:
    """Signs that the run ended early, which make the contention rule
    undetermined: the figures cover only part of the plan."""
    found = []
    if not plan:
        found.append("no plan line: start the capture before the app")
    elif not run.plan_done:
        found.append("no plan-done line: the app quit or the capture ended early")
    accounted = len(answers) + len(run.skips) + len(run.not_sent)
    if plan and accounted < int(plan.get("questions", 0)):
        found.append(f"only {accounted} of {plan['questions']} questions were asked, skipped or not sent: "
                     "the app quit or the capture ended early")
    found += [f"question {answer.question} has no done line: the app quit or the capture ended early"
              for answer in answers if answer.done is None]
    return found


def memory_budgets(peak_mib: float | None, model_files: list[str]) -> list[dict]:
    """Whether the decision figure's peak fits each tier's budget. A tier's
    row applies to this run when the run loaded the model that tier uses."""
    return [
        {
            "mac": mac, "budgetGB": budget, "model": model.upper(),
            "appliesToThisRun": any(model in file.lower() for file in model_files) if model_files else None,
            "fits": None if peak_mib is None else peak_mib / 1024 <= budget,
        }
        for mac, budget, model in BUDGETS
    ]


def model_loaded_during(answer: Answer, run: Run) -> bool:
    end = answer.first_token or answer.done or math.inf
    return any(answer.ask <= time <= end for time in run.model_opens)


def answer_row(answer: Answer, answers: list[Answer], run: Run) -> dict:
    first, done = answer.first_token, answer.done
    tokens = answer.count("tokens") or 0
    generated, generation_seconds = answer.count("generated"), answer.number("generationSeconds")
    if generated and generation_seconds:
        rate = generated / generation_seconds
    elif first is not None and done is not None and tokens >= 2 and done > first:
        rate = (tokens - 1) / (done - first)
    else:
        rate = None
    next_ask = min((other.ask for other in answers if done is not None and other.ask > done), default=math.inf)
    partial = answer.fields.get("partial", "-")
    return {
        "question": answer.question,
        "outcome": answer.fields.get("outcome", "unfinished"),
        "error": answer.error,
        "done": done is not None,
        "cold": answer.loading or model_loaded_during(answer, run),
        "timeToFirstTokenSeconds": None if first is None else first - answer.ask,
        "tokensPerSecond": rate,
        "windowSeconds": None if answer.window is None else answer.window[1] - answer.window[0],
        "catchUpSeconds": None if done is None else catch_up(done, run.statuses, min(done + CATCH_UP_GRACE_S, next_ask)),
        "promptTokens": answer.count("promptTokens"),
        "contextSize": answer.count("context"),
        "partial": None if partial == "-" else partial == "true",
        "tokens": tokens,
        "generatedTokens": generated,
        "cited": answer.count("cited"),
        "linked": answer.count("linked"),
    }


def warnings(run: Run, answers: list[Answer], plan: dict[str, str]) -> list[str]:
    """Signs that the capture or the setup lost something the figures need."""
    found = incomplete(run, answers, plan)
    if run.recording_started is None:
        found.append("no recording-started line: the memory figures and model loads cover the whole capture")
    found += unread_workers(run)
    if len(run.app_pids) > 1:
        found.append(f"lines come from {len(run.app_pids)} Biscotti Dev processes: quit every other copy before a run")
    for answer in answers:
        if answer.loading and not model_loaded_during(answer, run):
            found.append(f"question {answer.question} loaded the model, but no 'Model opened' line is in the range: "
                         "info lines are missing, so the model-load count is wrong")
    for name, path in sorted(run.workers.items()):
        if path == "missing":
            found.append(f"the {name} worker was not found, so its memory is not in the sum")
    if run.losses:
        found.append(f"the log reported dropped messages {plural(run.losses, 'time')}, so figures may be incomplete")
    if run.unreadable:
        found.append(f"{plural(run.unreadable, 'capture line')} did not decode (a capture stopped mid-write cuts its last line)")
    captured = {"worker decode": len(run.decodes), "chunk to update": len(run.delays["update"])}
    for figure, logged in sorted(run.session_counts.items()):
        if captured[figure] < logged:
            found.append(f"the live session counted {logged} for '{figure}', but only {captured[figure]} are in the range")
    return found


def unread_workers(run: Run) -> list[str]:
    """Workers whose memory was never read when they must have run: the
    speech worker during the recording, the AI worker after the first lease.
    The memory rule's sum then leaves them out."""
    found = []
    recording = [sample for time, sample in run.memory if during_recording(time, run)]
    if recording and all(sample["transcriber"] is None for sample in recording):
        found.append("the transcriber's memory was never read during the recording, so the sum leaves it out")
    leases = [answer.lease for answer in run.answers.values() if answer.lease is not None]
    after_lease = [sample for time, sample in run.memory if leases and time >= min(leases)]
    if after_lease and all(sample["llm"] is None for sample in after_lease):
        found.append("the llm worker's memory was never read after the first lease, so the sum leaves it out")
    return found


def contention(answers: list[Answer], *, resets: int = 0, engine_failures: int = 0, longest_decode_ms: float | None = None,
               catch_up_median: float | None = None, missing: list[str] = ()) -> dict:
    """The default (no pause) stands if there are no watchdog resets, no decode
    inside an answer takes 5 s, and the median catch-up is under 30 s. It
    fails if live transcription stopped, and is undetermined (None) when the
    figures it needs are missing."""
    if not answers:
        return {"passes": None, "reasons": ["no answers"]}
    reasons = []
    if resets:
        reasons.append(f"{resets} watchdog reset{'s' if resets > 1 else ''}")
    if engine_failures:
        reasons.append("live transcription stopped: the live engine failed twice")
    if longest_decode_ms is not None and longest_decode_ms >= DECODE_LIMIT_MS:
        reasons.append(f"a decode inside an answer took {longest_decode_ms / 1000:.1f} s")
    if catch_up_median is not None and catch_up_median >= CATCH_UP_LIMIT_S:
        reasons.append("the median catch-up is 30 s or more" if catch_up_median != math.inf else "the live transcript never caught up after most answers")
    if reasons:
        return {"passes": False, "reasons": reasons}
    if missing:
        return {"passes": None, "reasons": list(missing)}
    return {"passes": True, "reasons": []}


def range_of(entries: list[Entry]) -> dict:
    def iso(time: float) -> str:
        return datetime.fromtimestamp(time).astimezone().isoformat(timespec="seconds")

    lines = [entry for entry in entries if entry.kind == "log"]
    return {"first": iso(lines[0].time), "last": iso(lines[-1].time)} if lines else {}


# MARK: - Markdown


def seconds(value: float | str | None, digits: int = 1) -> str:
    if isinstance(value, str):
        return value
    return "–" if value is None else f"{value:.{digits}f} s"


def gigabytes(mebibytes: float | None) -> str:
    return "–" if mebibytes is None else f"{mebibytes / 1024:.2f} GB"


def plural(count: int, noun: str) -> str:
    return f"{count} {noun}{'' if count == 1 else 's'}"


def delay_text(stats: dict) -> str:
    if not stats["count"]:
        return "no chunks"
    return f"median {seconds(stats['median'])}, p95 {seconds(stats['p95'])} ({plural(stats['count'], 'chunk')})"


def memory_rows(memory: dict, after_stop: dict) -> list[tuple[str, str]]:
    """The recording's figures, and the rule's figure after Stop for reference."""
    def peak_and_median(figures: dict) -> str:
        return f"peak {gigabytes(figures['peakMiB'])}, median {gigabytes(figures['medianMiB'])}"

    return [
        *[(f"Memory during the recording, {label}",
           f"footprint {peak_and_median(memory['footprint'][name])}; resident {peak_and_median(memory['resident'][name])}")
          for name, label in (("app", "app"), ("transcriber", "speech worker"), ("llm", "AI worker"), ("sum", "sum"))],
        ("Memory for the rule (footprints + AI worker's mapped weights)", peak_and_median(memory["decision"])),
        ("Same figure after Stop (final pass and summary; not for the rule)", peak_and_median(after_stop["decision"])),
    ]


def markdown(result: dict) -> str:
    plan = result["plan"]
    questions = result["questions"]
    live = result["liveDelaySeconds"]
    decode = result["longestDecodeMs"]
    first_token = result["timeToFirstTokenSeconds"]
    citations = result["citations"]
    contention_result = result["contention"]
    model = result["model"]
    closes_after_answer = {"true": "yes", "false": "no"}.get(plan.get("closeModelAfterAnswer", "-"), "as this Mac's policy")
    closes = ", ".join(f"{reason} {count}" for reason, count in sorted(model["closes"].items())) or "none"
    files = ", ".join(model["files"]) or "no model file named"
    dropped = ", ".join(f"{reason} {count}" for reason, count in sorted(result["liveChunksDropped"].items())) or "none"

    def budget_text(budget: dict) -> str:
        fits = "–" if budget["fits"] is None else "fits" if budget["fits"] else "over"
        applies = " (this run's model)" if budget["appliesToThisRun"] else ""
        return f"{budget['mac']} Mac, {budget['model']} ({budget['budgetGB']} GB): {fits}{applies}"

    budgets = "; ".join(budget_text(budget) for budget in result["memoryBudgets"])
    not_asked = [f"q{skip['question']} skipped ({skip['reason']})" for skip in questions["skipped"]]
    not_asked += [f"q{question} not sent" for question in questions["notSent"]]
    catch_ups = ", ".join(
        value if isinstance(value, str) else "never" if value is None else f"{value:.1f}"
        for value in result["catchUpSeconds"]["perAnswer"]
    )
    validity = citations["validity"]
    verdict = {None: "undetermined", True: "passes", False: "fails"}[contention_result["passes"]]
    if contention_result["reasons"]:
        verdict += f" ({'; '.join(contention_result['reasons'])})"
    rows = [
        ("Plan", f"{plan.get('name', '–')}, mode {plan.get('mode', '–')}, model closed after each answer: {closes_after_answer}"),
        ("Questions asked", f"{questions['asked']} of {questions['planned']}" + (f" ({'; '.join(not_asked)})" if not_asked else "")),
        ("Model loads", f"{model['loadsDuringRecording']} during the recording, {model['loadsOutsideRecording']} outside it: "
                        f"{files} (closes: {closes})"),
        *memory_rows(result["memory"], result["memoryAfterStop"]),
        ("Rule figure's peak against budgets", budgets),
        *[(f"Live delay {where} answers, to {stage}", delay_text(live[stage][where]))
          for stage in STAGES for where in ("inside", "outside")],
        ("Live chunks not measured", dropped),
        ("Longest live decode inside answers", seconds(None if decode["inside"] is None else decode["inside"] / 1000, 2)),
        ("Longest live decode outside answers", seconds(None if decode["outside"] is None else decode["outside"] / 1000, 2)),
        ("Watchdog resets", str(result["watchdogResets"])),
        ("Live engine restarts / failures", f"{result['engineRestarts']} / {result['engineFailures']}"),
        ("Catch-up after answers", f"median {seconds(result['catchUpSeconds']['median'])}; per answer (s): {catch_ups or '–'}"),
        ("Time to first token, cold", ", ".join(seconds(value) for value in first_token["cold"]) or "–"),
        ("Time to first token, warm", f"median {seconds(median(first_token['warm']))} ({plural(len(first_token['warm']), 'answer')})"),
        ("Tokens per second", "–" if result["tokensPerSecond"]["median"] is None else f"median {result['tokensPerSecond']['median']:.1f}"),
        ("Citation validity", f"{citations['linked']} of {citations['cited']}" + ("" if validity is None else f" ({validity:.0%})")),
        ("Failed / partial answers", f"{result['outcomes']['failed']} failed, {result['outcomes']['partial']} partial"),
        ("Warnings", "; ".join(result["warnings"]) or "none"),
        ("Contention rule", verdict),
    ]
    lines = [f"### {result['run']}", "", "| Measure | Value |", "|---|---|"]
    lines += [f"| {name} | {value} |" for name, value in rows]
    return "\n".join(lines) + "\n"


# MARK: - Command line


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Analyze one chat measurement run from a capture of the unified log.")
    parser.add_argument("run", help="the run's name, used for the result files")
    parser.add_argument("--log", type=Path, help="the run's `log stream --style ndjson` capture")
    parser.add_argument("--start", help="instead of --log: the run's start, as `log show` takes it (needs persisted info lines)")
    parser.add_argument("--end", help="instead of --log: the run's end, as `log show` takes it")
    parser.add_argument("--out", type=Path, default=RESULTS, help="where the result files go")
    parser.add_argument("--process", default=DEFAULT_PROCESS, help="keep lines from processes whose path contains this")
    args = parser.parse_args(argv)
    if not args.log and not (args.start and args.end):
        parser.error("give --log, or --start and --end")
    args.out.mkdir(parents=True, exist_ok=True)

    if args.log:
        text = args.log.read_text()
    else:
        text = read_log(args.start, args.end, args.process)
        (args.out / f"{args.run}.ndjson").write_text(text)

    try:
        result = analyze(parse_entries(text.splitlines(), args.process), args.run)
    except AnalysisError as error:
        print(f"analyze.py: {error}", file=sys.stderr)
        return 1
    for warning in result["warnings"]:
        print(f"analyze.py: warning: {warning}", file=sys.stderr)
    table = markdown(result)
    (args.out / f"{args.run}.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    (args.out / f"{args.run}.md").write_text(table)
    print(table)
    return 0


if __name__ == "__main__":
    sys.exit(main())
