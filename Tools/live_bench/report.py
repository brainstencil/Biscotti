"""Apply the four gates to scored live-bench runs and write report.md.

    uv run python report.py --runs RESULTS_FOLDER [RESULTS_FOLDER ...] --out report.md

Score each folder first (score.py writes metrics.json). Every folder must
have been scored against the same fixtures lock. Live runs are grouped by
configuration (option, model, interval, mode, load, clock, vocabulary, work
alongside, the Whisper prompt and, for SpeechAnalyzer, fast results) and
their clips pooled. Latency and
accuracy are gated on the validation clips when there are any, otherwise
on the clips given, and every gate line names the clips and splits behind
it. Soak clips go to the endurance gate. The accuracy baseline comes only
from final-pass folders that used the app's final-pass model. A clip whose
session failed, stopped short of the end or ran out of time finishing
fails every gate it feeds, and so does a clip the run never finished
(score.py records it as missing). Runs with a virtual clock, with
vocabulary on or with other work alongside (`live-bench run --alongside`,
such as the back-to-back arm's final pass) are reported as diagnostics,
not gated. Recording safety is measured by the writer test in
AudioCaptureTests, not here.

Other work on the Mac, and Low Power Mode, skew real-time latency, and
differently from run to run. A run that started in Low Power Mode, or whose
30 s baseline, taken before the engine loads, had a median CPU idle under
BUSY_CPU_IDLE, or that recorded no CPU idle, is left out of the gates; a
configuration with only such runs is reported as a diagnostic. The busy
test reads CPU idle, not the 1-minute load average: the load average
counts runnable threads; Spotlight and mediaanalysisd run at background
priority, which on Apple silicon uses only the two efficiency cores, so
their queue raises it while the performance cores stay idle. At night,
Spotlight (mds_stores, corespotlightd) and mediaanalysisd kept it at 15 to
20 for hours while the CPU stayed 65 to 75% idle. The runs table still
shows both for the baseline and the replay. The
load while the clips replayed includes the engine's own work, so it is shown
but never used to exclude a run. Runs of one configuration repeat its clips:
every repetition counts in the gates, and the runs table shows each run's
numbers and load, and the spread between gated runs of the same clips.

The latency share counts matched words only: a word never shown correctly is
already an accuracy error. Coverage is shown beside it.

The thresholds are frozen in GATES. The latency and accuracy values are the
functional spec's. The endurance values turn its "never falls further and
further behind" and "never stays at a serious heat level" into numbers; they
are frozen here and will be recorded in the phase 5 research document
(specs/research/live_transcription/README.md). Never change one to fit a result.
"""

from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from types import MappingProxyType

from make_fixtures import SPLITS, read_json
from score import LAG_WINDOW_SECONDS, pooled_wer

GATES = MappingProxyType({
    "latency": MappingProxyType({
        "share": 0.95,
        "first_display_seconds": 3.0,
        "settled_seconds": 5.0,
        "slower_first_display_seconds": 5.0,
        "slower_settled_seconds": 8.0,
    }),
    "accuracy": MappingProxyType({
        "max_wer": 0.20,
        "max_wer_above_final": 0.03,
        "min_critical_survival": 0.95,
    }),
    "endurance": MappingProxyType({
        "max_added_memory_bytes": 3 * 1024**3,
        "max_lag_growth_seconds": 5.0,
        "max_first_display_growth_seconds": 5.0,
        "max_overflow_gaps": 0,
        "max_serious_thermal_seconds": 60.0,
    }),
})
CALL_LOAD = "simulated call load"
# A run is busy when other work already used the CPU in the baseline, with
# simulated call load running and before the engine loads: under half the
# CPU time idle, over all cores (live-bench's ResourceSampler reads
# host_statistics once a second; score.py takes the median). The 1-minute
# load average is shown but does not decide: it counts runnable threads;
# Spotlight and mediaanalysisd run at background priority, which on Apple
# silicon uses only the two efficiency cores, so their queue raises it while
# the performance cores stay idle. At night, Spotlight (mds_stores,
# corespotlightd) and mediaanalysisd kept it at 15 to 20 for hours while the
# CPU stayed 65 to 75% idle, which would have left every run out.
BUSY_CPU_IDLE = 0.5
SIXTEEN_GB = 16 * 1024**3

PASS, SLOWER, FAIL, NOT_MEASURED, DIAGNOSTIC = "pass", "slower tier", "fail", "not measured", "diagnostic"


class ReportError(RuntimeError):
    pass


def clip_id(key: str, entry: dict) -> str:
    """The fixture clip behind a pooled entry; a repeated clip's key also names its run."""
    return entry.get("clip", key)


def clip_label(clips: dict, missing: dict | None = None) -> str:
    """The clips behind a verdict, e.g. "6 validation clips, 2 runs each"."""
    splits = {clip_id(key, entry): entry["split"] for key, entry in clips.items()} | dict(missing or {})
    counts = Counter(splits.values())
    parts = [f"{counts[split]} {split} clip{'' if counts[split] == 1 else 's'}" for split in SPLITS if counts[split]]
    repeats = Counter(clip_id(key, entry) for key, entry in clips.items()).values()
    if repeats and max(repeats) > 1:
        parts.append(f"{max(repeats)} runs each" if min(repeats) == max(repeats) else f"up to {max(repeats)} runs each")
    return ", ".join(parts) or "no clips"


def gated_clips(clips: dict, missing: dict) -> tuple[dict, dict]:
    """The validation clips, scored and missing, when the runs asked for any;
    otherwise every clip given."""
    if "validation" not in [entry["split"] for entry in clips.values()] + list(missing.values()):
        return clips, missing
    return (
        {clip: entry for clip, entry in clips.items() if entry["split"] == "validation"},
        {clip: split for clip, split in missing.items() if split == "validation"},
    )


def session_problems(clips: dict) -> list[str]:
    """Clips whose session failed, stopped before the end or ran out of time finishing."""
    problems = []
    for clip, entry in sorted(clips.items()):
        finish, lag = entry["finish"], entry["lag"]
        if finish["session_ended_early"]:
            problems.append(f"{clip}: the session failed")
        elif not lag["reached_end"]:
            problems.append(f"{clip}: transcription stopped at {lag['transcribed_through']:.0f} s of {entry['duration']:.0f} s")
        if finish["incomplete_rows"]:
            problems.append(f"{clip}: {finish['incomplete_rows']} rows incomplete at the finish deadline")
    return problems


def checked(gate: dict, clips: dict, missing: dict) -> dict:
    """The gate, failed when any of its clips' sessions went wrong or never
    finished, and labeled with its clips."""
    if not clips and not missing:
        return gate
    problems = session_problems(clips) + [f"{clip}: no result; the run stopped before it finished" for clip in sorted(missing)]
    if problems:
        gate["result"] = FAIL
    gate["measured"] = f"{clip_label(clips, missing)}: " + "; ".join([gate["measured"], *problems])
    return gate


def config_key(options: dict, model: str | None) -> tuple:
    return (
        options.get("option"),
        model,
        options.get("interval"),
        options.get("mode"),
        options.get("load"),
        options.get("clock"),
        options.get("vocabulary"),
        options.get("fast_results"),
        options.get("alongside"),
        options.get("whisper_prompt"),
        options.get("clip_seconds"),
        options.get("baseline_seconds"),
    )


def config_title(key: tuple) -> str:
    option, model, interval, mode, load, clock, vocabulary, fast_results, alongside, whisper_prompt, clip_seconds, baseline_seconds = key
    interval_text = f"{interval:g} s" if isinstance(interval, (int, float)) else str(interval)
    engine = f"{option} ({model})" if model else option
    if whisper_prompt is not None:
        engine += f" · prompt: {whisper_prompt}"
    if fast_results is not None:
        engine += f" · fast results: {'on' if fast_results else 'off'}"
    title = f"{engine} · every {interval_text} · {mode} · load: {load} · clock: {clock} · vocabulary: {'on' if vocabulary else 'off'}"
    title += f" · alongside: {alongside}" if alongside else ""
    if clip_seconds or baseline_seconds:
        cuts = [f"clips cut to {clip_seconds:g} s" if clip_seconds else None, f"baseline {baseline_seconds} s" if baseline_seconds else None]
        title += " · dry run: " + ", ".join(cut for cut in cuts if cut)
    return title


def share_within(values: list, index: int, limit: float) -> float | None:
    if not values:
        return None
    return sum(1 for pair in values if pair[index] is not None and pair[index] <= limit) / len(values)


def latency_gate(clips: dict) -> dict:
    gate = GATES["latency"]
    values = [pair for clip in clips.values() for pair in clip["latency"]["values"]]
    if not values:
        return {"result": NOT_MEASURED, "measured": "no matched words"}
    matched = sum(clip["latency"]["matched"] for clip in clips.values())
    scored = matched + sum(clip["latency"]["unmatched"] for clip in clips.values())
    shares = {
        "first": share_within(values, 0, gate["first_display_seconds"]),
        "settled": share_within(values, 1, gate["settled_seconds"]),
        "slower_first": share_within(values, 0, gate["slower_first_display_seconds"]),
        "slower_settled": share_within(values, 1, gate["slower_settled_seconds"]),
    }
    if shares["first"] >= gate["share"] and shares["settled"] >= gate["share"]:
        result = PASS
    elif shares["slower_first"] >= gate["share"] and shares["slower_settled"] >= gate["share"]:
        result = SLOWER
    else:
        result = FAIL
    measured = (
        f"{shares['first']:.1%} shown ≤ {gate['first_display_seconds']:g} s, {shares['settled']:.1%} settled ≤ {gate['settled_seconds']:g} s "
        f"({shares['slower_first']:.1%} / {shares['slower_settled']:.1%} within {gate['slower_first_display_seconds']:g} s / {gate['slower_settled_seconds']:g} s); "
        f"{len(values)} matched words, coverage {matched / scored:.1%} of {scored} scored words"
    )
    return {"result": result, "measured": measured, "shares": shares}


def accuracy_gate(clips: dict, baseline: dict) -> dict:
    gate = GATES["accuracy"]
    live = pooled_wer([clip["wer"] for clip in clips.values()])
    critical_total = sum(clip["critical"]["total"] for clip in clips.values())
    survival = sum(clip["critical"]["survived"] for clip in clips.values()) / critical_total if critical_total else None
    ids = [clip_id(key, entry) for key, entry in clips.items()]
    missing = sorted(set(ids) - set(baseline))
    final = pooled_wer([baseline[clip]["wer"] for clip in ids]) if not missing else None
    if live["wer"] is None:
        return {"result": NOT_MEASURED, "measured": "no scored reference words"}
    parts = [f"WER {live['wer']:.1%}"]
    if final is not None and final["wer"] is not None:
        parts.append(f"final pass {final['wer']:.1%} ({100 * (live['wer'] - final['wer']):+.1f} points)")
    else:
        parts.append(f"no final-pass baseline for {', '.join(missing)}")
    parts.append("critical words " + ("n/a" if survival is None else f"{survival:.1%} of {critical_total}"))
    failed = live["wer"] > gate["max_wer"] or (survival is not None and survival < gate["min_critical_survival"])
    if final is not None and final["wer"] is not None:
        failed = failed or live["wer"] - final["wer"] > gate["max_wer_above_final"]
        result = FAIL if failed else PASS
    else:
        result = FAIL if failed else NOT_MEASURED
    return {"result": result, "measured": "; ".join(parts), "wer": live["wer"], "final_wer": None if final is None else final["wer"]}


def endurance_gate(soak: dict, runs: list[dict]) -> dict:
    gate = GATES["endurance"]
    if not soak:
        return {"result": NOT_MEASURED, "measured": "no soak clip"}
    stopped = sorted(clip for clip, entry in soak.items() if entry["lag"].get("first_display_stopped"))
    if stopped:
        minutes = LAG_WINDOW_SECONDS / 60
        return {"result": FAIL, "measured": f"text stopped: no word spoken in the last {minutes:g} minutes of {', '.join(stopped)} was shown"}
    # Memory and heat come only from the runs that replayed a soak clip.
    soak_runs = [run for run in runs if any(entry["split"] == "soak" for entry in run["clips"].values())]
    if any(run["run"]["options"].get("load") != CALL_LOAD for run in soak_runs):
        return {"result": NOT_MEASURED, "measured": "the soak ran without --load call"}
    growths = [clip["lag"]["growth"] for clip in soak.values()]
    # Lag follows transcribed-through, which for SpeechAnalyzer is the audio
    # it accepted; first-display growth sees a backlog in any engine.
    display_growths = [clip["lag"].get("first_display_growth") for clip in soak.values()]
    overflow = sum(clip["gaps"].get("queueOverflow", {}).get("count", 0) for clip in soak.values())
    resources = [run.get("resources") for run in soak_runs]
    if None in resources:
        return {"result": NOT_MEASURED, "measured": "no resource samples for the soak"}
    added = max((entry["max_added_bytes"] for entry in resources if entry["max_added_bytes"] is not None), default=None)
    hot = max(entry["longest_serious_thermal_seconds"] for entry in resources)
    if None in growths or None in display_growths or added is None:
        return {"result": NOT_MEASURED, "measured": "soak too short for lag and latency growth, or no samples during it"}
    passed = (
        max(growths) <= gate["max_lag_growth_seconds"]
        and max(display_growths) <= gate["max_first_display_growth_seconds"]
        and overflow <= gate["max_overflow_gaps"]
        and added < gate["max_added_memory_bytes"]
        and hot <= gate["max_serious_thermal_seconds"]
    )
    memory = runs[0]["run"]["machine"]["memory_bytes"]
    note = "" if memory == SIXTEEN_GB else f" (the memory limit is set for a 16 GB Mac; this one has {memory / 1024**3:.0f} GB)"
    measured = (
        f"lag growth {max(growths):+.1f} s, first-display growth {max(display_growths):+.1f} s, {overflow} overflow gaps, added memory {added / 1024**3:.2f} GB{note}, "
        f"longest serious heat {hot:.0f} s"
    )
    return {"result": PASS if passed else FAIL, "measured": measured}


def diagnostic_reason(options: dict) -> str | None:
    """Why a configuration is reported but not gated, or None for a gated one."""
    if options.get("clip_seconds") or options.get("baseline_seconds"):
        return "dry run, clips cut short"
    if options.get("clock") == "simulated":
        return "virtual clock"
    if options.get("vocabulary"):
        return "vocabulary on"
    if options.get("alongside"):
        return f"alongside {options['alongside']}"
    return None


def busy_reason(run: dict) -> str | None:
    """Why a run's real-time numbers are not comparable, judged from its power
    state at the start and its baseline CPU idle before the engine loaded
    (BUSY_CPU_IDLE), or None. The load average does not count here."""
    if (run["run"].get("power") or {}).get("low_power_mode"):
        return "Low Power Mode"
    baseline = (run.get("resources") or {}).get("baseline_load") or {}
    idle = baseline.get("median_cpu_idle")
    if idle is None:
        return "CPU idle not recorded"
    if idle < BUSY_CPU_IDLE:
        return f"baseline CPU idle {idle:.0%}"
    return None


def pooled(runs: list[dict], soak: bool) -> dict:
    """Every run's clip entries, soak or not. A clip that several runs
    replayed counts once per run, keyed by clip and folder."""
    counts = Counter(clip for run in runs for clip, entry in run["clips"].items() if (entry["split"] == "soak") == soak)
    entries = {}
    for run in runs:
        for clip, entry in run["clips"].items():
            if (entry["split"] == "soak") == soak:
                entries[clip if counts[clip] == 1 else f"{clip} ({run['run']['folder']})"] = {**entry, "clip": clip}
    return entries


def run_row(run: dict, baseline: dict) -> dict:
    """One run's own numbers on the clips its gates would use, and its load."""
    clips = {clip: entry for clip, entry in run["clips"].items() if entry["split"] != "soak"}
    clips = gated_clips(clips, {})[0] or run["clips"]
    latency = latency_gate(clips)
    accuracy = accuracy_gate(clips, baseline)
    values = [pair for entry in clips.values() for pair in entry["latency"]["values"]]
    p95 = [summarize_p95([pair[index] for pair in values]) for index in (0, 1)]
    resources = run.get("resources") or {}
    baseline_load, load = resources.get("baseline_load") or {}, resources.get("load") or {}
    return {
        "folder": run["run"]["folder"],
        "clips": clip_label(clips),
        "clip_ids": tuple(sorted(clips)),
        "wer": accuracy.get("wer"),
        "shown": (latency.get("shares") or {}).get("first"),
        "settled": (latency.get("shares") or {}).get("settled"),
        "p95_shown": p95[0],
        "p95_settled": p95[1],
        "baseline_load": baseline_load.get("median_load_average"),
        "baseline_idle": baseline_load.get("median_cpu_idle"),
        "load": load.get("median_load_average"),
        "idle": load.get("median_cpu_idle"),
        "busy": busy_reason(run),
    }


def summarize_p95(values: list) -> float | None:
    """Nearest-rank p95, with None (never shown or settled) slowest."""
    ordered = sorted(float("inf") if value is None else value for value in values)
    if not ordered:
        return None
    value = ordered[max(0, -(-95 * len(ordered) // 100) - 1)]
    return None if value == float("inf") else value


def spread(rows: list[dict]) -> list[str]:
    """How far apart the gated runs of the same clips landed, one line per
    clip set: a soak is never compared with validation runs."""
    lines = []
    groups: dict[tuple, list[dict]] = defaultdict(list)
    for row in rows:
        if row["busy"] is None:
            groups[row["clip_ids"]].append(row)
    for gated in groups.values():
        if len(gated) < 2:
            continue
        parts = []
        for key, label in (("wer", "WER"), ("shown", "shown within 3 s"), ("settled", "settled within 5 s")):
            values = [row[key] for row in gated if row[key] is not None]
            if len(values) > 1:
                parts.append(f"{label} {100 * (max(values) - min(values)):.1f} points")
        if parts:
            lines.append(f"Spread across the {len(gated)} gated runs of {gated[0]['clips']}: " + ", ".join(parts) + ".")
    return lines


def measured_in_parts(runs: list[dict]) -> str | None:
    """A note when the configuration's clips were split over runs with no
    clip in common, such as a recheck and its completion: each part starts
    cold and its clips may be easier or harder than the other part's."""
    parts = [(run["run"]["folder"], {clip for clip, entry in run["clips"].items() if entry["split"] != "soak"}) for run in runs]
    parts = [(folder, clips) for folder, clips in parts if clips]
    if len(parts) < 2 or any(first & second for index, (_, first) in enumerate(parts) for _, second in parts[index + 1 :]):
        return None
    pieces = ", ".join(f"{folder} ({len(clips)} clip{'' if len(clips) == 1 else 's'})" for folder, clips in parts)
    return f"Measured in {len(parts)} parts over different clips: {pieces}. Each part starts cold, and its clips may be easier or harder than the others'; compare it with care."


def evaluate(runs: list[dict], baseline: dict) -> dict:
    quiet = [run for run in runs if busy_reason(run) is None]
    gated_runs = quiet or runs
    notes = [f"Left out of the gates: {run['run']['folder']} ({busy_reason(run)})." for run in runs if quiet and run not in quiet]
    parts = measured_in_parts(gated_runs)
    if parts:
        notes.append(parts)
    clips = pooled(gated_runs, soak=False)
    soak = pooled(gated_runs, soak=True)
    finished = {clip_id(key, entry) for key, entry in {**clips, **soak}.items()}
    # A clip another folder finished was run again; it is not missing.
    missing = {clip: split for run in gated_runs for clip, split in run.get("missing_clips", {}).items() if clip not in finished}
    options = runs[0]["run"]["options"]
    gated, gated_missing = gated_clips(clips, {clip: split for clip, split in missing.items() if split != "soak"})
    soak_missing = {clip: split for clip, split in missing.items() if split == "soak"}
    gates = {
        "latency": checked(latency_gate(gated), gated, gated_missing),
        "accuracy": checked(accuracy_gate(gated, baseline), gated, gated_missing),
        "endurance": checked(endurance_gate(soak, gated_runs), soak, soak_missing),
    }
    reason = diagnostic_reason(options)
    if reason is None and not quiet:
        reason = "not comparable: " + "; ".join(sorted({busy_reason(run) for run in runs}))
    if reason:
        for gate in gates.values():
            if gate["result"] != NOT_MEASURED:
                gate["result"] = f"{DIAGNOSTIC} ({reason}; would be {gate['result']})"
    rows = [run_row(run, baseline) for run in runs]
    return {"gates": gates, "clips": clips, "soak": soak, "notes": notes, "runs": rows, "spread": spread(rows)}


def final_baseline(runs: list[dict]) -> tuple[dict, list[str]]:
    """Clip → final-pass metrics from folders that used the app's final-pass
    model on whole clips (the latest folder wins when a clip repeats), and the
    folders left out. A dry run's cut final pass is never the baseline."""
    used = [
        run for run in runs
        if run["run"]["model"] == run["run"].get("final_pass_model") and not run["run"]["options"].get("clip_seconds")
    ]
    baseline = {}
    for run in sorted(used, key=lambda run: run["run"]["folder"]):
        baseline.update(run["clips"])
    return baseline, sorted(run["run"]["folder"] for run in runs if run not in used)


def check_one_lock(metrics: list[dict]) -> None:
    locks = {entry["run"].get("lock_sha256") for entry in metrics}
    if len(locks) > 1:
        folders = ", ".join(f"{entry['run']['folder']} ({str(entry['run'].get('lock_sha256'))[:12]})" for entry in metrics)
        raise ReportError(f"the folders were scored against different fixtures locks: {folders}")


def percent(value: float | None) -> str:
    return "–" if value is None else f"{value:.1%}"


def seconds(value: float | None) -> str:
    return "–" if value is None else f"{value:.2f}"


def settled_after(value: float | None) -> str:
    return "never settled" if value is None else f"settled after {value:.1f} s"


def clip_rows(clips: dict, baseline: dict) -> list[str]:
    header = [
        "| Clip | Split | WER | Final WER | Coverage | p95 shown (s) | p95 settled (s) | Critical | Corrections /100 | Longest rewrite | Words in silence | Crosstalk insertions | Repeat insertions | Decodes in silence | tcORC-WER |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    rows = []
    for clip, entry in sorted(clips.items()):
        streams = entry["streams"].values()
        critical = entry["critical"]
        final = baseline.get(clip_id(clip, entry), {}).get("wer", {}).get("wer")
        tcorc = entry.get("tcorc_wer")
        crosstalk = [stream["crosstalk"]["insertions"] for stream in streams if stream.get("crosstalk") is not None]
        # Over both streams' words together, so two-track and mixed compare.
        rewritten = sum(stream["corrections"]["rewritten_words"] for stream in streams)
        shown = sum(stream["corrections"]["words"] for stream in streams)
        rows.append(
            "| " + " | ".join([
                clip,
                entry["split"],
                percent(entry["wer"]["wer"]),
                percent(final),
                percent(entry["latency"]["coverage"]),
                seconds(entry["latency"]["first_display"]["p95"]),
                seconds(entry["latency"]["settled"]["p95"]),
                f"{critical['survived']}/{critical['total']}",
                f"{100 * rewritten / max(1, shown):.1f}",
                str(max(stream["corrections"]["longest_rewrite"] for stream in streams)),
                str(sum(stream["silence"]["words"] for stream in streams)),
                str(sum(crosstalk)) if crosstalk else "–",
                str(sum(stream["repeats"]["insertions"] for stream in streams)),
                f"{sum(stream['decodes_in_silence'] for stream in streams)}/{sum(stream['decodes'] for stream in streams)}",
                percent(None if tcorc is None else tcorc["error_rate"]),
            ]) + " |"
        )
    return header + rows


def run_rows(rows: list[dict]) -> list[str]:
    lines = [
        "| Folder | Clips | WER | Shown ≤ 3 s | Settled ≤ 5 s | p95 shown (s) | p95 settled (s) | Baseline load / CPU idle | Replay load / CPU idle | Gated |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]

    def load(average: float | None, idle: float | None) -> str:
        return f"{'–' if average is None else f'{average:.1f}'} / {percent(idle)}"

    for row in rows:
        lines.append("| " + " | ".join([
            row["folder"], row["clips"], percent(row["wer"]), percent(row["shown"]), percent(row["settled"]),
            seconds(row["p95_shown"]), seconds(row["p95_settled"]),
            load(row["baseline_load"], row["baseline_idle"]), load(row["load"], row["idle"]),
            "yes" if row["busy"] is None else f"no ({row['busy']})",
        ]) + " |")
    return lines


def failure_examples(clips: dict) -> list[str]:
    lines = []
    for clip, entry in sorted(clips.items()):
        slow = ", ".join(f"\"{word['text']}\" at {word['end']:.1f} s ({settled_after(word['settled'])})" for word in entry["latency"]["slowest"][:5])
        missing = ", ".join(f"\"{word['text']}\" ({word['category']}, {word['start']:.1f} s)" for word in entry["critical"]["missing"][:5])
        silent = ", ".join(f"\"{word['text']}\" at {word['start']:.1f} s" for stream in entry["streams"].values() for word in stream["silence"]["examples"][:5])
        blocks = entry["lag"].get("first_display_by_block")
        timeline = ", ".join("–" if value is None else f"{value:.1f}" for value in blocks) if blocks else ""
        for label, text in (
            ("slowest words", slow), ("missing critical words", missing), ("text during silence", silent),
            ("p95 first display per five minutes (s)", timeline),
        ):
            if text:
                lines.append(f"- {clip}, {label}: {text}")
    return lines


def render(groups: dict, baseline: dict, folders: list[str], ignored: list[str]) -> str:
    lines = [
        "# Live transcript experiment report",
        "",
        f"Generated {datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC from {len(folders)} results folders. Thresholds are frozen in `report.py` (`GATES`).",
        "Latency is session-result latency; the app adds XPC delivery, merging and rendering. Recording safety is measured by the writer test in `AudioCaptureTests`, not here.",
    ]
    if ignored:
        lines.append(f"Final-pass folders with another model or with clips cut short, not used as the baseline: {', '.join(ignored)}.")
    lines.append("")
    for key, (runs, evaluation) in groups.items():
        machine = runs[0]["run"]["machine"]
        lines += [
            f"## {config_title(key)}",
            "",
            f"Machine: {machine['model']}, {machine['chip']}, {machine['memory_bytes'] / 1024**3:.0f} GB, {machine['operating_system']}. Folders: {', '.join(run['run']['folder'] for run in runs)}.",
            "",
            "| Gate | Result | Measured |",
            "|---|---|---|",
        ]
        for name, gate in evaluation["gates"].items():
            lines.append(f"| {name.capitalize()} | {gate['result']} | {gate['measured']} |")
        lines.append("| Recording safety | measured elsewhere | `AudioCaptureTests` writer integration test |")
        lines += [f"- {note}" for note in evaluation["notes"]]
        lines += ["", "### Runs", ""] + run_rows(evaluation["runs"])
        if evaluation["spread"]:
            lines += [""] + evaluation["spread"]
        lines += ["", "### Clips", ""] + clip_rows({**evaluation["clips"], **evaluation["soak"]}, baseline)
        examples = failure_examples({**evaluation["clips"], **evaluation["soak"]})
        if examples:
            lines += ["", "### Examples and timeline", ""] + examples
        lines.append("")
    return "\n".join(lines)


def build_report(folders: list[Path]) -> str:
    metrics = [read_json(folder / "metrics.json") for folder in folders]
    check_one_lock(metrics)
    baseline, ignored = final_baseline([entry for entry in metrics if entry["run"]["kind"] == "final-pass"])
    grouped: dict[tuple, list[dict]] = defaultdict(list)
    for entry in metrics:
        if entry["run"]["kind"] == "run":
            grouped[config_key(entry["run"]["options"], entry["run"]["model"])].append(entry)
    groups = {key: (runs, evaluate(runs, baseline)) for key, runs in grouped.items()}
    return render(groups, baseline, [folder.name for folder in folders], ignored)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=Path, nargs="+", required=True, help="scored results folders")
    parser.add_argument("--out", type=Path, required=True, help="report.md to write")
    args = parser.parse_args(argv)
    try:
        report = build_report(args.runs)
    except FileNotFoundError as error:
        print(f"report: {error}; run score.py on every folder first", file=sys.stderr)
        return 1
    except ReportError as error:
        print(f"report: {error}", file=sys.stderr)
        return 1
    args.out.write_text(report, encoding="utf-8")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
