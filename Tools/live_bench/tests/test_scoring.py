import json

import pytest
from conftest import event, final_record, row, update

import make_fixtures
import score
from normalize import tokenize
from score import Display, HypToken, RefToken


def ref(text: str, start: float, end: float, counted: bool = True, critical: str | None = None) -> RefToken:
    return RefToken(text, start, end, "A", counted, critical)


def hyps(text: str, start: float = 1.0, step: float = 1.0) -> list[HypToken]:
    return [HypToken(word, start + index * step, start + index * step + 0.5) for index, word in enumerate(text.split())]


def test_wer_counts_sub_del_ins():
    reference = [ref(word, index, index + 0.5) for index, word in enumerate("one two three four five six".split())]

    counts, inserted = score.wer_counts(reference, hyps("one too three five six seven"), scored_from=0)

    assert (counts["n"], counts["substitutions"], counts["deletions"], counts["insertions"], counts["hits"]) == (6, 1, 1, 1, 4)
    assert counts["wer"] == pytest.approx(0.5)
    assert inserted == [5]


def test_wer_leaves_out_overlap_speech_and_insertions_beside_it():
    reference = [ref("hello", 0, 0.5), ref("crosstalk", 1, 1.5, counted=False), ref("there", 2, 2.5)]

    counts, _ = score.wer_counts(reference, hyps("hello noise extra there"), scored_from=0)

    assert counts["n"] == 2
    assert (counts["substitutions"], counts["deletions"], counts["insertions"]) == (0, 0, 0)
    assert counts["wer"] == 0


def test_insertions_in_the_lead_in_are_not_counted():
    lead_in_only = [HypToken("hum", 0.2, 0.8), HypToken("noise", 3.0, 3.4)]

    counts, inserted = score.wer_counts([], lead_in_only, scored_from=1.0)
    assert (counts["n"], counts["insertions"], inserted) == (0, 1, [1])

    counts, _ = score.wer_counts([ref("hello", 2.0, 2.4)], [HypToken("hum", 0.2, 0.8), HypToken("hello", 2.0, 2.4)], scored_from=1.0)
    assert counts["insertions"] == 0 and counts["wer"] == 0


def test_spelled_numbers_score_the_same_from_every_source():
    reference = {"lead_in": 0, "words": [
        {"text": word, "start": 1 + index * 0.3, "end": 1.25 + index * 0.3, "speaker": "A", "track": "mic", "scored": True, "overlap": False, "critical": "number"}
        for index, word in enumerate(["two", "hundred", "and", "fifty"])
    ]}
    tokens = score.reference_tokens(reference, None)

    assert [token.text for token in tokens] == ["two", "hundred", "fifty"]
    final_pass = score.keep_stream([HypToken(text, 1.0, 2.2) for text in tokenize("250")])
    assert score.wer_counts(tokens, final_pass, scored_from=0)[0]["wer"] == 0
    display = score.track_display({"r": row(" Two hundred and", 1.0, 1.9, tail=" fifty")}, "mic", 3.0)
    assert display.settled == ["two", "hundred"] and display.tail == ["fifty"], "the stream pass sees across settled text and tail"


def test_crosstalk_counts_insertions_inside_the_other_tracks_speech():
    own = [ref("hello", 1.0, 1.4)]
    other = [ref("budget", 5.0, 5.5), ref("today", 5.6, 6.0)]
    hypothesis = [HypToken("hello", 1.0, 1.4), HypToken("budget", 5.0, 6.0), HypToken("today", 5.0, 6.0), HypToken("um", 9.0, 9.2)]

    _, inserted = score.wer_counts(own, hypothesis, scored_from=0)
    result = score.crosstalk(hypothesis, inserted, own, other)

    assert inserted == [1, 2, 3]
    assert result["insertions"] == 2
    assert [example["text"] for example in result["examples"]] == ["budget", "today"]


def test_crosstalk_inside_a_row_with_the_speakers_own_words_is_counted():
    """A live row has one span; its words are spread over it, so the other
    side's words after the speaker's own still count."""
    own = [ref("right", 1.0, 1.4)]
    other = [ref("budget", 3.0, 3.5), ref("today", 3.5, 4.0)]
    row_span = (1.0, 4.0)
    hypothesis = [HypToken(text, *row_span) for text in ("right", "so", "budget", "today")]

    _, inserted = score.wer_counts(own, hypothesis, scored_from=0)
    result = score.crosstalk(hypothesis, inserted, own, other)

    assert score.word_times(hypothesis) == [(1.0, 1.75), (1.75, 2.5), (2.5, 3.25), (3.25, 4.0)]
    assert [example["text"] for example in result["examples"]] == ["budget", "today"]


def test_repeated_insertions_are_counted_as_repeats():
    reference = [ref(word, index, index + 0.5) for index, word in enumerate("the plan is good".split())]
    hypothesis = hyps("the plan the plan is good fine")

    _, inserted = score.wer_counts(reference, hypothesis, scored_from=0)

    assert inserted == [2, 3, 6]
    assert score.repeats(hypothesis, inserted)["insertions"] == 2, "\"fine\" is new, not a repeat"


def test_latency_keeps_repeated_words_distinct():
    reference = [ref("yes", 1.0, 1.3), ref("well", 5.0, 5.4), ref("yes", 20.0, 20.3)]
    first, second = row(" Yes.", 1.0, 1.3), row(" Well, yes.", 5.0, 20.3)
    events = [
        event(1.5, "mic", [{**first, "settled_text": "", "tail_text": " Yes."}], 1.5),
        event(2.0, "mic", [first], 2.0),
        event(6.0, "mic", [{**second, "settled_text": " Well,", "tail_text": "", "end_time": 5.4}], 6.0),
        event(21.5, "mic", [second], 21.5),
    ]
    _, tokens = score.display_history(events, final_record(22.0), simulated=False)
    hypothesis = tokens["mic"]

    result = score.latency(reference, hypothesis, score.match_tokens(reference, hypothesis))

    assert [token.text for token in hypothesis] == ["yes", "well", "yes"]
    assert result["matched"] == 3 and result["unmatched"] == 0
    assert [pair[0] for pair in result["values"]] == pytest.approx([1.5 - 1.3, 6.0 - 5.4, 21.5 - 20.3])
    assert [pair[1] for pair in result["values"]] == pytest.approx([2.0 - 1.3, 6.0 - 5.4, 21.5 - 20.3])


def test_latency_reports_unmatched_words():
    reference = [ref("yes", 1.0, 1.3), ref("please", 9.0, 9.4), ref("call", 9.5, 9.8), ref("bob", 10.0, 10.3), ref("yes", 20.0, 20.3)]
    events = [
        event(11.0, "mic", [row(" Please call.", 9.0, 9.8)], 11.0),
        event(21.0, "mic", [row(" Yes.", 20.0, 20.3)], 21.0),
    ]
    _, tokens = score.display_history(events, final_record(21.0), simulated=True)

    result = score.latency(reference, tokens["mic"], score.match_tokens(reference, tokens["mic"]))

    assert result["matched"] == 3
    assert [word["text"] for word in result["unmatched_words"]] == ["yes", "bob"]
    assert result["unmatched_words"][0]["start"] == 1.0, "the remaining 'yes' is matched to its own time"
    assert result["coverage"] == pytest.approx(3 / 5)
    assert result["values"][-1][0] == pytest.approx(21.0 - 20.3)


def test_unsettled_words_count_as_slower_than_every_threshold():
    reference = [ref("hello", 1.0, 1.4), ref("there", 2.0, 2.3)]
    tail = row(" Hello", 1.0, 2.3, tail=" there")
    events = [event(3.0, "mic", [tail], 3.0)]
    final = {**final_record(4.0), "session_ended_early": True}
    _, tokens = score.display_history(events, final, simulated=True)

    result = score.latency(reference, tokens["mic"], score.match_tokens(reference, tokens["mic"]))

    assert result["values"][1] == [pytest.approx(0.7), None]
    assert result["settled"]["share_within"]["8"] == 0.5
    assert result["settled"]["p95"] is None


def test_a_later_repeat_of_a_tail_word_is_not_credited_early():
    reference = [ref("the", 1.0, 1.2), ref("plan", 1.3, 1.6), ref("is", 1.7, 1.8), ref("the", 9.0, 9.2), ref("budget", 9.3, 9.8)]
    early = row(" The plan is", 1.0, 1.8, row_id="early")
    late = row(" the budget", 9.0, 9.8, row_id="late")
    events = [
        event(1.9, "mic", [{**early, "settled_text": "", "tail_text": " The plan is the"}], 1.9),
        event(2.5, "mic", [early], 2.5),
        event(10.5, "mic", [late], 10.5),
    ]
    _, tokens = score.display_history(events, final_record(11.0), simulated=True)

    shown = {(token.text, token.start): token.first_shown for token in tokens["mic"]}

    assert shown[("the", 1.0)] == 1.9
    assert shown[("the", 9.0)] == 10.5, "the stray tail 'the' at 1.9 s belongs to another row"


def test_lag_reaches_the_end_only_when_the_session_finishes():
    events = [event(2.0, "mic", [], 2.0), event(4.0, "mic", [], 4.0)]

    finished = score.lag(events, final_record(6.0, [update("mic", [], 6.0)]), ["mic"], simulated=True, duration=6.0)
    failed = score.lag(events, {**final_record(6.0), "session_ended_early": True}, ["mic"], simulated=True, duration=6.0)

    assert finished["reached_end"] and finished["transcribed_through"] == 6.0
    assert not failed["reached_end"] and failed["transcribed_through"] == 4.0
    assert failed["max"] == pytest.approx(2.0), "the finish sample shows the stall"


def test_corrections_count_rewritten_tail_words():
    displays = [
        Display(1, [], ["the", "cat"], [(0, 1)] * 2),
        Display(2, [], ["the", "hat", "sat"], [(0, 1)] * 3),
        Display(3, ["the", "hat", "sat"], ["down", "here"], [(0, 1)] * 5),
        Display(4, ["the", "hat", "sat"], ["down"], [(0, 1)] * 4),
        Display(5, ["the", "hat", "sat", "down"], [], [(0, 1)] * 4),
    ]

    result = score.corrections(displays, final_count=4)

    assert result["rewritten_words"] == 2
    assert result["longest_rewrite"] == 1
    assert result["per_100_words"] == pytest.approx(50)


def test_corrections_count_only_displays_a_reader_could_see():
    """A burst of volatile results a letter apart within a millisecond is one display."""
    burst = [Display(1.0 + index * 0.001, [], words, [(0, 1)] * len(words)) for index, words in enumerate([["the"], ["the", "qu"], ["the", "quarter"], ["the", "quarterly"]])]
    later = [
        Display(2.0, [], ["the", "quarterly", "plan"], [(0, 1)] * 3),
        Display(3.0, [], ["the", "quarterly", "plans"], [(0, 1)] * 3),
        Display(3.02, [], ["the", "quarterly", "plan"], [(0, 1)] * 3),
        Display(4.0, ["the", "quarterly", "plan"], [], [(0, 1)] * 3),
    ]

    result = score.corrections(burst + later, final_count=3)

    assert [display.time for display in score.visible_displays(burst + later)] == [1.003, 2.0, 3.02, 4.0]
    assert result["rewritten_words"] == 0, "the partial words and the 20 ms flicker were never seen"


def test_first_display_growth_compares_the_last_ten_minutes_with_minutes_one_to_eleven():
    early = [[1.0, 2.0]] * 19 + [[2.0, 3.0]]
    late = [[4.0, 5.0]] * 18 + [[9.0, 9.5]] * 2
    latency = {"values": early + late + [[None, None]], "ends": [100.0] * 20 + [2500.0] * 20 + [2600.0]}

    assert score.first_display_growth(latency, duration=2700.0) == pytest.approx(9.0 - 1.0), "nearest-rank p95 of 20 words is the 19th"
    assert score.first_display_growth(latency, duration=1200.0) is None, "too short to compare"
    assert score.first_display_growth({"values": early, "ends": [100.0] * 20}, duration=2700.0) is None, "nothing in the last ten minutes"


def test_text_that_stops_late_in_a_long_clip_is_flagged():
    shown_early = {"values": [[1.0, 2.0]] * 5, "ends": [100.0] * 5, "unmatched_words": [{"text": "late", "speaker": "A", "start": 2500.0}]}
    shown_late_too = {**shown_early, "values": [[1.0, 2.0]] * 6, "ends": [100.0] * 5 + [2600.0]}

    assert score.first_display_stopped(shown_early, duration=2700.0)
    assert score.first_display_growth(shown_early, duration=2700.0) is None, "growth has nothing to compare"
    assert not score.first_display_stopped(shown_late_too, duration=2700.0)
    assert not score.first_display_stopped({**shown_early, "unmatched_words": []}, duration=2700.0), "nothing was said late"
    assert not score.first_display_stopped(shown_early, duration=1200.0), "too short to compare"


def test_first_display_is_summarized_per_five_minutes_on_long_clips():
    latency = {"ends": [100.0, 200.0, 650.0, 2650.0], "values": [[1.0, 2.0], [3.0, 4.0], [None, None], [9.0, 9.0]]}

    blocks = score.first_display_by_block(latency, duration=2700.0)

    assert len(blocks) == 9
    assert blocks[0] == 3.0 and blocks[2] is None and blocks[8] == 9.0, "the late stall shows in the last block"
    assert score.first_display_by_block(latency, duration=1200.0) is None


def test_decodes_during_silence_are_counted():
    reference = [ref("hello", 1.0, 1.3), ref("again", 8.5, 8.9)]
    events = [
        event(2.0, "mic", [], 2.0),
        event(4.0, "mic", [], 4.0),
        event(6.0, "mic", [], 6.0, decode_ms=None),
        event(8.0, "mic", [], 8.0),
        event(9.0, "mic", [], 9.0),
        event(9.0, "system", [], 9.0),
    ]

    assert score.decodes(events, "mic", reference) == {"decodes": 4, "decodes_in_silence": 2}


def test_score_run_end_to_end(tmp_path, fixtures):
    lock = json.loads((fixtures / make_fixtures.LOCK_FILE).read_text())
    run = tmp_path / "run"
    clip = run / "smoke"
    clip.mkdir(parents=True)
    manifest = {
        "kind": "run",
        "options": {"option": "whisper-current", "interval": 2, "mode": "two-track", "clips": ["smoke"], "load": "none", "clock": "simulated", "vocabulary": False},
        "model": {"name": "test-model"},
        "machine": {"model": "Mac", "chip": "M", "memory_bytes": 17179869184, "operating_system": "26"},
        "power": {"low_power_mode": False, "thermal_state": "nominal"},
        "repo": {},
        "fixtures": {"lock_sha256": make_fixtures.sha256(fixtures / make_fixtures.LOCK_FILE), "clips": {"smoke": lock["clips"]["smoke"]["files"]}},
        "memory_baseline": {"seconds": 30, "samples": 30, "median_used_bytes": 1000},
        "sessions": [{"clip": "smoke", "warm": False, "started_at": "now"}],
    }
    (run / "manifest.json").write_text(json.dumps(manifest))
    mic = row(" So twenty five euros", 1.1, 2.4, row_id="m1")
    system = row(" No, I don't think.", 2.6, 3.7, track="system", row_id="s1")
    late = row(" Rose. Late.", 4.5, 6.4, track="system", row_id="s2")
    events = [
        event(3.0, "mic", [{**mic, "settled_text": " So twenty", "tail_text": " five euros"}], 3.0),
        event(4.0, "mic", [mic], 4.0),
        event(4.5, "system", [system], 4.5),
        event(6.0, "mic", [], 6.0),
    ]
    (clip / "events.jsonl").write_text("\n".join(json.dumps(entry) for entry in events) + "\n")
    (clip / "final.json").write_text(json.dumps(final_record(6.5, [update("mic", [], 6.5), update("system", [late], 6.5)])))
    samples = [
        {"elapsed": 0, "phase": "baseline", "system_used_bytes": 1000, "process_footprint_bytes": 1, "thermal_state": "nominal", "memory_pressure": "normal",
         "one_minute_load_average": 1.5, "cpu_idle": 0.9},
        {"elapsed": 1, "phase": "clip:smoke", "system_used_bytes": 5000, "process_footprint_bytes": 9, "thermal_state": "serious", "memory_pressure": "normal",
         "one_minute_load_average": 3.0, "cpu_idle": None},
        {"elapsed": 2, "phase": "clip:smoke", "system_used_bytes": 3000, "process_footprint_bytes": 7, "thermal_state": "serious", "memory_pressure": "warning",
         "one_minute_load_average": 5.0, "cpu_idle": 0.4},
    ]
    (run / "resources.jsonl").write_text("\n".join(json.dumps(sample) for sample in samples) + "\n")

    metrics = score.score_run(run, fixtures)

    smoke = metrics["clips"]["smoke"]
    assert smoke["split"] == "smoke"
    assert smoke["wer"]["wer"] == 0, "lead-in and overlap words are not scored; the rest match"
    assert smoke["critical"] == {"total": 4, "survived": 4, "missing": []}, "twenty, five, don't, Rose; the overlapping \"No\" is not scored"
    assert smoke["latency"]["coverage"] == 1
    assert smoke["streams"]["mic"]["corrections"]["rewritten_words"] == 0
    assert smoke["streams"]["mic"]["decodes"] == 3
    assert smoke["tcorc_wer"] is not None
    assert smoke["finish"]["session_ended_early"] is False
    assert smoke["lag"]["reached_end"]
    assert smoke["lag"]["first_display_growth"] is None, "a smoke clip is too short to compare"
    assert smoke["lag"]["first_display_stopped"] is False
    assert len(smoke["latency"]["ends"]) == len(smoke["latency"]["values"])
    assert smoke["streams"]["mic"]["crosstalk"] == {"insertions": 0, "examples": []}
    assert metrics["run"]["lock_sha256"] == manifest["fixtures"]["lock_sha256"]
    assert metrics["resources"]["max_added_bytes"] == 4000
    assert metrics["resources"]["longest_serious_thermal_seconds"] == 1
    assert metrics["resources"]["load"] == {"median_load_average": 4.0, "p90_load_average": pytest.approx(4.8), "median_cpu_idle": 0.4}
    assert metrics["resources"]["baseline_load"] == {"median_load_average": 1.5, "p90_load_average": 1.5, "median_cpu_idle": 0.9}, "before the engine loaded"
    assert metrics["missing_clips"] == {}
    assert smoke["streams"]["mic"]["corrections"]["words"] == 4
    json.dumps(metrics, allow_nan=False)

    unfinished = {**manifest, "sessions": []}
    (run / "manifest.json").write_text(json.dumps(unfinished))
    assert score.score_run(run, fixtures)["missing_clips"] == {"smoke": "smoke"}, "a clip the run never finished is recorded"

    manifest["fixtures"]["clips"]["smoke"]["mic.wav"] = "0" * 64
    (run / "manifest.json").write_text(json.dumps(manifest))
    with pytest.raises(make_fixtures.LockMismatch, match="smoke/mic.wav"):
        score.score_run(run, fixtures)
