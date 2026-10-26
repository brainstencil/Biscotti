"""The AMI Meeting Corpus as the harness uses it: official URLs, the cache
layout, known defective recordings, and the annotation files.

Cache layout (made by fetch_ami.py):

    <cache>/annotations/...                      ami_public_manual_1.6.2.zip, extracted
    <cache>/audio/<meeting>/<meeting>.Headset-<channel>.wav
    <cache>/hashes.json                          SHA-256, size and URL of every download
    <cache>/ATTRIBUTION.txt
"""

from __future__ import annotations

import xml.etree.ElementTree as ElementTree
from dataclasses import dataclass
from pathlib import Path

ANNOTATIONS_VERSION = "1.6.2"
ANNOTATIONS_URL = f"https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_{ANNOTATIONS_VERSION}.zip"
AUDIO_URL = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{meeting}/audio/{meeting}.Headset-{channel}.wav"
SAMPLE_RATE = 16000

ATTRIBUTION = """\
AMI Meeting Corpus
Source: https://groups.inf.ed.ac.uk/ami/corpus/
Licence: Creative Commons Attribution 4.0 International (CC BY 4.0),
https://creativecommons.org/licenses/by/4.0/
Annotations: AMI manual annotations release {version}.

Citation: Jean Carletta et al., "The AMI Meeting Corpus: A Pre-announcement",
Machine Learning for Multimodal Interaction (MLMI 2005), LNCS 3869, Springer, 2006.

The files in this cache were downloaded unchanged from the official mirror.
Fixtures cut from them (cropped headset tracks, summed tracks and word lists)
are adaptations and carry the same attribution.
""".format(version=ANNOTATIONS_VERSION)

# Recordings whose headset audio or channel map is unusable for this test,
# from the corpus's own data-problems list
# (https://groups.inf.ed.ac.uk/ami/corpus/dataproblems.shtml). Dropouts were
# zero-padded, which would read as silence the speakers never had.
EXCLUDED_MEETINGS = {
    **{meeting: "participant 1 did not wear the headset properly" for meeting in ("ES2002a", "ES2002b", "ES2002c")},
    "ES2004d": "audio dropouts, zero-padded",
    "ES2005a": "start of the meeting not recorded",
    "ES2006d": "channels zero-padded to equal length",
    "ES2008c": "audio dropout, zero-padded",
    "ES2010d": "audio dropouts, zero-padded",
    **{f"ES2012{part}": "audio quality very weak" for part in "abcd"},
    "ES2016a": "audio dropout, zero-padded",
    "EN2001a": "audio dropout, zero-padded",
    "EN2005a": "audio dropout, zero-padded",
    "EN2006b": "audio dropouts, zero-padded",
    "IB4002": "wrong audio channel mapping in the corpus metadata",
    "IN1014": "recording stops before the end of the meeting",
    "IS1000a": "two participants removed their microphones",
    "IS1000c": "audio dropout",
    **{f"IS1002{part}": "incomplete trial (IS1002a dropout)" for part in "abcd"},
    **{f"IS1005{part}": "incomplete trial (IS1005d dropout)" for part in "abcd"},
    "TS3011d": "beginning missing after a dropout",
    "TS3012c": "end missing after a dropout",
}


@dataclass(frozen=True)
class Word:
    text: str
    speaker: str
    start: float
    end: float


PRODUCTION_PATHS = (Path.home() / "Library" / "Application Support" / "Biscotti", Path("/Applications/Biscotti.app"))
# Path.resolve leaves firmlinks alone, so the same folders reached through
# the system Data volume (/System/Volumes/Data) are refused as well.
DATA_VOLUME = Path("/System/Volumes/Data")


def refuse_production_path(path: Path, protected: tuple[Path, ...] = PRODUCTION_PATHS) -> Path:
    """`path` resolved, or ValueError when it is production Biscotti's data or app."""
    resolved = path.expanduser().resolve()
    roots = [form for root in protected for form in (root, root.resolve())]
    roots += [DATA_VOLUME / root.relative_to("/") for root in roots]
    for root in roots:
        root_parts = [part.lower() for part in root.parts]
        if [part.lower() for part in resolved.parts[: len(root_parts)]] == root_parts:
            raise ValueError(f"{resolved} is inside production Biscotti ({root}); use a folder outside it")
    return resolved


def annotations_root(cache: Path) -> Path:
    """The folder holding corpusResources/ and words/, wherever the zip put it."""
    matches = sorted((cache / "annotations").glob("**/corpusResources/meetings.xml"))
    if not matches:
        raise FileNotFoundError(f"no corpusResources/meetings.xml under {cache / 'annotations'}; run fetch_ami.py first")
    return matches[0].parent.parent


def channel_map(cache: Path, meeting: str) -> dict[str, int]:
    """Speaker letter (nxt_agent) to headset channel, from the corpus metadata."""
    tree = ElementTree.parse(annotations_root(cache) / "corpusResources" / "meetings.xml")
    for element in tree.iter():
        if _local(element.tag) == "meeting" and element.get("observation") == meeting:
            return {
                speaker.get("nxt_agent"): int(speaker.get("channel"))
                for speaker in element
                if _local(speaker.tag) == "speaker" and speaker.get("nxt_agent") and speaker.get("channel") is not None
            }
    raise KeyError(f"meeting {meeting} is not in corpusResources/meetings.xml")


def _timed_words(cache: Path, meeting: str, speaker: str) -> list[tuple[ElementTree.Element, float, float]]:
    """Every timed `<w>` of a speaker except punctuation."""
    path = annotations_root(cache) / "words" / f"{meeting}.{speaker}.words.xml"
    return [
        (element, float(element.get("starttime")), float(element.get("endtime")))
        for element in ElementTree.parse(path).getroot()
        if _local(element.tag) == "w" and "starttime" in element.attrib and "endtime" in element.attrib and element.get("punc") != "true"
    ]


def words(cache: Path, meeting: str, speaker: str) -> list[Word]:
    """A speaker's timed words for the reference. Truncated words are left out."""
    return [
        Word(text, speaker, start, end)
        for element, start, end in _timed_words(cache, meeting, speaker)
        if element.get("trunc") != "true" and (text := (element.text or "").strip())
    ]


def speech(cache: Path, meeting: str, speaker: str) -> list[tuple[float, float]]:
    """When a speaker talks, by their annotated words, truncated ones included."""
    return [(start, end) for _, start, end in _timed_words(cache, meeting, speaker)]


def headset_path(cache: Path, meeting: str, channel: int) -> Path:
    return cache / "audio" / meeting / f"{meeting}.Headset-{channel}.wav"


def series(meeting: str) -> str:
    """The session series a meeting belongs to: ES2002a → ES2002 (same participants)."""
    return meeting[:-1] if meeting[-1:].isalpha() else meeting


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]
