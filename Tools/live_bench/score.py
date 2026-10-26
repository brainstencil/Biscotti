"""Score one live-bench results folder and write its metrics.json.

    uv run python score.py --run RESULTS_FOLDER --fixtures FIXTURES

Works for `live-bench run` folders (live sessions) and `final-pass` folders
(the accuracy baseline: WER and critical words only). The fixtures must match
fixtures.lock.json, and the run's manifest must name the same fixture hashes.

Per clip and stream (mic and system in two-track mode, one stream in mixed
mode and for the final pass):

- WER on non-overlap scored speech, with substitutions, deletions and
  insertions (jiwer). Insertions next to overlap or unscored speech, or
  within the lead-in, are left out with it. In two-track mode, counted
  insertions that fall inside the other track's speech and outside the
  stream's own are reported as crosstalk; a live row has one time span, so
  each of its words is placed by spreading the row's words evenly over it.
  Counted insertions that repeat one of the four words before them are
  reported as repeats, a sign of duplicate text from the agreement step.
- Matching for latency and critical words: the longest common subsequence of
  reference and hypothesis tokens where a pair needs equal text, a time that
  fits (the hypothesis row spans the reference word, within 1 s) and, live,
  a first display no earlier than the word began. Repeated words therefore
  stay distinct, and a reference word without a match is reported unmatched.
  A tail word counts as shown only where it sits at most one word from its
  final position, in a row whose time fits.
- Latency from each matched reference word's end to its first correct
  display and to its settled display. Display time is the event's monotonic
  time for real-time runs and its source time (simulated) otherwise.
- Corrections per 100 words and the longest rewritten tail, counted over the
  displays a reader could see: of displays less than 50 ms apart, only the
  last. Words shown during reference silence; decodes and decodes during
  silence; lag (source time minus transcribed-through) through the finish,
  and whether transcription reached the end of the clip; on clips long
  enough, the growth of lag and of p95 first-display latency; gaps;
  tcORC-WER (MeetEval) on clips with overlap, as a diagnostic. The
  system load (median and p90 1-minute load average, median CPU idle) in
  the 30 s baseline before the engine loads, which report.py uses to leave
  busy runs out, and while the clips replayed, for display. On long
  clips, p95 first-display latency per five-minute block, so a stall late
  in the soak shows even where growth does not.

Clips the manifest lists but has no session for (the run stopped before
they finished) are recorded as missing; report.py fails their gates.

Text is tokenized word by word, then "and" inside spelled numbers is dropped
over each stream's whole token sequence, the same way for the reference, the
final pass and the live display.
"""

from __future__ import annotations

import argparse
import bisect
import difflib
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import jiwer
import numpy as np
from meeteval.wer import tcorcwer

from make_fixtures import LOCK_FILE, LockMismatch, read_json, sha256, verify_lock
from normalize import number_and_mask, tokenize

TIME_TOLERANCE = 1.0
SILENCE_PADDING = 0.5
MAX_TAIL_SHIFT = 1
END_TOLERANCE = 0.5
SEGMENT_PAUSE = 1.0
TCORC_COLLAR = 5.0
LATENCY_THRESHOLDS = (3.0, 5.0, 8.0)
LAG_WINDOW_SECONDS = 600.0
LAG_GROWTH_MIN_SECONDS = 1500.0
TIMELINE_BLOCK_SECONDS = 300.0
REPEAT_WINDOW = 4
# About one frame: a display replaced sooner was never seen.
VISIBLE_DISPLAY_SECONDS = 0.05
EXAMPLE_COUNT = 10


@dataclass
class RefToken:
    text: str
    start: float
    end: float
    speaker: str
    counted: bool
    critical: str | None


@dataclass
class HypToken:
    text: str
    start: float
    end: float
    first_shown: float = math.inf
    settled: float = math.inf


# MARK: - Reference


def keep_stream(tokens: list, text=lambda token: token.text) -> list:
    """The tokens without "and" inside spelled numbers, judged over the whole stream."""
    return [token for token, kept in zip(tokens, number_and_mask([text(token) for token in tokens])) if kept]


def reference_tokens(reference: dict, tracks: set[str] | None) -> list[RefToken]:
    """Normalized reference tokens of the given tracks (None: all), in time order."""
    tokens = []
    for word in reference["words"]:
        if tracks is not None and word["track"] not in tracks:
            continue
        counted = word["scored"] and not word["overlap"]
        for text in tokenize(word["text"]):
            tokens.append(RefToken(text, word["start"], word["end"], word["speaker"], counted, word.get("critical")))
    tokens.sort(key=lambda token: token.start)
    return keep_stream(tokens)


def stream_tracks(mode: str) -> dict[str, set[str] | None]:
    """Hypothesis stream → the reference tracks it transcribes."""
    if mode == "two-track":
        return {"mic": {"mic"}, "system": {"system"}}
    return {"mixed": None}


# MARK: - WER


def wer_counts(reference: list[RefToken], hypothesis: list[HypToken], scored_from: float) -> tuple[dict, list[int]]:
    """Substitutions, deletions and insertions on counted reference tokens,
    and the hypothesis indices of the counted insertions.

    An insertion counts when its row ends after the lead-in (`scored_from`)
    and every reference token beside it counts.
    """
    n = sum(token.counted for token in reference)
    hits = substitutions = deletions = 0
    inserted: list[int] = []
    if not reference:
        inserted = [index for index, token in enumerate(hypothesis) if token.end > scored_from]
    elif not hypothesis:
        deletions = n
    else:
        output = jiwer.process_words(" ".join(token.text for token in reference), " ".join(token.text for token in hypothesis))
        for chunk in output.alignments[0]:
            counted = [reference[index].counted for index in range(chunk.ref_start_idx, chunk.ref_end_idx)]
            if chunk.type == "equal":
                hits += sum(counted)
            elif chunk.type == "substitute":
                substitutions += sum(counted)
            elif chunk.type == "delete":
                deletions += sum(counted)
            else:
                neighbors = [index for index in (chunk.ref_start_idx - 1, chunk.ref_start_idx) if 0 <= index < len(reference)]
                if neighbors and all(reference[index].counted for index in neighbors):
                    inserted += [index for index in range(chunk.hyp_start_idx, chunk.hyp_end_idx) if hypothesis[index].end > scored_from]
    errors = substitutions + deletions + len(inserted)
    counts = {
        "n": n,
        "hits": hits,
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": len(inserted),
        "wer": errors / n if n else None,
    }
    return counts, inserted


def pooled_wer(parts: list[dict]) -> dict:
    total = {key: sum(part[key] for part in parts) for key in ("n", "hits", "substitutions", "deletions", "insertions")}
    errors = total["substitutions"] + total["deletions"] + total["insertions"]
    total["wer"] = errors / total["n"] if total["n"] else None
    return total


# MARK: - Matching


def match_tokens(reference: list[RefToken], hypothesis: list[HypToken], tolerance: float = TIME_TOLERANCE) -> list[tuple[int, int]]:
    """Index pairs of the longest time-compatible common subsequence."""
    n, m = len(reference), len(hypothesis)
    if not n or not m:
        return []
    vocabulary: dict[str, int] = {}
    hyp_ids = np.array([vocabulary.setdefault(token.text, len(vocabulary)) for token in hypothesis])
    hyp_start = np.array([token.start for token in hypothesis])
    hyp_end = np.array([token.end for token in hypothesis])
    hyp_shown = np.array([token.first_shown for token in hypothesis])

    def compatible(ref: RefToken) -> np.ndarray:
        return (
            (hyp_ids == vocabulary.get(ref.text, -1))
            & (hyp_start - tolerance <= ref.end)
            & (ref.start <= hyp_end + tolerance)
            & (hyp_shown >= ref.start - tolerance)
        )

    lengths = np.zeros((n + 1, m + 1), dtype=np.int16 if min(n, m) < 32000 else np.int32)
    for i, ref in enumerate(reference, start=1):
        previous = lengths[i - 1]
        candidates = np.maximum(previous[1:], previous[:-1] + compatible(ref))
        lengths[i, 1:] = np.maximum.accumulate(candidates)
    pairs = []
    i, j = n, m
    while i and j:
        if lengths[i, j] == lengths[i - 1, j - 1] + 1 and compatible(reference[i - 1])[j - 1]:
            pairs.append((i - 1, j - 1))
            i, j = i - 1, j - 1
        elif lengths[i - 1, j] == lengths[i, j]:
            i -= 1
        else:
            j -= 1
    pairs.reverse()
    return pairs


def finite_or_none(value: float) -> float | None:
    return value if math.isfinite(value) else None


def summarize(values: list[float | None]) -> dict:
    """Nearest-rank percentiles and the share within each threshold. None
    (never shown or never settled) counts as slower than every threshold."""
    if not values:
        return {"count": 0, "p50": None, "p95": None, "max": None, "share_within": {}}
    array = np.array([math.inf if value is None else value for value in values])
    return {
        "count": len(values),
        "p50": finite_or_none(float(np.percentile(array, 50, method="inverted_cdf"))),
        "p95": finite_or_none(float(np.percentile(array, 95, method="inverted_cdf"))),
        "max": finite_or_none(float(array.max())),
        "share_within": {f"{limit:g}": float(np.mean(array <= limit)) for limit in LATENCY_THRESHOLDS},
    }


def latency(reference: list[RefToken], hypothesis: list[HypToken], pairs: list[tuple[int, int]]) -> dict:
    """First-display and settled latency for each matched counted reference token."""
    matched = {ref_index: hyp_index for ref_index, hyp_index in pairs}
    first, settled, ends, slowest, unmatched = [], [], [], [], []
    for index, token in enumerate(reference):
        if not token.counted:
            continue
        if index not in matched:
            unmatched.append({"text": token.text, "speaker": token.speaker, "start": token.start})
            continue
        hyp = hypothesis[matched[index]]
        first.append(finite_or_none(hyp.first_shown - token.end))
        settled.append(finite_or_none(hyp.settled - token.end))
        ends.append(token.end)
        slowest.append({"text": token.text, "end": token.end, "first": first[-1], "settled": settled[-1]})
    total = len(first) + len(unmatched)
    slowest.sort(key=slowness)
    return {
        "matched": len(first),
        "unmatched": len(unmatched),
        "coverage": len(first) / total if total else None,
        "first_display": summarize(first),
        "settled": summarize(settled),
        "values": [[a, b] for a, b in zip(first, settled)],
        "ends": ends,
        "unmatched_words": unmatched,
        "slowest": slowest[:EXAMPLE_COUNT],
    }


def first_display_growth(latency: dict, duration: float) -> float | None:
    """p95 first-display latency of the words spoken in the last
    LAG_WINDOW_SECONDS minus that of the words spoken from 60 s on, as lag
    growth compares them. Lag follows transcribed-through, which for
    SpeechAnalyzer is the audio it accepted, not the audio it analyzed; this
    measures text reaching the display, the same way for every engine.

    Every matched word has a display time: it is in the last display."""
    if duration < LAG_GROWTH_MIN_SECONDS:
        return None
    timed = [(end, first) for end, (first, _) in zip(latency["ends"], latency["values"]) if first is not None]
    early = [first for end, first in timed if 60 <= end < 60 + LAG_WINDOW_SECONDS]
    late = [first for end, first in timed if duration - LAG_WINDOW_SECONDS <= end <= duration]
    if not early or not late:
        return None
    return float(np.percentile(late, 95, method="inverted_cdf") - np.percentile(early, 95, method="inverted_cdf"))


def first_display_by_block(latency: dict, duration: float) -> list[float | None] | None:
    """p95 first-display latency of the words spoken in each
    TIMELINE_BLOCK_SECONDS block, on clips long enough for growth; None for
    a block with no word shown. A stall that starts late shows here even
    when growth, which compares whole ten-minute windows, does not."""
    if duration < LAG_GROWTH_MIN_SECONDS:
        return None
    blocks: list[list[float]] = [[] for _ in range(math.ceil(duration / TIMELINE_BLOCK_SECONDS))]
    for end, (first, _) in zip(latency["ends"], latency["values"]):
        if first is not None:
            blocks[min(int(end // TIMELINE_BLOCK_SECONDS), len(blocks) - 1)].append(first)
    return [float(np.percentile(block, 95, method="inverted_cdf")) if block else None for block in blocks]


def first_display_stopped(latency: dict, duration: float) -> bool:
    """True when, in a clip long enough for growth, words spoken in the last
    LAG_WINDOW_SECONDS were never shown although words from 60 s on were:
    text stopped reaching the display. first_display_growth has nothing to
    compare then, and for SpeechAnalyzer lag does not show it either."""
    if duration < LAG_GROWTH_MIN_SECONDS:
        return False
    shown = [end for end, (first, _) in zip(latency["ends"], latency["values"]) if first is not None]

    def in_last_window(time: float) -> bool:
        return duration - LAG_WINDOW_SECONDS <= time <= duration

    shown_early = any(60 <= end < 60 + LAG_WINDOW_SECONDS for end in shown)
    spoken_late = any(in_last_window(word["start"]) for word in latency["unmatched_words"])
    return shown_early and spoken_late and not any(in_last_window(end) for end in shown)


def slowness(entry: dict) -> float:
    """Sort key: slowest settled first, never-settled before all."""
    return -math.inf if entry["settled"] is None else -entry["settled"]


def critical_words(reference: list[RefToken], pairs: list[tuple[int, int]]) -> dict:
    matched = {ref_index for ref_index, _ in pairs}
    critical = [(index, token) for index, token in enumerate(reference) if token.counted and token.critical]
    missing = [{"text": token.text, "category": token.critical, "start": token.start} for index, token in critical if index not in matched]
    return {"total": len(critical), "survived": len(critical) - len(missing), "missing": missing}


# MARK: - Live display


@dataclass
class Display:
    """One track's text after an event: settled tokens, then the tail, and
    the time span of the row each token is in."""

    time: float
    settled: list[str]
    tail: list[str]
    spans: list[tuple[float, float]]

    @property
    def words(self) -> list[str]:
        return self.settled + self.tail


def track_display(rows: dict[str, dict], track: str, time: float) -> Display:
    """The track's display. Only the newest row has a tail, so settled tokens all come first."""
    settled, tail = [], []
    for row in sorted((row for row in rows.values() if row["track"] == track), key=lambda row: row["start_time"]):
        span = (row["start_time"], row["end_time"])
        settled += [(token, span) for token in tokenize(row["settled_text"])]
        tail += [(token, span) for token in tokenize(row["tail_text"])]
    keep = number_and_mask([token for token, _ in settled + tail])
    settled = [entry for entry, kept in zip(settled, keep) if kept]
    tail = [entry for entry, kept in zip(tail, keep[len(keep) - len(tail) :]) if kept]
    return Display(time, [token for token, _ in settled], [token for token, _ in tail], [span for _, span in settled + tail])


def display_history(events: list[dict], final: dict, simulated: bool) -> tuple[dict[str, list[Display]], dict[str, list[HypToken]]]:
    """Every display of every track, and each track's final tokens with timings."""
    rows: dict[str, dict] = {}
    history: dict[str, list[Display]] = {}
    end_time = final["t_release"] if simulated else final["t_event"]
    stamped = [(event["t_release"] if simulated else event["t_event"], event["update"]) for event in events]
    stamped += [(end_time, update) for update in final["updates"]]
    for time, update in stamped:
        for row in update["rows"]:
            rows[row["id"]] = row
        history.setdefault(update["track"], []).append(track_display(rows, update["track"], time))
    tokens = {track: final_tokens(displays) for track, displays in history.items()}
    return history, tokens


def spans_meet(first: tuple[float, float], second: tuple[float, float]) -> bool:
    return first[0] - TIME_TOLERANCE <= second[1] and second[0] <= first[1] + TIME_TOLERANCE


def final_tokens(displays: list[Display]) -> list[HypToken]:
    """The last display's tokens, with when each was first shown correctly and settled.

    A tail word is credited to a final word only near its own position (at
    most MAX_TAIL_SHIFT words away) and in a row whose time fits, so a later
    repeat of a common word such as "the" is not credited early.
    """
    last = displays[-1]
    final = last.words
    tokens = [HypToken(text, start, end) for text, (start, end) in zip(final, last.spans)]
    for display in displays:
        count = len(display.settled)
        for index in range(min(count, len(tokens))):
            tokens[index].settled = min(tokens[index].settled, display.time)
            tokens[index].first_shown = min(tokens[index].first_shown, display.time)
        window = final[count : count + len(display.tail) + MAX_TAIL_SHIFT]
        matcher = difflib.SequenceMatcher(None, display.tail, window, autojunk=False)
        for block in matcher.get_matching_blocks():
            if abs(block.b - block.a) > MAX_TAIL_SHIFT:
                continue
            for offset in range(block.size):
                index = count + block.b + offset
                shown_span = display.spans[count + block.a + offset]
                if spans_meet(shown_span, (tokens[index].start, tokens[index].end)):
                    tokens[index].first_shown = min(tokens[index].first_shown, display.time)
    return tokens


def visible_displays(displays: list[Display]) -> list[Display]:
    """Of each run of displays less than VISIBLE_DISPLAY_SECONDS apart, only the
    last. SpeechAnalyzer sends a burst of volatile results a letter or a word
    apart within about a millisecond; nobody sees those steps."""
    return [display for display, after in zip(displays, displays[1:] + [None]) if after is None or after.time - display.time >= VISIBLE_DISPLAY_SECONDS]


def corrections(displays: list[Display], final_count: int) -> dict:
    """Previously shown words that a later visible display changed or removed."""
    displays = visible_displays(displays)
    rewritten, longest = 0, 0
    for before, after in zip(displays, displays[1:]):
        old, new = before.words, after.words
        common = 0
        while common < min(len(old), len(new)) and old[common] == new[common]:
            common += 1
        rewritten += len(old) - common
        longest = max(longest, len(old) - common)
    return {"rewritten_words": rewritten, "words": final_count, "per_100_words": 100 * rewritten / max(1, final_count), "longest_rewrite": longest}


class Speech:
    """Where the reference has speech, as merged intervals, for fast overlap tests."""

    def __init__(self, reference: list[RefToken], padding: float = 0.0):
        self.starts: list[float] = []
        self.ends: list[float] = []
        for start, end in sorted((token.start - padding, token.end + padding) for token in reference):
            if self.ends and start <= self.ends[-1]:
                self.ends[-1] = max(self.ends[-1], end)
            else:
                self.starts.append(start)
                self.ends.append(end)

    def overlaps(self, start: float, end: float) -> bool:
        index = bisect.bisect_right(self.ends, start)
        return index < len(self.starts) and self.starts[index] < end


def word_times(hypothesis: list[HypToken]) -> list[tuple[float, float]]:
    """Each token's own time: a run of tokens sharing one span (a live row)
    split evenly over it. Final-pass words keep their own times."""
    times: list[tuple[float, float]] = []
    first = 0
    while first < len(hypothesis):
        span = (hypothesis[first].start, hypothesis[first].end)
        last = first
        while last < len(hypothesis) and (hypothesis[last].start, hypothesis[last].end) == span:
            last += 1
        step = (span[1] - span[0]) / (last - first)
        times += [(span[0] + offset * step, span[0] + (offset + 1) * step) for offset in range(last - first)]
        first = last
    return times


def crosstalk(hypothesis: list[HypToken], inserted: list[int], own: list[RefToken], other: list[RefToken]) -> dict:
    """Counted insertions inside the other track's speech and outside this
    track's: the other side's voice transcribed on this track. Each word is
    placed within its row (word_times), so crosstalk that shares a row with
    the speaker's own words is counted too."""
    own_speech, other_speech = Speech(own), Speech(other)
    times = word_times(hypothesis)
    found = [
        {"text": hypothesis[index].text, "start": round(times[index][0], 2)}
        for index in inserted
        if other_speech.overlaps(*times[index]) and not own_speech.overlaps(*times[index])
    ]
    return {"insertions": len(found), "examples": found[:EXAMPLE_COUNT]}


def repeats(hypothesis: list[HypToken], inserted: list[int]) -> dict:
    """Counted insertions that repeat one of the REPEAT_WINDOW words before
    them, as duplicate text from the agreement step would ("the plan the
    plan"). Speakers' own repeats are in the reference and are not insertions."""
    found = [
        {"text": hypothesis[index].text, "start": hypothesis[index].start}
        for index in inserted
        if hypothesis[index].text in {token.text for token in hypothesis[max(0, index - REPEAT_WINDOW) : index]}
    ]
    return {"insertions": len(found), "examples": found[:EXAMPLE_COUNT]}


def silence_text(hypothesis: list[HypToken], reference: list[RefToken]) -> dict:
    """Hypothesis words whose row lies wholly in reference silence."""
    speech = Speech(reference, SILENCE_PADDING)
    found = [{"text": token.text, "start": token.start} for token in hypothesis if not speech.overlaps(token.start, token.end)]
    return {"words": len(found), "examples": found[:EXAMPLE_COUNT]}


def decodes(events: list[dict], track: str, reference: list[RefToken]) -> dict:
    """Decodes on the track, and those whose new audio held no reference speech."""
    speech = Speech(reference)
    total = silent = 0
    previous = 0.0
    for event in events:
        update = event["update"]
        if update["track"] != track:
            continue
        through = update["transcribed_through"]
        if update.get("decode_milliseconds") is not None:
            total += 1
            if not speech.overlaps(previous, max(through, previous + 1e-6)):
                silent += 1
        previous = max(previous, through)
    return {"decodes": total, "decodes_in_silence": silent}


def lag(events: list[dict], final: dict, tracks: list[str], simulated: bool, duration: float) -> dict:
    """Source time minus the least transcribed-through across tracks, after
    each event and after the finish, and whether transcription reached the
    clip's end. A session that died or stalled does not reach it."""
    through = dict.fromkeys(tracks, 0.0)
    samples = []
    for event in events:
        update = event["update"]
        through[update["track"]] = update["transcribed_through"]
        time = event["t_release"] if simulated else event["t_event"]
        samples.append((time, time - min(through.values())))
    for update in final["updates"]:
        through[update["track"]] = update["transcribed_through"]
    end_time = final["t_release"] if simulated else final["t_event"]
    samples.append((end_time, end_time - min(through.values())))
    reached = min(through.values())
    values = np.array([value for _, value in samples])
    result = {
        "max": float(values.max()),
        "p95": float(np.percentile(values, 95)),
        "growth": None,
        "transcribed_through": reached,
        "reached_end": reached >= duration - END_TOLERANCE,
    }
    if duration >= LAG_GROWTH_MIN_SECONDS:
        # Growth compares the replay itself; the finish sample is left out.
        early = [value for time, value in samples[:-1] if 60 <= time < 60 + LAG_WINDOW_SECONDS]
        late = [value for time, value in samples[:-1] if duration - LAG_WINDOW_SECONDS <= time <= duration]
        if early and late:
            result["growth"] = float(np.percentile(late, 95) - np.percentile(early, 95))
    return result


def gaps(events: list[dict], final: dict) -> dict:
    found: dict[str, dict] = {}
    for update in [event["update"] for event in events] + final["updates"]:
        for gap in update["gaps"]:
            entry = found.setdefault(gap["reason"], {"count": 0, "seconds": 0.0})
            entry["count"] += 1
            entry["seconds"] += gap["duration"]
    return found


# MARK: - tcORC-WER


def reference_segments(reference: list[RefToken], session: str) -> list[dict]:
    """Each speaker's tokens as utterances split at pauses."""
    segments: list[dict] = []
    last: dict[str, dict] = {}
    for token in reference:
        current = last.get(token.speaker)
        if current is None or token.start - current["end_time"] > SEGMENT_PAUSE:
            current = {"session_id": session, "speaker": token.speaker, "start_time": token.start, "end_time": token.end, "words": token.text}
            segments.append(current)
            last[token.speaker] = current
        else:
            current["end_time"] = max(current["end_time"], token.end)
            current["words"] += " " + token.text
    return segments


def hypothesis_segments(streams: dict[str, list[HypToken]], session: str) -> list[dict]:
    """One segment per run of tokens with the same time span: a live row, or a final-pass word."""
    segments: list[dict] = []
    for stream, tokens in streams.items():
        previous = None
        for token in tokens:
            if previous is not None and (token.start, token.end) == (previous["start_time"], previous["end_time"]):
                previous["words"] += " " + token.text
                continue
            previous = {"session_id": session, "speaker": stream, "start_time": token.start, "end_time": token.end, "words": token.text}
            segments.append(previous)
    return segments


def tcorc(reference: list[RefToken], streams: dict[str, list[HypToken]]) -> dict | None:
    if not reference or not any(streams.values()):
        return None
    result = tcorcwer(reference_segments(reference, "clip"), hypothesis_segments(streams, "clip"), collar=TCORC_COLLAR)["clip"]
    return {"error_rate": result.error_rate, "errors": result.errors, "length": result.length}


# MARK: - Clips


def read_lines(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def score_live_clip(folder: Path, reference: dict, mode: str, simulated: bool) -> dict:
    events = read_lines(folder / "events.jsonl")
    final = read_json(folder / "final.json")
    history, hypotheses = display_history(events, final, simulated)
    streams = stream_tracks(mode)
    per_stream, parts, latencies, criticals = {}, [], [], []
    for stream, tracks in streams.items():
        ref = reference_tokens(reference, tracks)
        hyp = hypotheses.get(stream, [])
        pairs = match_tokens(ref, hyp)
        part, inserted = wer_counts(ref, hyp, reference["lead_in"])
        parts.append(part)
        latencies.append(latency(ref, hyp, pairs))
        criticals.append(critical_words(ref, pairs))
        other_tracks = {track for others in streams.values() if others is not None and others != tracks for track in others}
        per_stream[stream] = {
            "wer": part,
            "crosstalk": crosstalk(hyp, inserted, ref, reference_tokens(reference, other_tracks)) if other_tracks else None,
            "repeats": repeats(hyp, inserted),
            "corrections": corrections(history.get(stream, []), len(hyp)),
            "silence": silence_text(hyp, ref),
            **decodes(events, stream, ref),
        }
    all_reference = reference_tokens(reference, None)
    has_overlap = any(word["overlap"] and word["scored"] for word in reference["words"])
    merged_latency = merge_latency(latencies)
    return {
        "wer": pooled_wer(parts),
        "latency": merged_latency,
        "critical": merge_critical(criticals),
        "streams": per_stream,
        "lag": {
            **lag(events, final, list(streams), simulated, reference["duration"]),
            "first_display_growth": first_display_growth(merged_latency, reference["duration"]),
            "first_display_stopped": first_display_stopped(merged_latency, reference["duration"]),
            "first_display_by_block": first_display_by_block(merged_latency, reference["duration"]),
        },
        "gaps": gaps(events, final),
        "finish": {
            "seconds": final["finish_seconds"],
            "session_ended_early": final["session_ended_early"],
            "incomplete_rows": sum(row["is_incomplete"] for update in final["updates"] for row in update["rows"]),
        },
        "tcorc_wer": tcorc(all_reference, hypotheses) if has_overlap else None,
    }


def score_final_pass_clip(folder: Path, reference: dict) -> dict:
    record = read_json(folder / "final_pass.json")
    hypothesis = keep_stream([HypToken(text, word["start"], word["end"]) for word in record["words"] for text in tokenize(word["text"])])
    ref = reference_tokens(reference, None)
    pairs = match_tokens(ref, hypothesis)
    has_overlap = any(word["overlap"] and word["scored"] for word in reference["words"])
    counts, inserted = wer_counts(ref, hypothesis, reference["lead_in"])
    return {
        "wer": counts,
        "repeats": repeats(hypothesis, inserted),
        "critical": critical_words(ref, pairs),
        "tcorc_wer": tcorc(ref, {"final": hypothesis}) if has_overlap else None,
    }


def merge_latency(parts: list[dict]) -> dict:
    values = [pair for part in parts for pair in part["values"]]
    matched = sum(part["matched"] for part in parts)
    unmatched = sum(part["unmatched"] for part in parts)
    return {
        "matched": matched,
        "unmatched": unmatched,
        "coverage": matched / (matched + unmatched) if matched + unmatched else None,
        "first_display": summarize([first for first, _ in values]),
        "settled": summarize([settled for _, settled in values]),
        "values": values,
        "ends": [end for part in parts for end in part["ends"]],
        "unmatched_words": [word for part in parts for word in part["unmatched_words"]],
        "slowest": sorted((entry for part in parts for entry in part["slowest"]), key=slowness)[:EXAMPLE_COUNT],
    }


def merge_critical(parts: list[dict]) -> dict:
    return {
        "total": sum(part["total"] for part in parts),
        "survived": sum(part["survived"] for part in parts),
        "missing": [word for part in parts for word in part["missing"]],
    }


# MARK: - Resources


def resources(folder: Path, manifest: dict) -> dict | None:
    path = folder / "resources.jsonl"
    baseline = (manifest.get("memory_baseline") or {}).get("median_used_bytes")
    if not path.exists() or baseline is None:
        return None
    samples = read_lines(path)
    during = [sample for sample in samples if sample["phase"].startswith("clip:")]
    longest = current = 0.0
    previous_time = None
    for sample in during:
        hot = sample["thermal_state"] in {"serious", "critical"}
        step = sample["elapsed"] - previous_time if previous_time is not None else 0.0
        current = current + step if hot else 0.0
        longest = max(longest, current)
        previous_time = sample["elapsed"]
    return {
        "load": load_summary(during),
        "baseline_load": load_summary([sample for sample in samples if sample["phase"] == "baseline"]),
        "baseline_used_bytes": baseline,
        "max_added_bytes": max((sample["system_used_bytes"] - baseline for sample in during), default=None),
        "max_process_footprint_bytes": max((sample["process_footprint_bytes"] for sample in during), default=None),
        "longest_serious_thermal_seconds": longest,
        "thermal_states": sorted({sample["thermal_state"] for sample in during}),
        "memory_pressure": sorted({sample["memory_pressure"] for sample in during}),
    }


def load_summary(samples: list[dict]) -> dict:
    """The 1-minute load average (median and p90) and median CPU idle over `samples`."""
    loads = [sample["one_minute_load_average"] for sample in samples if sample.get("one_minute_load_average") is not None]
    idle = [sample["cpu_idle"] for sample in samples if sample.get("cpu_idle") is not None]
    return {
        "median_load_average": float(np.median(loads)) if loads else None,
        "p90_load_average": float(np.percentile(loads, 90)) if loads else None,
        "median_cpu_idle": float(np.median(idle)) if idle else None,
    }


# MARK: - Run


def check_manifest_fixtures(manifest: dict, fixtures: Path, lock: dict) -> None:
    """The run must have used exactly the locked fixtures."""
    problems = []
    if manifest["fixtures"].get("lock_sha256") != sha256(fixtures / LOCK_FILE):
        problems.append(f"the run used a different {LOCK_FILE}")
    for clip, files in manifest["fixtures"]["clips"].items():
        locked = lock["clips"].get(clip, {}).get("files", {})
        for name, digest in files.items():
            if locked.get(name) != digest:
                problems.append(f"{clip}/{name} differs from the locked file")
    if problems:
        raise LockMismatch("the run does not match the fixtures:\n  " + "\n  ".join(problems))


def score_run(run: Path, fixtures: Path) -> dict:
    manifest = read_json(run / "manifest.json")
    clips = manifest["options"]["clips"]
    lock = verify_lock(fixtures, clips)
    check_manifest_fixtures(manifest, fixtures, lock)
    options = manifest["options"]
    simulated = options.get("clock") == "simulated"
    finished = {session["clip"] for session in manifest["sessions"]}
    missing = {clip: lock["clips"][clip]["split"] for clip in clips if clip not in finished}
    scored = {}
    for session in manifest["sessions"]:
        clip = session["clip"]
        reference = read_json(fixtures / clip / "reference.json")
        if manifest["kind"] == "final-pass":
            metrics = score_final_pass_clip(run / clip, reference)
        else:
            metrics = score_live_clip(run / clip, reference, options["mode"], simulated)
        metrics["split"] = lock["clips"][clip]["split"]
        metrics["duration"] = reference["duration"]
        metrics["warm"] = session["warm"]
        scored[clip] = metrics
    return {
        "run": {
            "folder": run.name,
            "kind": manifest["kind"],
            "options": options,
            "model": (manifest.get("model") or {}).get("name"),
            "final_pass_model": options.get("final_pass_model"),
            "lock_sha256": manifest["fixtures"]["lock_sha256"],
            "machine": manifest["machine"],
            "power": manifest["power"],
            "repo": manifest["repo"],
        },
        "clips": scored,
        "missing_clips": missing,
        "resources": resources(run, manifest),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run", type=Path, required=True, help="a live-bench results folder")
    parser.add_argument("--fixtures", type=Path, required=True, help="the fixtures folder the run used")
    args = parser.parse_args(argv)
    try:
        metrics = score_run(args.run, args.fixtures)
    except (LockMismatch, FileNotFoundError, KeyError) as error:
        print(f"score: {error}", file=sys.stderr)
        return 1
    (args.run / "metrics.json").write_text(json.dumps(metrics, indent=1, allow_nan=False, ensure_ascii=False) + "\n", encoding="utf-8")
    for clip, entry in metrics["clips"].items():
        wer = entry["wer"]["wer"]
        print(f"{clip}: WER {'n/a' if wer is None else f'{wer:.1%}'}")
    for clip in metrics["missing_clips"]:
        print(f"{clip}: missing; the run stopped before this clip finished")
    return 0


if __name__ == "__main__":
    sys.exit(main())
