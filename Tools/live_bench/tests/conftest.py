"""Synthetic AMI data and live-bench output for the tests. Nothing here
touches the network or real recordings."""

from __future__ import annotations

import itertools
import json
from pathlib import Path

import numpy as np
import pytest
import soundfile

import ami
import make_fixtures

MEETING = "ES2003a"
# Speaker letter → (headset channel, constant level). The channel order is
# deliberately not alphabetical, so a test notices an assumed map.
SPEAKERS = {"A": (2, 0.3), "B": (0, 0.1), "C": (1, 0.2)}
WORDS = {
    "A": [("Okay", 1.2, 1.5), ("so", 2.1, 2.3), ("twenty", 2.4, 2.7), ("five", 2.7, 3.0), ("Euros", 3.0, 3.4)],
    "B": [("No", 3.6, 3.8), ("I", 4.0, 4.1), ("don't", 4.1, 4.4), ("think", 4.4, 4.7), ("Rose", 5.5, 5.8)],
    "C": [("Mm-hmm", 3.7, 3.9), ("late", 7.0, 7.4)],
}
_ids = itertools.count()


def write_ami(cache: Path, duration: float = 8.0) -> Path:
    """A one-meeting AMI cache in the real layout, with constant-level headsets."""
    resources = cache / "annotations" / "corpusResources"
    resources.mkdir(parents=True)
    speakers = "".join(f'<speaker nxt_agent="{letter}" channel="{channel}" global_name="P{letter}"/>' for letter, (channel, _) in SPEAKERS.items())
    (resources / "meetings.xml").write_text(
        f'<?xml version="1.0"?><nite:root xmlns:nite="http://nite.sourceforge.net/"><meeting observation="{MEETING}">{speakers}</meeting></nite:root>'
    )
    words = cache / "annotations" / "words"
    words.mkdir()
    for letter, entries in WORDS.items():
        body = "".join(f'<w nite:id="w{index}" starttime="{start}" endtime="{end}">{text}</w>' for index, (text, start, end) in enumerate(entries))
        body += '<w nite:id="p" starttime="9.0" endtime="9.0" punc="true">.</w><vocalsound nite:id="v" starttime="1" endtime="2"/>'
        (words / f"{MEETING}.{letter}.words.xml").write_text(f'<nite:root xmlns:nite="http://nite.sourceforge.net/">{body}</nite:root>')
    for _, (channel, level) in SPEAKERS.items():
        path = ami.headset_path(cache, MEETING, channel)
        path.parent.mkdir(parents=True, exist_ok=True)
        soundfile.write(str(path), np.full(int(duration * ami.SAMPLE_RATE), level, dtype=np.float32), ami.SAMPLE_RATE, subtype="PCM_16")
    return cache


def clip_entry(**overrides) -> dict:
    entry = {
        "id": "smoke", "split": "smoke", "meeting": MEETING, "start": 2.0, "duration": 5.5, "lead_in": 1.0,
        "mic_speaker": "A", "covers": ["test"], "names": ["Rose"], "vocabulary": ["Rose"],
    }
    entry.update(overrides)
    return entry


def write_clip_list(path: Path, clips: list[dict], seed: int = 7) -> Path:
    path.write_text(json.dumps({"seed": seed, "clips": clips}))
    return path


@pytest.fixture
def fixtures(tmp_path: Path) -> Path:
    """Fixtures for one clip cut from the synthetic meeting."""
    cache = write_ami(tmp_path / "ami")
    out = tmp_path / "fixtures"
    make_fixtures.make_fixtures(cache, write_clip_list(tmp_path / "clips.json", [clip_entry()]), out)
    return out


def row(text: str, start: float, end: float, *, tail: str = "", track: str = "mic", row_id: str | None = None, incomplete: bool = False) -> dict:
    return {
        "id": row_id or f"row-{next(_ids)}", "track": track, "start_time": start, "end_time": end,
        "settled_text": text, "tail_text": tail, "is_closed": False, "is_forced_boundary": False, "is_incomplete": incomplete,
    }


def update(track: str, rows: list[dict], through: float, *, revision: int = 0, decode_ms: float | None = None, gaps: list | None = None) -> dict:
    return {
        "session_id": "s", "generation": 1, "track": track, "revision": revision, "rows": rows, "gaps": gaps or [],
        "transcribed_through": through, "settled_through": through, "decode_milliseconds": decode_ms,
    }


def event(time: float, track: str, rows: list[dict], through: float, *, decode_ms: float | None = 100.0) -> dict:
    return {"t_release": time, "t_event": time, "update": update(track, rows, through, decode_ms=decode_ms)}


def final_record(time: float, updates: list[dict] | None = None) -> dict:
    return {"t_release": time, "t_event": time, "finish_seconds": 0.1, "session_ended_early": False, "updates": updates or []}
