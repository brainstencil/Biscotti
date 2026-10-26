import json

import pytest

import report
from report import GATES


def test_gate_thresholds_are_frozen():
    assert {name: dict(values) for name, values in GATES.items()} == {
        "latency": {
            "share": 0.95,
            "first_display_seconds": 3.0,
            "settled_seconds": 5.0,
            "slower_first_display_seconds": 5.0,
            "slower_settled_seconds": 8.0,
        },
        "accuracy": {"max_wer": 0.20, "max_wer_above_final": 0.03, "min_critical_survival": 0.95},
        "endurance": {
            "max_added_memory_bytes": 3 * 1024**3,
            "max_lag_growth_seconds": 5.0,
            "max_first_display_growth_seconds": 5.0,
            "max_overflow_gaps": 0,
            "max_serious_thermal_seconds": 60.0,
        },
    }
    with pytest.raises(TypeError):
        GATES["latency"]["share"] = 0.5
    with pytest.raises(TypeError):
        GATES["new"] = {}


def wer(n: int, errors: int) -> dict:
    return {"n": n, "hits": n - errors, "substitutions": errors, "deletions": 0, "insertions": 0, "wer": errors / n}


def live_clip(
    split: str, latencies: list, errors: int, *, growth: float | None = None, display_growth: float | None = None, overflow: int = 0,
    failed: bool = False, unmatched: int = 0,
) -> dict:
    stream = {
        "wer": wer(100, errors),
        "crosstalk": {"insertions": 1, "examples": []},
        "corrections": {"rewritten_words": 3, "words": 100, "per_100_words": 3.0, "longest_rewrite": 2},
        "repeats": {"insertions": 1, "examples": []},
        "silence": {"words": 0, "examples": []},
        "decodes": 10,
        "decodes_in_silence": 1,
    }
    return {
        "split": split,
        "duration": 180,
        "warm": False,
        "wer": wer(100, errors),
        "latency": {
            "matched": len(latencies), "unmatched": unmatched, "coverage": len(latencies) / (len(latencies) + unmatched), "values": latencies,
            "first_display": {"p95": 1.0}, "settled": {"p95": 2.0}, "unmatched_words": [],
            "slowest": [{"text": "late", "end": 10.0, "first": 4.0, "settled": None}],
        },
        "critical": {"total": 20, "survived": 20, "missing": []},
        "streams": {"mic": stream, "system": {**stream, "corrections": {"rewritten_words": 1, "words": 300, "per_100_words": 0.3, "longest_rewrite": 1}}},
        "lag": {
            "max": 3.0, "p95": 2.0, "growth": growth, "first_display_growth": growth if display_growth is None else display_growth,
            "transcribed_through": 120.0 if failed else 180.0, "reached_end": not failed,
        },
        "gaps": {"queueOverflow": {"count": overflow, "seconds": overflow * 5.0}} if overflow else {},
        "finish": {"seconds": 0.5, "session_ended_early": failed, "incomplete_rows": 0},
        "tcorc_wer": None,
    }


def write_metrics(
    folder, kind: str, clips: dict, *, interval: int = 2, load: str = "none", clock: str = "real", resources: dict | None = None,
    model: str | None = "large", lock: str = "lock-1", options: dict | None = None, missing: dict | None = None,
    load_average: float | None = 2.0, baseline_idle: float | None = 0.8, low_power: bool = False,
):
    folder.mkdir()
    options = {
        "option": "whisper-current", "interval": interval, "mode": "two-track", "clips": list(clips), "load": load, "clock": clock, "vocabulary": False,
        **(options or {}),
    }
    metrics = {
        "run": {
            "folder": folder.name, "kind": kind, "options": options, "model": model,
            "final_pass_model": "large" if kind == "final-pass" else None, "lock_sha256": lock,
            "machine": {"model": "Mac", "chip": "M4", "memory_bytes": 16 * 1024**3, "operating_system": "26"},
            "power": {"low_power_mode": low_power, "thermal_state": "nominal"}, "repo": {},
        },
        "clips": clips,
        "missing_clips": missing or {},
        "resources": {
            "baseline_load": {"median_load_average": load_average, "p90_load_average": load_average, "median_cpu_idle": baseline_idle},
            "load": {"median_load_average": 5.0, "p90_load_average": 6.0, "median_cpu_idle": 0.6},
            **(resources or {}),
        },
    }
    (folder / "metrics.json").write_text(json.dumps(metrics))
    return folder


def test_report_applies_gates(tmp_path):
    fast = [[1.0, 2.0]] * 96 + [[4.0, 7.0]] * 4
    slower = [[4.0, 7.0]] * 100
    final = write_metrics(tmp_path / "final", "final-pass", {
        "cal-1": {"split": "calibration", "wer": wer(100, 15), "critical": {"total": 20, "survived": 20, "missing": []}},
    })
    good = write_metrics(tmp_path / "good", "run", {"cal-1": live_clip("calibration", fast, 17)})
    slow = write_metrics(tmp_path / "slow", "run", {"cal-1": live_clip("calibration", slower, 19)}, interval=4)
    soak = write_metrics(
        tmp_path / "soak", "run", {"soak": live_clip("soak", fast, 10, growth=1.0)}, interval=1, load="simulated call load",
        resources={"max_added_bytes": 2 * 1024**3, "longest_serious_thermal_seconds": 0.0},
    )

    text = report.build_report([final, good, slow, soak])

    sections = {section.split("\n", 1)[0]: section for section in text.split("\n## ")[1:]}
    good_section = next(body for title, body in sections.items() if "every 2 s" in title)
    slow_section = next(body for title, body in sections.items() if "every 4 s" in title)
    soak_section = next(body for title, body in sections.items() if "every 1 s" in title)
    assert "| Latency | pass | 1 calibration clip: 96.0% shown" in good_section
    assert "coverage 100.0% of 100 scored words" in good_section
    assert "| Accuracy | pass | 1 calibration clip: WER 17.0%" in good_section and "+2.0 points" in good_section
    assert "| Endurance | not measured |" in good_section
    assert "| Latency | slower tier |" in slow_section
    assert "| Accuracy | fail |" in slow_section, "4 points worse than the final pass"
    assert "| Endurance | pass |" in soak_section
    assert "| Recording safety | measured elsewhere |" in good_section
    assert '"late" at 10.0 s (never settled)' in good_section
    assert "| cal-1 | calibration | 17.0% | 15.0% | 100.0% | 1.00 | 2.00 | 20/20 | 1.0 | 2 | 0 | 2 | 2 | 2/20 | – |" in good_section, (
        "corrections are 100 × 4 rewritten / 400 shown words over both streams, not the sum of per-stream rates"
    )


def test_clips_a_run_never_finished_fail_their_gates(tmp_path):
    fast = [[1.0, 2.0]] * 100
    stopped = write_metrics(tmp_path / "stopped", "run", {"val-1": live_clip("validation", fast, 5)}, missing={"val-2": "validation", "cal-1": "calibration"})
    rerun = write_metrics(tmp_path / "rerun", "run", {"val-2": live_clip("validation", fast, 5)}, missing={})
    soak = write_metrics(tmp_path / "soak", "run", {}, interval=1, load="simulated call load", missing={"soak": "soak"})

    text = report.build_report([stopped])
    both = report.build_report([stopped, rerun])
    soak_text = report.build_report([soak])

    assert "| Latency | fail | 2 validation clips: " in text and "val-2: no result; the run stopped before it finished" in text
    assert "| Accuracy | fail |" in text and "cal-1" not in text.split("### Clips")[0], "validation clips decide the gates"
    assert "| Latency | pass | 2 validation clips:" in both, "another folder finished the clip"
    assert "| Endurance | fail | 1 soak clip: no soak clip; soak: no result; the run stopped before it finished |" in soak_text


def test_runs_with_work_alongside_are_diagnostics(tmp_path):
    fast = [[1.0, 2.0]] * 100
    alone = write_metrics(tmp_path / "alone", "run", {"val-1": live_clip("validation", fast, 5)})
    beside = write_metrics(tmp_path / "beside", "run", {"val-1": live_clip("validation", fast, 5)}, options={"alongside": "final pass of soak"})

    text = report.build_report([alone, beside])

    sections = {section.split("\n", 1)[0]: section for section in text.split("\n## ")[1:]}
    beside_section = next(body for title, body in sections.items() if title.endswith("alongside: final pass of soak"))
    alone_section = next(body for title, body in sections.items() if "alongside" not in title)
    assert "| Latency | diagnostic (alongside final pass of soak; would be pass) |" in beside_section
    assert "| Latency | pass |" in alone_section


def test_report_keeps_fast_results_apart(tmp_path):
    shown = [[1.0, 2.0]] * 100
    speech = {"option": "speechanalyzer", "locale": "en-US"}
    standard = write_metrics(tmp_path / "standard", "run", {"cal-1": live_clip("calibration", shown, 10)}, model=None, options={**speech, "fast_results": False})
    fast = write_metrics(tmp_path / "fast", "run", {"cal-1": live_clip("calibration", shown, 10)}, model=None, options={**speech, "fast_results": True})

    text = report.build_report([standard, fast])

    titles = [section.split("\n", 1)[0] for section in text.split("\n## ")[1:]]
    assert any(title.startswith("speechanalyzer · fast results: off · every 2 s") for title in titles)
    assert any(title.startswith("speechanalyzer · fast results: on · every 2 s") for title in titles)


def test_simulated_runs_and_failed_endurance_are_reported(tmp_path):
    fast = [[0.5, 1.0]] * 100
    simulated = write_metrics(tmp_path / "virtual", "run", {"cal-1": live_clip("calibration", fast, 5)}, clock="simulated")
    leaking = write_metrics(
        tmp_path / "leaking", "run", {"soak": live_clip("soak", fast, 5, growth=12.0, overflow=2)}, load="simulated call load",
        resources={"max_added_bytes": 4 * 1024**3, "longest_serious_thermal_seconds": 120.0},
    )

    text = report.build_report([simulated, leaking])

    assert "| Latency | diagnostic (virtual clock; would be pass) |" in text
    assert "| Endurance | fail | 1 soak clip: lag growth +12.0 s, first-display growth +12.0 s, 2 overflow gaps, added memory 4.00 GB" in text
    assert "no final-pass baseline for cal-1" in text


def baseline_clip(errors: int) -> dict:
    return {"split": "validation", "wer": wer(100, errors), "critical": {"total": 20, "survived": 20, "missing": []}}


def test_gates_use_validation_clips_and_the_right_baseline(tmp_path):
    fast = [[1.0, 2.0]] * 100
    final = write_metrics(tmp_path / "final", "final-pass", {"val-1": baseline_clip(15)})
    small = write_metrics(tmp_path / "small", "final-pass", {"val-1": baseline_clip(30)}, model="small")
    live = write_metrics(tmp_path / "live", "run", {
        "cal-1": live_clip("calibration", [[9.0, 9.0]] * 100, 40),
        "val-1": live_clip("validation", fast, 16, unmatched=25),
    })

    text = report.build_report([final, small, live])

    assert "| Latency | pass | 1 validation clip: 100.0% shown" in text, "calibration clips tune options; they do not decide gates"
    assert "coverage 80.0% of 125 scored words" in text
    assert "| Accuracy | pass | 1 validation clip: WER 16.0%; final pass 15.0% (+1.0 points)" in text
    assert "Final-pass folders with another model or with clips cut short, not used as the baseline: small." in text


def test_a_failed_session_fails_its_gates_and_mixed_locks_are_refused(tmp_path):
    fast = [[1.0, 2.0]] * 100
    failed = write_metrics(tmp_path / "failed", "run", {"val-1": live_clip("validation", fast, 5, failed=True)})
    other = write_metrics(tmp_path / "other", "run", {"val-2": live_clip("validation", fast, 5)}, interval=4, lock="lock-2")

    text = report.build_report([failed])

    assert "| Latency | fail | 1 validation clip:" in text and "val-1: the session failed" in text
    with pytest.raises(report.ReportError, match="different fixtures locks"):
        report.build_report([failed, other])


def test_endurance_reads_only_the_soak_run_and_notes_duplicate_clips(tmp_path):
    fast = [[1.0, 2.0]] * 100
    loaded = {"load": "simulated call load", "interval": 1}
    soak = write_metrics(
        tmp_path / "soak", "run", {"soak": live_clip("soak", fast, 5, growth=1.0)}, **loaded,
        resources={"max_added_bytes": 1 * 1024**3, "longest_serious_thermal_seconds": 0.0},
    )
    short = write_metrics(
        tmp_path / "short", "run", {"val-1": live_clip("validation", fast, 5)}, **loaded,
        resources={"max_added_bytes": 5 * 1024**3, "longest_serious_thermal_seconds": 0.0},
    )
    again = write_metrics(tmp_path / "again", "run", {"val-1": live_clip("validation", fast, 6)}, **loaded)

    text = report.build_report([soak, short, again])

    assert "| Endurance | pass | 1 soak clip: lag growth +1.0 s, first-display growth +1.0 s, 0 overflow gaps, added memory 1.00 GB" in text
    assert "| Accuracy | not measured | 1 validation clip, 2 runs each: WER 5.5%" in text, "both repetitions count"


def test_endurance_fails_when_first_display_latency_grows_while_lag_holds(tmp_path):
    """SpeechAnalyzer takes its audio at once, so its lag holds even when its text falls behind."""
    shown = [[1.0, 2.0]] * 100
    soak = write_metrics(
        tmp_path / "soak", "run", {"soak": live_clip("soak", shown, 5, growth=0.5, display_growth=6.0)}, interval=1, load="simulated call load",
        resources={"max_added_bytes": 1 * 1024**3, "longest_serious_thermal_seconds": 0.0}, model=None, options={"option": "speechanalyzer"},
    )

    text = report.build_report([soak])

    assert "| Endurance | fail | 1 soak clip: lag growth +0.5 s, first-display growth +6.0 s, 0 overflow gaps" in text


def test_endurance_fails_with_its_own_reason_when_text_stops_late_in_the_soak(tmp_path):
    """SpeechAnalyzer's lag follows the audio it accepted, so only the display shows a stall."""
    clip = live_clip("soak", [[1.0, 2.0]] * 100, 5, growth=0.5)
    clip["lag"] |= {"first_display_growth": None, "first_display_stopped": True}
    soak = write_metrics(
        tmp_path / "soak", "run", {"soak": clip}, interval=1, load="simulated call load",
        resources={"max_added_bytes": 1 * 1024**3, "longest_serious_thermal_seconds": 0.0}, model=None, options={"option": "speechanalyzer"},
    )

    text = report.build_report([soak])

    assert "| Endurance | fail | 1 soak clip: text stopped: no word spoken in the last 10 minutes of soak was shown" in text


def test_a_soak_whose_session_failed_fails_endurance(tmp_path):
    dead = live_clip("soak", [[1.0, 2.0]] * 100, 5, growth=None, failed=True)
    soak = write_metrics(
        tmp_path / "soak", "run", {"soak": dead}, interval=1, load="simulated call load",
        resources={"max_added_bytes": 1 * 1024**3, "longest_serious_thermal_seconds": 0.0},
    )

    text = report.build_report([soak])

    assert "| Endurance | fail |" in text and "soak: the session failed" in text


def test_busy_runs_are_left_out_of_the_gates_and_shown_with_their_load(tmp_path):
    """Busy means busy before the engine loaded: the replay's own load never excludes a run."""
    fast, slow = [[1.0, 2.0]] * 100, [[9.0, 9.0]] * 100
    quiet = write_metrics(tmp_path / "quiet", "run", {"val-1": live_clip("validation", fast, 5)}, load_average=3.0)
    # Spotlight at night: background threads queued on the efficiency cores raise the load average while the CPU stays mostly idle.
    indexing = write_metrics(tmp_path / "indexing", "run", {"val-1": live_clip("validation", fast, 5)}, load_average=20.0, baseline_idle=0.7)
    busy = write_metrics(tmp_path / "busy", "run", {"val-1": live_clip("validation", slow, 30)}, load_average=3.0, baseline_idle=0.4)
    unknown = write_metrics(tmp_path / "unknown", "run", {"val-1": live_clip("validation", slow, 30)}, load_average=3.0, baseline_idle=None, interval=4)
    saving = write_metrics(tmp_path / "saving", "run", {"val-1": live_clip("validation", slow, 30)}, low_power=True)

    text = report.build_report([quiet, indexing, busy, unknown, saving])

    sections = {section.split("\n", 1)[0]: section for section in text.split("\n## ")[1:]}
    two = next(body for title, body in sections.items() if "every 2 s" in title)
    four = next(body for title, body in sections.items() if "every 4 s" in title)
    assert "| Latency | pass | 1 validation clip, 2 runs each: 100.0% shown" in two, "the quiet run and the indexing run"
    assert "| Accuracy | not measured | 1 validation clip, 2 runs each: WER 5.0%" in two
    assert "- Left out of the gates: busy (baseline CPU idle 40%)." in two
    assert "- Left out of the gates: saving (Low Power Mode)." in two
    assert "indexing (" not in two, "a high load average alone leaves no run out"
    assert "| busy | 1 validation clip | 30.0% | 0.0% | 0.0% | 9.00 | 9.00 | 3.0 / 40.0% | 5.0 / 60.0% | no (baseline CPU idle 40%) |" in two
    assert "| indexing | 1 validation clip | 5.0% | 100.0% | 100.0% | 1.00 | 2.00 | 20.0 / 70.0% | 5.0 / 60.0% | yes |" in two
    assert "| quiet | 1 validation clip | 5.0% | 100.0% | 100.0% | 1.00 | 2.00 | 3.0 / 80.0% | 5.0 / 60.0% | yes |" in two
    assert "| Latency | diagnostic (not comparable: CPU idle not recorded; would be fail) |" in four
    assert "| unknown | 1 validation clip | 30.0% | 0.0% | 0.0% | 9.00 | 9.00 | 3.0 / – | 5.0 / 60.0% | no (CPU idle not recorded) |" in four


def test_busy_is_judged_by_cpu_idle_not_the_load_average():
    def run(load, idle, low_power=False):
        return {"run": {"power": {"low_power_mode": low_power}}, "resources": {"baseline_load": {"median_load_average": load, "median_cpu_idle": idle}}}

    assert report.busy_reason(run(20.0, 0.7)) is None, "load 20 from the efficiency cores' queue with 70% idle is not busy"
    assert report.busy_reason(run(3.0, 0.4)) == "baseline CPU idle 40%"
    assert report.busy_reason(run(20.0, 0.4)) == "baseline CPU idle 40%", "the load average adds no reason"
    assert report.busy_reason(run(3.0, report.BUSY_CPU_IDLE)) is None, "exactly half idle is not busy"
    assert report.busy_reason(run(None, 0.8)) is None, "the load average is not needed"
    assert report.busy_reason(run(3.0, None)) == "CPU idle not recorded"
    assert report.busy_reason({"run": {}}) == "CPU idle not recorded"
    assert report.busy_reason(run(3.0, 0.8, low_power=True)) == "Low Power Mode"
    assert not hasattr(report, "BUSY_LOAD_AVERAGE")


def test_dry_runs_never_pool_with_real_runs_or_give_the_baseline(tmp_path):
    shown = [[1.0, 2.0]] * 100
    final = write_metrics(tmp_path / "final", "final-pass", {"val-1": {"split": "validation", "wer": wer(100, 9), "critical": {"total": 1, "survived": 1, "missing": []}}})
    cut_final = write_metrics(
        tmp_path / "cut-final", "final-pass", {"val-1": {"split": "validation", "wer": wer(100, 50), "critical": {"total": 1, "survived": 1, "missing": []}}},
        options={"clip_seconds": 5},
    )
    real = write_metrics(tmp_path / "real", "run", {"val-1": live_clip("validation", shown, 10)})
    cut = write_metrics(tmp_path / "cut", "run", {"val-1": live_clip("validation", shown, 90)}, options={"clip_seconds": 5, "baseline_seconds": 2})

    text = report.build_report([final, cut_final, real, cut])

    sections = {section.split("\n", 1)[0]: section for section in text.split("\n## ")[1:]}
    assert len(sections) == 2 and any(title.endswith("dry run: clips cut to 5 s, baseline 2 s") for title in sections)
    real_section = next(body for title, body in sections.items() if "dry run" not in title)
    assert "| Accuracy | pass | 1 validation clip: WER 10.0%; final pass 9.0% (+1.0 points)" in real_section, "the cut final pass is not the baseline"
    assert "cut-final" in text.split("\n## ")[0]


def test_repeated_runs_pool_their_clips_and_report_the_spread_of_the_same_clips(tmp_path):
    first = write_metrics(tmp_path / "first", "run", {"val-1": live_clip("validation", [[1.0, 2.0]] * 100, 10)})
    second = write_metrics(tmp_path / "second", "run", {"val-1": live_clip("validation", [[1.0, 2.0]] * 90 + [[4.0, 7.0]] * 10, 14)})
    soak = write_metrics(
        tmp_path / "soak", "run", {"soak": live_clip("soak", [[1.0, 2.0]] * 100, 40, growth=1.0)},
        resources={"max_added_bytes": 1024**3, "longest_serious_thermal_seconds": 0.0},
    )

    text = report.build_report([first, second, soak])

    assert "| Latency | pass | 1 validation clip, 2 runs each: 95.0% shown ≤ 3 s" in text, "200 words pooled"
    assert "| Accuracy | not measured | 1 validation clip, 2 runs each: WER 12.0%" in text
    assert "Spread across the 2 gated runs of 1 validation clip: WER 4.0 points, shown within 3 s 10.0 points, settled within 5 s 10.0 points." in text
    assert "30.0 points" not in text and "3 gated runs" not in text, "the soak is not compared with the validation runs"
    assert "| val-1 (first) | validation |" in text and "| val-1 (second) | validation |" in text


def test_a_configuration_measured_in_parts_says_so(tmp_path):
    shown = [[1.0, 2.0]] * 100
    first = write_metrics(tmp_path / "recheck", "run", {"cal-1": live_clip("calibration", shown, 10), "cal-2": live_clip("calibration", shown, 10)})
    second = write_metrics(tmp_path / "completion", "run", {"cal-3": live_clip("calibration", shown, 30)})
    again = write_metrics(tmp_path / "again", "run", {"cal-1": live_clip("calibration", shown, 10)}, interval=4)
    again_too = write_metrics(tmp_path / "again-too", "run", {"cal-1": live_clip("calibration", shown, 12)}, interval=4)
    cut = write_metrics(tmp_path / "cut", "run", {"cal-1": live_clip("calibration", shown, 10)}, options={"clip_seconds": 4})

    text = report.build_report([first, second, again, again_too, cut])

    assert "- Measured in 2 parts over different clips: recheck (2 clips), completion (1 clip). Each part starts cold" in text
    assert text.count("Measured in") == 1, "repetitions of the same clips are not parts"
    assert any(line.endswith("· dry run: clips cut to 4 s") for line in text.splitlines()), "a single cut names only itself"
