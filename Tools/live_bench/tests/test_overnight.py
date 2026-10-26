import json
import os
from datetime import datetime, timedelta
from pathlib import Path

import pytest
from test_report import live_clip, wer, write_metrics

import overnight
from overnight import SPEECH_CHOSEN, Runner, RunnerError, State, Step

DURATIONS = {"smoke": 100.0, "soak": 2710.0} | {clip: 190.0 for clip in overnight.CALIBRATION + overnight.VALIDATION}


def test_schedule_runs_by_priority_and_interleaves_options():
    steps = overnight.schedule()
    groups = [step.group for step in steps]

    assert groups[:7] == ["own-load"] * 4 + ["cost", "cost", "baseline"]
    assert groups[7:] == ["validation"] * 8 + ["soak"] * 3 + ["calibration"] * 2 + ["back-to-back"] * 3 + ["calibration"] * 4 + ["extended"] * 14
    assert [step.id for step in steps if step.group == "calibration"][:2] == ["calibration-whisper-small-chosen", "calibration-whisper-small-runner-up"], (
        "whisper-small's interval, chosen in virtual time, is rechecked before the back-to-back arm"
    )
    validation = [step.id for step in steps if step.group == "validation"]
    assert validation == [f"validation-1-{option}" for option in overnight.OPTIONS] + [f"validation-2-{option}" for option in reversed(overnight.OPTIONS)]
    assert [step.id for step in steps if step.group == "soak"] == ["soak-whisper-current", f"soak-{SPEECH_CHOSEN}", "soak-whisper-small"]
    assert all(step.alongside for step in steps if step.group == "back-to-back")
    for step in steps:
        if step.group in {"own-load", "validation", "soak", "back-to-back", "calibration", "extended"}:
            assert {"--load", "call", "--vocabulary-off"} <= set(step.arguments), step.id
            assert ("--virtual-clock" in step.arguments) is False


def test_the_core_fits_the_default_deadline_and_the_extended_block_adds_three_to_four_hours():
    steps = overnight.schedule()
    core = [overnight.estimate_seconds(step, DURATIONS) for step in steps if step.group != "extended"]
    extended = [overnight.estimate_seconds(step, DURATIONS) for step in steps if step.group == "extended"]

    assert sum(core[:-1]) <= overnight.DEFAULT_HOURS * 3600, "only the last recheck may fall past the default deadline"
    assert 3 * 3600 <= sum(extended) <= 4 * 3600
    assert sum(core) + sum(extended) <= 12 * 3600, "well inside --hours 24"
    assert overnight.timeout_seconds(core[7]) == 2 * core[7] + 600


def test_the_plan_adds_the_worst_case_for_completions_whose_recheck_did_not_count(capsys):
    steps = overnight.schedule()
    extra_clips = sum(len(step.fallback_clips) - len(step.clips) for step in steps if step.completes)

    overnight.print_plan(steps, DURATIONS, 24)
    with_completions = capsys.readouterr().out
    overnight.print_plan([step for step in steps if not step.completes], DURATIONS, 24)
    without_completions = capsys.readouterr().out

    assert extra_clips == 18, "six completions, three more clips each"
    minutes = extra_clips * (190 + overnight.CLIP_OVERHEAD_SECONDS) / 60
    assert f"up to {minutes:.0f} min more if completions run all calibration clips because their recheck did not count" in with_completions
    assert "min more" not in without_completions


def test_the_extended_block_covers_the_candidates_on_all_calibration_clips():
    steps = {step.id: step for step in overnight.schedule()}
    rechecked = {step.id for step in steps.values() if step.group == "calibration"}
    extended = [step for step in steps.values() if step.group == "extended"]

    assert len(extended) == 14
    for step in extended:
        clips = set(step.clips)
        assert clips in (set(overnight.CALIBRATION), set(overnight.CALIBRATION) - set(overnight.RECHECK_CLIPS)), step.id
    completions = [step.id for step in extended if set(step.clips) != set(overnight.CALIBRATION)]
    assert len(completions) == len(rechecked) == 6, "each rechecked combination gets the other three clips"

    def configuration(step):
        arguments = list(step.arguments)
        index = arguments.index("--clips")
        return tuple(arguments[:index] + arguments[index + 2:])

    assert {configuration(step) for step in extended if step.completes} == {configuration(steps[step_id]) for step_id in rechecked}, (
        "each completion has its recheck's settings, so the report pools them"
    )
    assert all(steps[step.completes].group == "calibration" and step.fallback_clips == overnight.CALIBRATION for step in extended if step.completes)
    assert {step.id for step in extended if step.completes} == set(completions)
    assert [step.id for step in extended][:2] == ["extended-whisper-current-i2-two-track", "extended-whisper-small-i1-two-track"], "the chosen settings first"
    speech = [step for step in extended if "speechanalyzer" in step.id]
    assert {("--fast-results" in step.arguments, step.arguments[step.arguments.index("--mode") + 1]) for step in speech} == {
        (False, "two-track"), (True, "two-track"), (False, "mixed"), (True, "mixed"),
    }


def test_the_speechanalyzer_variant_is_chosen_by_the_rule(tmp_path):
    shown = [[1.0, 2.0]] * 100
    late = [[4.0, 7.0]] * 100
    speech = {"option": "speechanalyzer", "fast_results": False}
    standard = write_metrics(tmp_path / "standard", "run", {"val-1": live_clip("validation", late, 10)}, model=None, options=speech)
    fast = write_metrics(tmp_path / "fast", "run", {"val-1": live_clip("validation", shown, 10)}, model=None, options={**speech, "fast_results": True})
    baseline = {"val-1": {"split": "validation", "wer": wer(100, 9)}}

    assert overnight.speech_variant({"speechanalyzer": [standard], "speechanalyzer-fast": [fast]}, baseline) == "speechanalyzer-fast"
    assert overnight.speech_variant({"speechanalyzer": [fast], "speechanalyzer-fast": [fast]}, baseline) == "speechanalyzer", "a tie keeps the plainer one"
    assert overnight.speech_variant({}, {}) == "speechanalyzer"
    busy_fast = write_metrics(tmp_path / "busy-fast", "run", {"val-1": live_clip("validation", shown, 10)}, model=None, options={**speech, "fast_results": True}, baseline_idle=0.4)
    quiet_fast = write_metrics(tmp_path / "quiet-fast", "run", {"val-1": live_clip("validation", late, 10)}, model=None, options={**speech, "fast_results": True})
    assert overnight.speech_variant({"speechanalyzer": [standard], "speechanalyzer-fast": [busy_fast, quiet_fast]}, baseline) == "speechanalyzer", (
        "a busy run does not count when a quiet one exists"
    )
    assert Step("s", "soak", ["run", SPEECH_CHOSEN, "--clips", "soak"]).resolved("speechanalyzer-fast") == ["run", *overnight.OPTIONS["speechanalyzer-fast"], "--clips", "soak"]


class FakeRunner(Runner):
    """Runs nothing: each call answers from `outcomes` and records its arguments."""

    def __init__(
        self, tmp_path: Path, outcomes: list, loads: list[float] | None = None, hours: float = 8, score_error: Exception | None = None,
        idles: list[float | None] | None = None,
    ):
        self.calls, self.outcomes, self.loads, self.messages, self.score_error = [], list(outcomes), list(loads or []), [], score_error
        self.idles = list(idles or [])
        self.now, self.timeouts = 0.0, []
        super().__init__(
            tmp_path / "models", tmp_path / "fixtures", tmp_path / "out", tmp_path / "live-bench", self.messages.append,
            datetime.now() + timedelta(hours=hours), clock=lambda: self.now, sleep=self.advance, load=self.next_load,
            power=lambda: {"ac_power": True, "low_power_mode": False}, cpu_idle=self.next_idle,
        )
        (self.folder / "logs").mkdir(parents=True)

    def advance(self, seconds: float) -> None:
        self.now += seconds

    def next_load(self) -> float:
        return self.loads.pop(0) if self.loads else 2.0

    def next_idle(self, seconds: float) -> float | None:
        """A quiet check: it takes its window, then answers from `idles`."""
        self.advance(seconds)
        return self.idles.pop(0) if self.idles else 0.8

    def live_bench(self, arguments, log_path, timeout):
        self.calls.append(arguments)
        self.timeouts.append(timeout)
        folder = self.out / f"run-{len(self.calls)}"
        folder.mkdir(parents=True)
        return self.outcomes.pop(0), folder

    run_alongside = live_bench

    def is_complete(self, folder, step):
        return True

    def score(self, folder):
        if self.score_error:
            raise self.score_error


def steps():
    return [Step("validation-1-a", "validation", ["run", "a"], ["val-1"]), Step("soak-b", "soak", ["run", "b"], ["soak"])]


def test_a_failed_run_is_retried_once_and_a_second_start_skips_finished_steps(tmp_path):
    runner = FakeRunner(tmp_path, outcomes=["timeout", 0, 0])
    state = State(runner.folder / "state.json", {"commit": "abc"})

    overnight.run_schedule(runner, state, steps(), DURATIONS)

    assert [call[1] for call in runner.calls] == ["a", "a", "b"]
    assert runner.timeouts[0] == overnight.timeout_seconds(overnight.estimate_seconds(steps()[0], DURATIONS))
    assert any(message.startswith("validation-1-a: timeout (exit timeout)") for message in runner.messages)
    assert any("attempt 1, median CPU idle 80.0% over 30 s, 1-minute load average 2.0, AC power, Low Power Mode off" in message for message in runner.messages), (
        "load and power logged per run"
    )
    assert state.step("validation-1-a")["attempts"] == 2 and state.is_done("validation-1-a") and state.is_done("soak-b")
    lines = overnight.status_lines(state, steps())
    assert len(lines) == 1 and lines[0].startswith("- validation-1-a: done on attempt 2, after a failed attempt"), "a retry stays visible"

    again = FakeRunner(tmp_path / "again", outcomes=[])
    overnight.run_schedule(again, State(runner.folder / "state.json", {"commit": "abc"}), steps(), DURATIONS)
    assert again.calls == [] and "validation-1-a: done earlier, skipped" in again.messages
    with pytest.raises(RunnerError, match="other code"):
        State(runner.folder / "state.json", {"commit": "def"})


# The quiet limit on this 10-core M1 Max: 50% + 2 threads x 60% / 10 cores + 5 points.
TEN_CORE_QUIET_CPU_IDLE = overnight.report.BUSY_CPU_IDLE + overnight.CALL_LOAD_CPU_THREADS * overnight.CALL_LOAD_CPU_DUTY_CYCLE / 10 + overnight.QUIET_MARGIN


@pytest.fixture
def ten_cores(monkeypatch):
    """The quiet limit of this Mac, whatever Mac runs the tests."""
    monkeypatch.setattr(overnight, "QUIET_CPU_IDLE", TEN_CORE_QUIET_CPU_IDLE)


def test_the_quiet_limit_leaves_a_margin_after_the_call_load():
    """The quiet check runs before live-bench starts the call load that the run's baseline includes."""
    source = (overnight.REPO / "Packages" / "Transcription" / "Sources" / "live-bench" / "SimulatedCallLoad.swift").read_text(encoding="utf-8")

    assert f"static let cpuThreads = {overnight.CALL_LOAD_CPU_THREADS}\n" in source
    assert f"static let cpuDutyCycle = {overnight.CALL_LOAD_CPU_DUTY_CYCLE:g}\n" in source
    assert overnight.CALL_LOAD_CPU_SHARE == pytest.approx(overnight.CALL_LOAD_CPU_THREADS * overnight.CALL_LOAD_CPU_DUTY_CYCLE / os.cpu_count())
    margin = overnight.QUIET_CPU_IDLE - overnight.CALL_LOAD_CPU_SHARE - overnight.report.BUSY_CPU_IDLE
    assert margin == pytest.approx(0.05), "a run that starts at the limit has a baseline 5 points above the busy limit"
    assert TEN_CORE_QUIET_CPU_IDLE == pytest.approx(0.67), "the call load takes 12 points of a 10-core Mac"


def test_a_busy_cpu_delays_the_next_run_and_a_late_step_is_skipped(tmp_path, ten_cores):
    # 65% would leave a baseline with the call load at about 53%, no margin.
    runner = FakeRunner(tmp_path, outcomes=[0], loads=[3.0], idles=[0.4, None, *[0.65] * 20, 0.7], hours=0.5)
    state = State(runner.folder / "state.json", {"commit": "abc"})

    overnight.run_schedule(runner, state, steps(), DURATIONS)

    assert runner.now == 24 * overnight.QUIET_WINDOW_SECONDS, "40%, unreadable and 65% wait; 70% starts the run; one check for the soak"
    assert "waiting: median CPU idle 40.0% over 30 s, 1-minute load average 3.0, under the quiet limit of 67% CPU idle" in runner.messages
    assert [message for message in runner.messages if message.startswith("still waiting")] == [
        "still waiting after 10 min: median CPU idle 65.0% over 30 s, 1-minute load average 2.0",
    ], "a long wait logs its idle every 10 minutes"
    assert sum(message.startswith("waiting:") for message in runner.messages) == 1
    assert "quiet again: median CPU idle 70.0% over 30 s, 1-minute load average 2.0" in runner.messages
    assert [call[1] for call in runner.calls] == ["a"]
    assert state.step("soak-b")["status"] == "skipped-deadline", "a 46-minute soak does not fit in half an hour"


def test_a_high_load_average_with_an_idle_cpu_does_not_wait(tmp_path, ten_cores):
    """Spotlight and mediaanalysisd at night: load 15 to 20 from the efficiency cores' queue, CPU 65 to 75% idle."""
    runner = FakeRunner(tmp_path, outcomes=[0, 0], loads=[20.0] * 4, idles=[0.7, 0.7])
    state = State(runner.folder / "state.json", {"commit": "abc"})

    overnight.run_schedule(runner, state, steps(), DURATIONS)

    assert [call[1] for call in runner.calls] == ["a", "b"]
    assert runner.now == 2 * overnight.QUIET_WINDOW_SECONDS, "one check per run, no waiting"
    assert not any(message.startswith("waiting:") for message in runner.messages)
    assert any("attempt 1, median CPU idle 70.0% over 30 s, 1-minute load average 20.0, AC power" in message for message in runner.messages), (
        "the load average is still logged beside CPU idle"
    )


def test_a_dry_run_measures_a_short_window_and_only_logs_a_busy_cpu(tmp_path, ten_cores):
    runner = FakeRunner(tmp_path, outcomes=[], idles=[0.4], hours=0)
    runner.dry = overnight.DryRun()

    assert runner.wait_for_quiet(), "a dry run does not wait, even past its deadline"
    assert runner.now == runner.dry.quiet_window_seconds
    assert runner.messages == ["dry run: median CPU idle 40.0% over 3 s, 1-minute load average 2.0, under the quiet limit of 67% CPU idle; a real run would wait here"]


def test_cpu_idle_is_the_median_of_each_second():
    # Busy and idle ticks, summed over all cores, read once a second.
    readings = iter([(0, 0), (10, 90), (50, 140), None, (60, 230), (50, 330), (80, 400), (80, 400)])
    sleeps = []

    idle = overnight.median_cpu_idle(7, sleep=sleeps.append, ticks=lambda: next(readings))

    # 90%, 50/90, (unreadable twice), a wrapped counter, 70%, no ticks.
    assert idle == pytest.approx(0.7) and sleeps == [1] * 7
    assert overnight.median_cpu_idle(3, sleep=sleeps.append, ticks=lambda: None) is None, "unreadable"
    assert sleeps == [1] * 10, "an unreadable check still takes its window, so the wait never spins"
    assert overnight.idle_share((100, 100), (120, 180)) == pytest.approx(0.8)
    busy, idle = overnight.cpu_ticks()
    assert busy > 0 and idle > 0, "host_statistics answers on this Mac"
    assert 0.0 <= overnight.median_cpu_idle(1) <= 1.0


def test_completion_needs_every_clip_in_the_manifest(tmp_path):
    runner = Runner(tmp_path, tmp_path, tmp_path, tmp_path / "live-bench", print, datetime.now())
    folder = tmp_path / "run"
    folder.mkdir()
    step = Step("validation-1-a", "validation", ["run"], ["val-1", "val-2"])

    assert not runner.is_complete(None, step)
    (folder / "manifest.json").write_text(json.dumps({"sessions": [{"clip": "val-1"}]}))
    assert not runner.is_complete(folder, step)
    (folder / "manifest.json").write_text(json.dumps({"sessions": [{"clip": "val-1"}, {"clip": "val-2"}]}))
    assert runner.is_complete(folder, step)


def test_a_step_out_of_attempts_is_skipped_with_a_reason_and_scoring_errors_do_not_end_the_night(tmp_path):
    runner = FakeRunner(tmp_path, outcomes=[1, 1, 0], score_error=ValueError("bad metrics"))
    state = State(runner.folder / "state.json", {"commit": "abc"})

    overnight.run_schedule(runner, state, steps(), DURATIONS)

    assert state.step("validation-1-a")["status"] == "failed" and state.step("validation-1-a")["attempts"] == 2
    assert state.step("soak-b")["status"] == "score-failed" and "bad metrics" in state.step("soak-b")["error"]
    lines = overnight.status_lines(state, steps())
    assert lines[0].startswith("- validation-1-a: failed (attempts 2, exit 1")
    assert lines[1].startswith("- soak-b: score-failed (") and "ValueError: bad metrics" in lines[1]

    again = FakeRunner(tmp_path / "again", outcomes=[])
    overnight.run_schedule(again, State(runner.folder / "state.json", {"commit": "abc"}), steps(), DURATIONS)
    assert again.calls == []
    assert "validation-1-a: failed after 2 attempts earlier, skipped" in again.messages
    assert "soak-b: score-failed earlier, skipped" in again.messages


def test_the_deadline_is_kept_across_restarts_and_state_is_replaced_whole(tmp_path):
    path = tmp_path / "state.json"
    first = State(path, {"commit": "abc"}).deadline(7.5, reset=False)

    assert State(path, {"commit": "abc"}).deadline(1.0, reset=False) == first
    assert State(path, {"commit": "abc"}).deadline(1.0, reset=True) < first
    assert not path.with_name("state.json.tmp").exists()
    State(path, {"commit": "abc"}).record("ü-step", status="done")
    assert "ü-step" in path.read_text(encoding="utf-8")


def test_power_is_read_from_pmset():
    on_ac = overnight.parse_power("Now drawing from 'AC Power'\n -InternalBattery-0 100%", " standby 1\n powermode            2\n")
    on_battery = overnight.parse_power("Now drawing from 'Battery Power'\n", " lowpowermode 1\n")

    assert on_ac == {"ac_power": True, "low_power_mode": False}
    assert on_battery == {"ac_power": False, "low_power_mode": True}
    assert overnight.parse_power("", "") == {"ac_power": None, "low_power_mode": None}
    assert overnight.describe_power(on_battery) == "battery, Low Power Mode on"


def test_a_completion_runs_all_calibration_clips_when_its_recheck_does_not_count(tmp_path):
    clips = overnight.REST_OF_CALIBRATION
    completion = Step("extended-x", "extended", ["run", "x", "--clips", ",".join(clips)], clips, completes="calibration-x", fallback_clips=overnight.CALIBRATION)
    # A high load average with the CPU mostly idle counts; CPU idle under half does not.
    recheck = write_metrics(tmp_path / "recheck", "run", {"cal-1": live_clip("calibration", [[1.0, 2.0]] * 10, 1)}, load_average=20.0, baseline_idle=0.7)
    busy = write_metrics(tmp_path / "busy", "run", {"cal-1": live_clip("calibration", [[1.0, 2.0]] * 10, 1)}, baseline_idle=0.4)
    runner = FakeRunner(tmp_path / "runner", outcomes=[0, 0, 0])
    state = State(runner.folder / "state.json", {"commit": "abc"})

    overnight.run_schedule(runner, state, [completion], DURATIONS)
    state.record("calibration-x", status="done", folder=str(busy))
    overnight.run_schedule(runner, State(runner.folder / "state.json", {"commit": "abc"}), [Step(**{**completion.__dict__, "id": "extended-y"})], DURATIONS)
    state = State(runner.folder / "state.json", {"commit": "abc"})
    state.record("calibration-x", status="done", folder=str(recheck))
    overnight.run_schedule(runner, state, [Step(**{**completion.__dict__, "id": "extended-z"})], DURATIONS)

    clip_lists = [call[call.index("--clips") + 1].split(",") for call in runner.calls]
    assert clip_lists == [overnight.CALIBRATION, overnight.CALIBRATION, clips], "not done, then busy: all six; quiet and done: the other three"
    assert "extended-x: calibration-x did not count, so this runs all 6 of its calibration clips" in runner.messages


def test_a_second_runner_on_the_same_folder_refuses_to_start(tmp_path):
    first = overnight.lock_folder(tmp_path)

    with pytest.raises(RunnerError, match="another overnight runner"):
        overnight.lock_folder(tmp_path)
    first.close()
    overnight.lock_folder(tmp_path).close()


def test_the_dry_run_cuts_completions_and_their_fallback_to_one_clip():
    dry = overnight.DryRun()
    completion = next(step for step in overnight.schedule() if step.completes)

    cut = dry.step(completion)

    assert cut.clips == completion.clips[:1] and cut.fallback_clips == overnight.CALIBRATION[:1] and cut.completes == completion.completes
    assert cut.arguments[cut.arguments.index("--clip-seconds") + 1] == "4"
