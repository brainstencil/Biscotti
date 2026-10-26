"""Cut the frozen clip list into replay fixtures.

    uv run python make_fixtures.py --ami CACHE --clips clips.json --out FIXTURES
    uv run python make_fixtures.py --verify FIXTURES

The clip list (clips.json) is written by hand from the annotations, before
any option is compared, and never by which option handles a clip best:

    {"seed": 20261023,
     "clips": [{"id": "smoke", "split": "smoke", "meeting": "ES2003a",
                "start": 312.0, "duration": 90, "lead_in": 5,
                "mic_speaker": "B", "covers": ["fast turn-taking"],
                "names": ["Rose"], "vocabulary": ["Rose"]}]}

`split` is smoke, calibration, validation or soak. `start` and `duration`
are the scored part in meeting seconds; the audio starts `lead_in` seconds
earlier. `mic_speaker` is the speaker letter heard as "You"; when left out,
the seed picks one. `names` join numbers and negations in the critical-word
list; `vocabulary` is what non-gated runs pass as custom vocabulary.

Per clip, <out>/<id>/ gets mic.wav (that speaker's headset), system.wav (the
other headsets, each gated to its own speaker's annotated speech, summed),
mixed.wav (both), reference.json and meta.json, all 16 kHz mono. Each
headset is scaled so that its speaker's annotated speech, over the whole
meeting, has an RMS level of SPEECH_LEVEL_DBFS; samples that then pass full
scale are clipped and counted. <out>/fixtures.lock.json freezes them:
hashes, annotation version, channel map, gains, gating, clipped samples, seed
and split. An existing lock is never rewritten.

Levels differ from the component spec's "fixed gain and headroom". AMI's
headsets were recorded quietly and unevenly: their speech averages -44 to
-29 dBFS, and one meeting's -22 to -14 dBFS. Through a fixed gain, much
of the quiet speech sits under the Whisper session's -45 dBFS silence test,
which assumes the level of a real microphone or call, and is skipped
unheard. -26 dBFS is the usual active speech level for telephony and VoIP
audio (ITU-T P.56 measurement, -26 dBov), the level a call's system audio
and a microphone with automatic gain deliver.

Gating differs from the component spec, which sums the other headsets as
they are. Every headset carries crosstalk from the people around it, so an
ungated sum would put the "You" speaker's voice into "Others", which a real
call never does, and two-track mode would be scored on words nobody said on
that track. mic.wav stays the raw headset: some of the others bleeding into
your own microphone is realistic.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import soundfile

import ami
from normalize import critical_category, normalize

LOCK_FILE = "fixtures.lock.json"
CLIP_FILES = ("mic.wav", "system.wav", "mixed.wav", "reference.json", "meta.json")
SPLITS = ("smoke", "calibration", "validation", "soak")
# Each speaker's speech level after scaling. Loud stretches that clip are
# counted rather than refused, which a 45-minute soak could not avoid.
SPEECH_LEVEL_DBFS = -26.0
# Gating keeps each other headset open this long around its speaker's words,
# with linear fades beyond, so word edges survive the annotation's timing.
GATE_PADDING_SECONDS = 0.3
GATE_FADE_SECONDS = 0.05


class FixtureError(RuntimeError):
    pass


class LockMismatch(RuntimeError):
    pass


@dataclass(frozen=True)
class Clip:
    id: str
    split: str
    meeting: str
    start: float
    duration: float
    lead_in: float
    mic_speaker: str | None = None
    covers: list[str] = field(default_factory=list)
    names: list[str] = field(default_factory=list)
    vocabulary: list[str] = field(default_factory=list)

    @property
    def crop_start(self) -> float:
        return self.start - self.lead_in

    @property
    def crop_end(self) -> float:
        return self.start + self.duration


def write_json(path: Path, value: dict, sort_keys: bool = False) -> None:
    path.write_text(json.dumps(value, indent=1, sort_keys=sort_keys, ensure_ascii=False) + "\n", encoding="utf-8")


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_clip_list(path: Path) -> tuple[int, list[Clip]]:
    data = read_json(path)
    clips = [Clip(**entry) for entry in data["clips"]]
    check_clip_list(clips)
    return int(data.get("seed", 0)), clips


def check_clip_list(clips: list[Clip]) -> None:
    ids = [clip.id for clip in clips]
    if len(set(ids)) != len(ids):
        raise FixtureError("clip IDs must be unique")
    for clip in clips:
        if not clip.id or "/" in clip.id or clip.id in {".", ".."}:
            raise FixtureError(f"clip ID {clip.id!r} must be a plain folder name")
        if clip.split not in SPLITS:
            raise FixtureError(f"{clip.id}: split must be one of {', '.join(SPLITS)}")
        if clip.meeting in ami.EXCLUDED_MEETINGS:
            raise FixtureError(f"{clip.id}: {clip.meeting} is a known defective recording ({ami.EXCLUDED_MEETINGS[clip.meeting]})")
        if clip.duration <= 0 or clip.lead_in < 0 or clip.crop_start < 0:
            raise FixtureError(f"{clip.id}: needs duration > 0 and 0 <= lead_in <= start")
    calibration = {ami.series(clip.meeting) for clip in clips if clip.split == "calibration"}
    shared = sorted(ami.series(clip.meeting) for clip in clips if clip.split == "validation" and ami.series(clip.meeting) in calibration)
    if shared:
        raise FixtureError(f"validation clips must come from other sessions than calibration clips; shared: {', '.join(shared)}")


def choose_mic_speaker(clip: Clip, speakers: list[str], seed: int) -> str:
    if clip.mic_speaker is not None:
        if clip.mic_speaker not in speakers:
            raise FixtureError(f"{clip.id}: speaker {clip.mic_speaker} is not in {clip.meeting} ({', '.join(speakers)})")
        return clip.mic_speaker
    return random.Random(f"{seed}:{clip.id}").choice(sorted(speakers))


def read_crop(path: Path, clip: Clip) -> np.ndarray:
    info = soundfile.info(str(path))
    if info.samplerate != ami.SAMPLE_RATE or info.channels != 1:
        raise FixtureError(f"{path} is {info.samplerate} Hz with {info.channels} channels; expected 16 kHz mono")
    first = round(clip.crop_start * ami.SAMPLE_RATE)
    last = round(clip.crop_end * ami.SAMPLE_RATE)
    if last > info.frames:
        raise FixtureError(f"{clip.id}: ends at {clip.crop_end:.1f} s, after the end of {path.name}")
    samples, _ = soundfile.read(str(path), start=first, stop=last, dtype="float32")
    return samples


def gate(samples: np.ndarray, speech: list[tuple[float, float]], crop_start: float) -> np.ndarray:
    """`samples` open only around `speech` (meeting seconds), with padding and fades."""
    count = len(samples)
    envelope = np.zeros(count, dtype=np.float32)
    fade = max(1, round(GATE_FADE_SECONDS * ami.SAMPLE_RATE))
    rise = np.linspace(0, 1, fade + 2, dtype=np.float32)[1:-1]

    def raise_to(first: int, values: np.ndarray) -> None:
        low, high = max(first, 0), min(first + len(values), count)
        if low < high:
            envelope[low:high] = np.maximum(envelope[low:high], values[low - first : high - first])

    for start, end in speech:
        first = round((start - GATE_PADDING_SECONDS - crop_start) * ami.SAMPLE_RATE)
        last = round((end + GATE_PADDING_SECONDS - crop_start) * ami.SAMPLE_RATE)
        raise_to(first - fade, rise)
        raise_to(first, np.ones(max(last - first, 0), dtype=np.float32))
        raise_to(last, rise[::-1])
    return samples * envelope


def limit(samples: np.ndarray) -> tuple[np.ndarray, int]:
    """The samples clipped to full scale, and how many needed it."""
    clipped = int(np.count_nonzero(np.abs(samples) > 1))
    return np.clip(samples, -1, 1), clipped


def reference_words(cache: Path, clip: Clip, speakers: list[str], mic_speaker: str) -> list[dict]:
    """Words inside the crop, in clip time, with their track and flags."""
    names = {token for name in clip.names for token in normalize(name)}
    words = [
        word
        for speaker in speakers
        for word in ami.words(cache, clip.meeting, speaker)
        if word.start >= clip.crop_start and word.end <= clip.crop_end
    ]
    words.sort(key=lambda word: (word.start, word.end))
    overlaps = [False] * len(words)
    for index, word in enumerate(words):
        later = index + 1
        while later < len(words) and words[later].start < word.end:
            if words[later].speaker != word.speaker:
                overlaps[index] = overlaps[later] = True
            later += 1
    result = []
    for word, overlap in zip(words, overlaps):
        tokens = normalize(word.text)
        category = critical_category(word.text) or ("name" if tokens and all(token in names for token in tokens) else None)
        result.append({
            "text": word.text,
            "speaker": word.speaker,
            "track": "mic" if word.speaker == mic_speaker else "system",
            "start": round(word.start - clip.crop_start, 3),
            "end": round(word.end - clip.crop_start, 3),
            "scored": word.start >= clip.start,
            "overlap": overlap,
            "critical": category,
        })
    return result


def speech_gain_db(cache: Path, meeting: str, speaker: str, channel: int) -> float:
    """The gain that brings a speaker's annotated speech, over their whole
    headset recording, to SPEECH_LEVEL_DBFS."""
    samples, rate = soundfile.read(str(ami.headset_path(cache, meeting, channel)), dtype="float32")
    speaking = np.zeros(len(samples), dtype=bool)
    for start, end in ami.speech(cache, meeting, speaker):
        speaking[round(start * rate) : round(end * rate)] = True
    if not speaking.any():
        raise FixtureError(f"{meeting}: speaker {speaker} has no annotated speech to measure")
    level = 10 * np.log10(np.mean(np.square(samples[speaking], dtype=np.float64)) + 1e-20)
    return round(SPEECH_LEVEL_DBFS - level, 2)


def make_clip(cache: Path, clip: Clip, seed: int, out: Path) -> dict:
    """Writes one clip's files and returns its lock entry."""
    channels = ami.channel_map(cache, clip.meeting)
    speakers = sorted(channels)
    mic_speaker = choose_mic_speaker(clip, speakers, seed)
    gains_db = {speaker: speech_gain_db(cache, clip.meeting, speaker, channels[speaker]) for speaker in speakers}
    tracks = {
        speaker: 10 ** (gains_db[speaker] / 20) * read_crop(ami.headset_path(cache, clip.meeting, channels[speaker]), clip)
        for speaker in speakers
    }
    mic = tracks[mic_speaker]
    others = [speaker for speaker in speakers if speaker != mic_speaker]
    system = sum((gate(tracks[speaker], ami.speech(cache, clip.meeting, speaker), clip.crop_start) for speaker in others), np.zeros_like(mic))
    mixed = mic + system

    folder = out / clip.id
    folder.mkdir(parents=True, exist_ok=False)
    clipped_samples = {}
    for name, samples in (("mic.wav", mic), ("system.wav", system), ("mixed.wav", mixed)):
        written, clipped_samples[name] = limit(samples)
        soundfile.write(str(folder / name), written, ami.SAMPLE_RATE, subtype="PCM_16")
    reference = {
        "clip": clip.id,
        "lead_in": clip.lead_in,
        "duration": clip.lead_in + clip.duration,
        "mic_speaker": mic_speaker,
        "words": reference_words(cache, clip, speakers, mic_speaker),
    }
    write_json(folder / "reference.json", reference)
    meta = {
        "id": clip.id,
        "split": clip.split,
        "meeting": clip.meeting,
        "crop_start": clip.crop_start,
        "start": clip.start,
        "duration": clip.duration,
        "lead_in": clip.lead_in,
        "mic_speaker": mic_speaker,
        "channel_map": channels,
        "covers": clip.covers,
        "names": clip.names,
        "vocabulary": clip.vocabulary,
    }
    write_json(folder / "meta.json", meta)
    return {
        "split": clip.split,
        "meeting": clip.meeting,
        "mic_speaker": mic_speaker,
        "channel_map": channels,
        "gains_db": gains_db,
        "clipped_samples": clipped_samples,
        "files": {name: sha256(folder / name) for name in CLIP_FILES},
    }


def make_fixtures(cache: Path, clip_list: Path, out: Path) -> dict:
    out = ami.refuse_production_path(out)
    lock_path = out / LOCK_FILE
    if lock_path.exists():
        raise FixtureError(f"{lock_path} exists; fixtures are frozen. Use a new folder to make another set.")
    seed, clips = load_clip_list(clip_list)
    out.mkdir(parents=True, exist_ok=True)
    source_hashes = read_json(cache / "hashes.json") if (cache / "hashes.json").exists() else {}
    lock = {
        "annotations_version": ami.ANNOTATIONS_VERSION,
        "seed": seed,
        "speech_level_dbfs": SPEECH_LEVEL_DBFS,
        "system_gating": {
            "speech": "each other speaker's annotated words, truncated words included",
            "padding_seconds": GATE_PADDING_SECONDS,
            "fade_seconds": GATE_FADE_SECONDS,
        },
        "clip_list_sha256": sha256(clip_list),
        "sources": {path: entry["sha256"] for path, entry in sorted(source_hashes.items())},
        "clips": {clip.id: make_clip(cache, clip, seed, out) for clip in clips},
    }
    write_json(lock_path, lock, sort_keys=True)
    return lock


def verify_lock(fixtures: Path, clips: list[str] | None = None) -> dict:
    """The lock, after checking every listed clip file against it.

    Raises LockMismatch naming each missing or changed file.
    """
    lock = read_json(fixtures / LOCK_FILE)
    problems = []
    for clip_id in clips if clips is not None else sorted(lock["clips"]):
        entry = lock["clips"].get(clip_id)
        if entry is None:
            problems.append(f"{clip_id}: not in {LOCK_FILE}")
            continue
        for name, expected in entry["files"].items():
            path = fixtures / clip_id / name
            if not path.exists():
                problems.append(f"{clip_id}/{name}: missing")
            elif sha256(path) != expected:
                problems.append(f"{clip_id}/{name}: hash differs from {LOCK_FILE}")
    if problems:
        raise LockMismatch("fixtures do not match their lock:\n  " + "\n  ".join(problems))
    return lock


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ami", type=Path, help="cache folder from fetch_ami.py")
    parser.add_argument("--clips", type=Path, help="the clip list (clips.json)")
    parser.add_argument("--out", type=Path, help="new fixtures folder")
    parser.add_argument("--verify", type=Path, metavar="FIXTURES", help="check a fixtures folder against its lock")
    args = parser.parse_args(argv)
    try:
        if args.verify:
            lock = verify_lock(args.verify)
            print(f"{len(lock['clips'])} clips match {LOCK_FILE}")
        elif args.ami and args.clips and args.out:
            lock = make_fixtures(args.ami, args.clips, args.out)
            print(f"wrote {len(lock['clips'])} clips and {args.out / LOCK_FILE}")
        else:
            parser.error("give --ami, --clips and --out, or --verify")
    except (FixtureError, LockMismatch, ValueError, KeyError, FileNotFoundError) as error:
        print(f"make_fixtures: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
