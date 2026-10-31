"""Tests for analyze.py: uv run --with pytest pytest Tools/chat_bench

`testdata/excerpt.ndjson` is a run in the form `log stream --style ndjson`
writes, with the fields analyze.py reads. Times are seconds after 10:00:00:
- The live engine starts at 5 and is live at 8; a backlog before that is left out.
- Question 1 (cold): ask 18, lease 19 (the model loads), first token 21,
  done 30. The live text catches up from 27 to 42.
- Question 2 (warm, stopped, partial): ask 49, lease 49.5, first token 50,
  done 55. The live text falls behind at 58, inside the grace after done,
  and is live again at 63.
- Question 3 is skipped. The watchdog ends the worker at 60. The recording
  stops at 66; memory and model loads after that are not part of the rule.
- Question 4 fails before it gets the model: ask 70, done 70.1, while live
  transcription is paused for good. Question 5 is not sent. The summary
  loads the model at 74.
- The llm worker is missing, the log dropped messages once, two chunks were
  never measured, the session counted one more chunk than the capture holds,
  and the capture's last line is cut off.
- Lines from /Applications/Biscotti.app and another subsystem are ignored.
"""

import json
import math
from datetime import datetime, timedelta
from pathlib import Path

import pytest

import analyze

EXCERPT = Path(__file__).parent / "testdata" / "excerpt.ndjson"
# The excerpt's answers that did not complete: each makes the verdict undetermined.
STOPPED = "question 2 stopped"
FAILED = "question 4 failed (There's no transcript to answer from yet.)"


def lines(without=(), replacing=()):
    """The excerpt's lines, less those containing any of `without`, with
    each (old, new) pair in `replacing` applied."""
    kept = [line for line in EXCERPT.read_text().splitlines() if not any(text in line for text in without)]
    for old, new in replacing:
        kept = [line.replace(old, new) for line in kept]
    return kept


def analyzed(lines_):
    return analyze.analyze(analyze.parse_entries(lines_), "excerpt")


@pytest.fixture(scope="module")
def result():
    return analyzed(lines())


def answer(result, question):
    return next(row for row in result["answers"] if row["question"] == question)


def test_questions_and_answer_windows(result):
    assert result["questions"] == {
        "planned": 5, "asked": 3, "skipped": [{"question": 3, "reason": "liveTranscriptOff"}], "notSent": [5],
    }
    assert [row["question"] for row in result["answers"]] == [1, 2, 4]
    assert [row["windowSeconds"] for row in result["answers"]] == pytest.approx([11.0, 5.5, 0.1])
    assert [row["cold"] for row in result["answers"]] == [True, False, False]
    assert result["timeToFirstTokenSeconds"] == {"cold": pytest.approx([3.0]), "warm": pytest.approx([1.0])}
    assert answer(result, 1)["promptTokens"] == 5200
    assert answer(result, 1)["contextSize"] == 8192
    assert answer(result, 4)["error"] == "There's no transcript to answer from yet."


def test_tokens_per_second_prefers_the_models_figures(result):
    # Question 1: 90 generated in 9 s. Question 2 stopped, so 50 tokens after the first in 5 s.
    assert answer(result, 1)["tokensPerSecond"] == pytest.approx(10.0)
    assert answer(result, 2)["tokensPerSecond"] == pytest.approx(10.0)
    assert answer(result, 4)["tokensPerSecond"] is None
    assert result["tokensPerSecond"]["median"] == pytest.approx(10.0)


def test_live_delay_inside_and_outside_answers(result):
    live = result["liveDelaySeconds"]
    assert live["update"]["inside"] == {"median": pytest.approx(3.0), "p95": pytest.approx(5.0), "count": 3}
    assert live["update"]["outside"] == {"median": pytest.approx(1.0), "p95": pytest.approx(1.0), "count": 2}
    assert live["drawn"]["inside"] == {"median": pytest.approx(2.45), "p95": pytest.approx(3.5), "count": 2}
    assert live["drawn"]["outside"] == {"median": pytest.approx(1.2), "p95": pytest.approx(1.2), "count": 1}


def test_longest_decodes_resets_and_restarts(result):
    # The 3 s decode ended after question 1's done, but started inside its window.
    # The 3.5 s decode came before the engine was live.
    assert result["longestDecodeMs"] == {"inside": 3000, "outside": 900}
    assert result["watchdogResets"] == 1
    assert result["engineRestarts"] == 1
    assert result["engineFailures"] == 0


def test_catch_up_after_each_answer(result):
    assert result["catchUpSeconds"]["perAnswer"] == [pytest.approx(12.0), pytest.approx(8.0), None]
    assert result["catchUpSeconds"]["median"] == pytest.approx(12.0)


@pytest.mark.parametrize("statuses, done, until, expected", [
    ([(0, "live"), (5, "off")], 6, 16, 0.0),
    ([(0, "live"), (12, "catchingUp"), (20, "live")], 10, 20, 10.0),
    ([(0, "live"), (12, "catchingUp"), (20, "live")], 10, 11, 0.0),
    ([(0, "paused(lowPowerHeat)"), (7, "live")], 5, 15, 2.0),
    ([(0, "unavailable(stopped)")], 5, 15, None),
    ([(8, "live")], 5, 15, analyze.UNKNOWN),
])
def test_catch_up_rules(statuses, done, until, expected):
    assert analyze.catch_up(done, statuses, until) == expected


def test_memory_during_the_recording_footprint_resident_and_budgets(result):
    # The samples at 10, 20 and 52: the one at 1 is before the recording, the one at 68 after Stop.
    footprint, resident = result["memory"]["footprint"], result["memory"]["resident"]
    assert result["memory"]["samples"] == 3
    assert footprint["app"] == {"peakMiB": 700.0, "medianMiB": 650.0}
    assert footprint["transcriber"] == {"peakMiB": 1600.0, "medianMiB": 1550.0}
    assert footprint["llm"] == {"peakMiB": 3100.0, "medianMiB": 3050.0}
    assert footprint["sum"] == {"peakMiB": 5300.0, "medianMiB": 5300.0}
    assert resident["llm"] == {"peakMiB": 9300.0, "medianMiB": 7250.0}
    assert resident["sum"] == {"peakMiB": 11750.0, "medianMiB": 7750.0}
    # The rule's figure: footprints plus the AI worker's resident pages beyond its footprint.
    assert result["memory"]["decision"] == {"peakMiB": 11500.0, "medianMiB": 7500.0}
    assert result["memoryAfterStop"] == {"decision": {"peakMiB": 15300.0, "medianMiB": 15300.0}, "samples": 1}
    assert [(budget["mac"], budget["model"], budget["fits"], budget["appliesToThisRun"]) for budget in result["memoryBudgets"]] == [
        ("8 GB", "E2B", False, True), ("16 GB", "E2B", False, True), ("24 GB", "12B", True, False),
    ]


def test_citations_outcomes_and_model(result):
    assert result["citations"] == {"cited": 6, "linked": 5, "validity": pytest.approx(5 / 6)}
    assert result["outcomes"] == {"failed": 1, "partial": 1}
    assert result["model"] == {
        "loadsDuringRecording": 1, "loadsOutsideRecording": 1,
        "files": ["gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf"], "closes": {"idle": 1},
    }
    assert result["liveChunksDropped"] == {"notCovered": 2}
    assert result["plan"]["name"] == "concurrent-e2b"
    assert result["plan"]["closeModelAfterAnswer"] == "true"


def test_warnings_name_what_the_capture_lost(result):
    assert result["warnings"] == [
        "the llm worker was not found, so its memory is not in the sum",
        "the log reported dropped messages 1 time, so figures may be incomplete",
        "1 capture line did not decode (a capture stopped mid-write cuts its last line)",
        "the live session counted 7 for 'chunk to update', but only 6 are in the range",
    ]


def test_a_model_load_without_its_broker_line_warns():
    warnings = analyzed(lines(without=["Model opened: gemma-4-E2B"]))["warnings"]
    assert warnings[0].startswith("question 1 loaded the model, but no 'Model opened' line is in the range")


@pytest.mark.parametrize("without, reason, outcomes", [
    (["plan name="], "no plan line: start the capture before the app", [STOPPED, FAILED]),
    (["plan-done"], "no plan-done line: the app quit or the capture ended early", [STOPPED, FAILED]),
    (["ask q=4", "done q=4"], "only 4 of 5 questions were asked, skipped or not sent: the app quit or the capture ended early",
     [STOPPED]),
])
def test_a_run_that_ended_early_is_undetermined(without, reason, outcomes):
    result = analyzed(lines(without=[*without, "A live decode has not returned"]))
    assert reason in result["warnings"]
    assert result["contention"] == {"passes": None, "reasons": [reason, *outcomes]}


def test_without_a_recording_start_the_whole_capture_counts():
    result = analyzed(lines(without=["recording-started"]))
    assert "no recording-started line: the memory figures and model loads cover the whole capture" in result["warnings"]
    assert result["memory"]["samples"] == 5
    assert result["model"]["loadsDuringRecording"] == 2


@pytest.mark.parametrize("replacing, warning", [
    ([(f"transcriber={value}.0", "transcriber=-") for value in (1500, 1600, 1550)],
     "the transcriber's memory was never read during the recording, so the sum leaves it out"),
    ([(f"llm={value}.0", "llm=-") for value in (3000, 3100, 3200)],
     "the llm worker's memory was never read after the first lease, so the sum leaves it out"),
])
def test_a_worker_never_read_warns(replacing, warning):
    assert warning in analyzed(lines(replacing=replacing))["warnings"]


def test_lines_from_two_app_processes_warn():
    second = json.loads(next(line for line in lines() if "recording-started" in line))
    second["processID"] = 5555
    assert "lines come from 2 Biscotti Dev processes: quit every other copy before a run" in analyzed(
        [*lines(), json.dumps(second, ensure_ascii=False)]
    )["warnings"]


def test_a_loss_event_without_a_timestamp_is_counted():
    entries = analyze.parse_entries([json.dumps({"eventType": "lossEvent"}, ensure_ascii=False)])
    assert [entry.kind for entry in entries] == ["loss"]


def test_contention_fails_on_a_watchdog_reset(result):
    assert result["contention"] == {"passes": False, "reasons": ["1 watchdog reset"]}
    # The reset at 10:01:00 came 54 s after the recording started at 10:00:06.
    assert result["watchdogResetTimes"] == ["at 0:54, 5 s after q2's done"]


@pytest.mark.parametrize("time, expected", [
    (25.0, "at 0:15, inside q1's answer"),
    (16.0, "at 0:06, 4 s before q1's lease"),
    (35.0, "at 0:25, 5 s after q1's done"),
    (45.0, "at 0:35, 5 s before q2's ask"),
    (130.0, "at 2:00, 10 s after Stop, 70 s after q2's done"),
])
def test_a_reset_is_placed_against_the_nearest_answer_and_stop(time, expected):
    # The recording runs from 10 to 120; q1 holds the model from 20 to 30, q2 never got it (50 to 60).
    run = analyze.Run(recording_started=10.0, recording_stopped=120.0)
    answers = [analyze.Answer(question=1, ask=18.0, lease=20.0, done=30.0), analyze.Answer(question=2, ask=50.0, done=60.0)]
    assert analyze.reset_time(time, answers, run) == expected


def test_a_reset_without_a_recording_start_or_answers_reads_the_clock():
    time = datetime(2026, 10, 29, 10, 15, 0).timestamp()
    assert analyze.reset_time(time, [], analyze.Run()) == "at 10:15:00"


def test_the_model_must_match_the_plan():
    def model_warnings(lines_):
        return [warning for warning in analyzed(lines_)["warnings"] if warning.startswith("the plan is for")]

    assert model_warnings(lines()) == []
    assert model_warnings(lines(replacing=[("name=concurrent-e2b", "name=concurrent-12b")])) == [
        "the plan is for 12B, but the run loaded gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf: select the plan's model",
    ]
    # No model loaded, as in a baseline run: nothing to compare.
    assert model_warnings(lines(without=["Model opened"], replacing=[("name=concurrent-e2b", "name=concurrent-12b")])) == []


def test_an_answer_asked_in_the_app_warns():
    done = next(line for line in lines() if "done q=1" in line)
    other = done.replace("done q=1", "done q=-").replace("10:00:30.000000", "10:00:40.000000")
    result = analyzed([*lines(), other])
    assert "1 answer not asked by the driver (someone asked in the app): their load falls outside the answer windows" in result["warnings"]
    assert [row["question"] for row in result["answers"]] == [1, 2, 4]


def test_an_aborted_plan_warns():
    plan_done = next(line for line in lines() if "plan-done" in line)
    abort = plan_done.replace("plan-done", "abort reason=liveTranscriptOff")
    result = analyzed([*lines(without=["plan-done", "A live decode has not returned"]), abort])
    assert "the driver aborted the plan: liveTranscriptOff" in result["warnings"]
    assert result["contention"] == {
        "passes": None, "reasons": ["no plan-done line: the app quit or the capture ended early", STOPPED, FAILED],
    }


def test_contention_is_undetermined_when_no_answer_finished():
    # The app quit mid-answer, or the capture ended early.
    result = analyzed(lines(without=["done q=", "A live decode has not returned"]))
    unfinished = [f"question {question} has no done line: the app quit or the capture ended early" for question in (1, 2, 4)]
    assert result["contention"] == {"passes": None, "reasons": unfinished}
    assert all(reason in result["warnings"] for reason in unfinished)


def test_contention_is_undetermined_when_the_last_answer_did_not_finish():
    result = analyzed(lines(without=["done q=4", "A live decode has not returned"]))
    assert result["contention"] == {
        "passes": None, "reasons": ["question 4 has no done line: the app quit or the capture ended early", STOPPED],
    }


def test_an_answer_that_did_not_complete_makes_the_verdict_undetermined():
    # The driver never presses the chat's Stop, so a stopped or failed answer is a fault in the run.
    without_reset = ["A live decode has not returned"]
    assert analyzed(lines(without=without_reset))["contention"] == {"passes": None, "reasons": [STOPPED, FAILED]}
    completed = [("outcome=stopped", "outcome=complete"), ("outcome=failed", "outcome=complete")]
    assert analyzed(lines(without=without_reset, replacing=completed))["contention"] == {"passes": True, "reasons": []}


def test_an_unknown_catch_up_is_not_never():
    # No live status before question 1's done (a capture that started late).
    early_statuses = ["10:00:05.000000", "10:00:08.000000", "10:00:27.000000", "10:01:09.000000"]
    result = analyzed(lines(without=[*early_statuses, "A live decode has not returned"]))
    assert result["catchUpSeconds"] == {"median": pytest.approx(4.0), "perAnswer": ["unknown", pytest.approx(8.0), 0.0]}
    assert result["contention"]["passes"] is None
    assert "the catch-up after question 1 is unknown: no live status came before its done" in result["contention"]["reasons"]


def test_contention_is_undetermined_without_decode_lines():
    contention = analyzed(lines(without=["decode ms=", "A live decode has not returned"]))["contention"]
    assert contention == {"passes": None, "reasons": [STOPPED, FAILED, "no live decode lines in the answer windows"]}


def test_contention_is_undetermined_without_live_status_lines():
    without_live = analyzed(lines(without=['"category": "live",']))
    assert without_live["catchUpSeconds"]["perAnswer"] == ["unknown", "unknown", "unknown"]
    assert without_live["contention"] == {"passes": None, "reasons": [STOPPED, FAILED, "no live status lines in the range"]}


def test_contention_fails_when_live_transcription_stops():
    failure = json.dumps({
        "timestamp": "2026-10-29 10:01:05.000000-0700", "eventType": "logEvent", "messageType": "Error",
        "subsystem": "net.scosman.biscotti", "category": "live", "processImagePath": "/x/Biscotti Dev.app/Contents/MacOS/Biscotti Dev",
        "eventMessage": "The live engine failed again; live transcription stops for this recording",
    }, ensure_ascii=False)
    result = analyzed(lines(without=["A live decode has not returned"]) + [failure])
    assert result["engineFailures"] == 1
    assert result["contention"] == {"passes": False, "reasons": ["live transcription stopped: the live engine failed twice"]}


def test_contention_rule_limits():
    answers = [analyze.Answer(question=1, ask=0)]
    assert analyze.contention(answers, longest_decode_ms=4999, catch_up_median=29.9) == {"passes": True, "reasons": []}
    assert analyze.contention(answers, longest_decode_ms=5000, catch_up_median=30)["reasons"] == [
        "a decode inside an answer took 5.0 s",
        "the median catch-up is 30 s or more",
    ]
    assert analyze.contention(answers, catch_up_median=math.inf)["passes"] is False
    assert analyze.contention([])["passes"] is None


def test_a_range_with_two_plans_is_refused():
    plan = next(line for line in lines() if "plan name=" in line)
    second = json.loads(plan)
    second["timestamp"] = "2026-10-29 10:05:00.000000-0700"
    with pytest.raises(analyze.AnalysisError, match="2 chat load plans"):
        analyzed([*lines(), json.dumps(second, ensure_ascii=False)])


def test_markdown_lists_every_measure(result):
    table = analyze.markdown(result)
    for text in [
        "| Plan | concurrent-e2b, mode concurrent, model closed after each answer: yes |",
        "| Questions asked | 3 of 5 (q3 skipped (liveTranscriptOff); q5 not sent) |",
        "| Model loads | 1 during the recording, 1 outside it: gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf (closes: idle 1) |",
        "| Memory during the recording, sum | footprint peak 5.18 GB, median 5.18 GB; resident peak 11.47 GB, median 7.57 GB |",
        "| Memory for the rule (footprints + AI worker's mapped weights) | peak 11.23 GB, median 7.32 GB |",
        "| Same figure after Stop (final pass and summary; not for the rule) | peak 14.94 GB, median 14.94 GB |",
        "| Rule figure's peak against budgets | 8 GB Mac, E2B (3 GB): over (this run's model); "
        "16 GB Mac, E2B (11 GB): over (this run's model); 24 GB Mac, 12B (19 GB): fits |",
        "| Live chunks not measured | notCovered 2 |",
        "| Live delay inside answers, to drawn | median 2.5 s, p95 3.5 s (2 chunks) |",
        "| Live delay outside answers, to update | median 1.0 s, p95 1.0 s (2 chunks) |",
        "| Longest live decode inside answers | 3.00 s |",
        "| Watchdog resets | 1 (at 0:54, 5 s after q2's done) |",
        "| Live engine restarts / failures | 1 / 0 |",
        "| Catch-up after answers | median 12.0 s; per answer (s): 12.0, 8.0, never |",
        "| Time to first token, cold | 3.0 s |",
        "| Citation validity | 5 of 6 (83%) |",
        "| Failed / partial answers | 1 failed, 1 partial |",
        "| Contention rule | fails (1 watchdog reset) |",
        "| Live gaps (audio missing from the live text) | none |",
        "| Live finish after Stop | – |",
    ]:
        assert text in table
    assert "| Warnings | the llm worker was not found" in table


def test_main_writes_the_results(tmp_path, capsys):
    assert analyze.main(["excerpt", "--log", str(EXCERPT), "--out", str(tmp_path)]) == 0

    saved = json.loads((tmp_path / "excerpt.json").read_text())
    output = capsys.readouterr()
    assert saved["run"] == "excerpt"
    assert saved["watchdogResets"] == 1
    assert (tmp_path / "excerpt.md").read_text() == output.out.removesuffix("\n")
    assert "warning: the llm worker was not found" in output.err


# MARK: - Live text in Low Power Mode

APP = "/x/Biscotti Dev.app/Contents/MacOS/Biscotti Dev"
TRANSCRIBER = "/x/Biscotti Dev.app/Contents/XPCServices/BiscottiTranscriber.xpc/Contents/MacOS/BiscottiTranscriber"


def event(seconds, category, message, process=APP):
    """One `log stream --style ndjson` line, `seconds` after 10:00:00."""
    stamp = (datetime(2026, 10, 29, 10) + timedelta(seconds=seconds)).strftime("%Y-%m-%d %H:%M:%S.%f-0700")
    return json.dumps({
        "timestamp": stamp, "eventType": "logEvent", "messageType": "Default", "subsystem": "net.scosman.biscotti",
        "category": category, "processImagePath": process, "processID": 4343 if process == TRANSCRIBER else 4242,
        "eventMessage": message,
    }, ensure_ascii=False)


def low_power_capture(replacing=(), extra=()):
    """Two answers beside the live transcript, in Low Power Mode (the worker
    updates every 2 s):
    - Question 1 (ask 10, lease 10.5, done 22): a decode that began at 9.8
      ends at 10.6, inside the window. The live text falls behind at 21 and
      is live again at 27.5.
    - Question 2 (ask 70, lease 70.2, done 76).
    - The recording stops at 90; its session ends with no gap, and the
      finish after Stop completes."""
    plan = "plan name=concurrent-e2b mode=concurrent closeModelAfterAnswer=true startAfter=recordingStart " \
           "delay=120.0 interval=60.0 questions=2 model=gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf record=10.0+900.0 live=on"
    done = "outcome=complete promptTokens=1000 context=4096 partial=false tokens=40 generated=40 generationSeconds=4.000 cited=1 linked=1"
    events = [
        (0, "chat-load", plan),
        (0, "chat-load", f"worker name=transcriber path={TRANSCRIBER}"),
        (0, "chat-load", "worker name=llm path=/x/BiscottiLLM"),
        (1, "live", "Live session started: 2 track(s), update every 2.000000 s", TRANSCRIBER),
        (2, "live", "Live status: starting"),
        (3, "chat-load", "recording-started"),
        (4, "live.latency", "decode ms=1000"),
        (4, "live", "Live status: live"),
        (10, "chat-load", "ask q=1 t=120.0"),
        (10.5, "chat-load", "lease q=1 loading=true"),
        (10.6, "live.latency", "decode ms=800"),
        (11, "llm-broker", "Model opened: gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf in 500 ms"),
        (13, "chat-load", "first-token q=1"),
        (21, "live", "Live status: catchingUp"),
        (22, "chat-load", f"done q=1 {done}"),
        (25.5, "live.latency", "decode ms=3000"),
        (27.5, "live", "Live status: live"),
        (70, "chat-load", "ask q=2 t=180.0"),
        (70.2, "chat-load", "lease q=2 loading=true"),
        (71, "llm-broker", "Model opened: gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf in 500 ms"),
        (72, "chat-load", "first-token q=2"),
        (76, "chat-load", f"done q=2 {done}"),
        (90, "chat-load", "recording-stopped"),
        (91, "live", "Live session ended with 40 rows and 0 gaps."),
        (91, "live", "Live finish after Stop: finished"),
        (92, "chat-load", "plan-done"),
        *extra,
    ]
    lines_ = [event(*item) for item in sorted(events, key=lambda item: item[0])]
    for old, new in replacing:
        lines_ = [line.replace(old, new) for line in lines_]
    return lines_


def analyzed_low_power(run="lowpower-e2b", **changes):
    return analyze.analyze(analyze.parse_entries(low_power_capture(**changes)), run)


def test_the_live_text_readings():
    result = analyzed_low_power()
    assert result["liveUpdateIntervalSeconds"] == [2.0]
    assert result["liveFinish"] == ["finished"]
    assert result["liveGaps"] == {"count": 0, "withSound": 0, "listed": 0, "byReason": {}, "seconds": 0}
    assert result["rejectedLiveUpdates"] == 0
    assert result["catchUpSeconds"]["perAnswer"] == [pytest.approx(5.5), 0.0]
    assert result["warnings"] == []
    assert result["contention"] == {"passes": True, "reasons": []}


def test_gaps_and_rejected_updates():
    gaps = "Live session ended with 40 rows and 0 gaps.", \
        "Live session ended with 40 rows and 3 gaps. mic 12.00+3.00 s queueOverflow; system 30.00+1.50 s captureGap silent; 1 more"
    rejected = (50, "live", "Live settled text changed instead of growing (12 to 10 characters); the update for the row was rejected")
    result = analyzed_low_power(replacing=[gaps], extra=[rejected])
    assert result["liveGaps"] == {
        "count": 3, "withSound": 1, "listed": 2, "byReason": {"captureGap": 1, "queueOverflow": 1}, "seconds": 4.5,
    }
    assert result["rejectedLiveUpdates"] == 1
    table = analyze.markdown(result)
    assert "| Live gaps (audio missing from the live text) | 3 (1 with sound, 4.5 s; 2 listed): captureGap 1, queueOverflow 1 |" in table
    assert "| Rejected live updates (settled text changed) | 1 |" in table


def test_a_low_power_run_must_update_every_two_seconds():
    warning = "the run is named for Low Power Mode, but the live transcript updated every 1 s (2 s in Low Power Mode): turn Low Power Mode on"
    normal_power = [("update every 2.000000 s", "update every 1.000000 s")]
    assert warning in analyzed_low_power(replacing=normal_power)["warnings"]
    assert warning not in analyzed_low_power(run="concurrent-e2b", replacing=normal_power)["warnings"]
    assert warning not in analyzed_low_power()["warnings"]


def test_markdown_for_the_live_text():
    table = analyze.markdown(analyzed_low_power())
    for text in [
        "| Longest live decode inside answers | 0.80 s |",
        "| Catch-up after answers | median 2.8 s; per answer (s): 5.5, 0.0 |",
        "| Live gaps (audio missing from the live text) | none |",
        "| Rejected live updates (settled text changed) | 0 |",
        "| Live finish after Stop | finished |",
        "| Live update interval | 2 s |",
        "| Contention rule | passes |",
    ]:
        assert text in table
