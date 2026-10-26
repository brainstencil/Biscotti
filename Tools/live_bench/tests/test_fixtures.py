import json

import numpy as np
import pytest
import soundfile
from conftest import MEETING, clip_entry, write_ami, write_clip_list

import make_fixtures
from make_fixtures import FixtureError, LockMismatch
from normalize import critical_category, drop_number_and, normalize, tokenize

# Every synthetic headset is one constant level, so scaling its speech to
# the target level makes it exactly that level.
LEVEL = 10 ** (make_fixtures.SPEECH_LEVEL_DBFS / 20)


def test_normalization_spells_numbers_and_drops_fillers():
    assert normalize("Um, we need 25 units—two hundred and fifty, OK?") == [
        "we", "need", "twenty", "five", "units", "two", "hundred", "fifty", "okay",
    ]
    assert normalize("Mm-hmm. Uh-huh") == []
    assert normalize("It's 3.5% of €1,200 on the 21st") == [
        "it's", "three", "point", "five", "percent", "of", "one", "thousand", "two", "hundred", "euros",
        "on", "the", "twenty", "first",
    ]
    assert normalize("The colour, well-known") == ["the", "color", "well", "known"]
    assert normalize("one and two") == ["one", "and", "two"]
    assert critical_category("25") == "number"
    assert critical_category("one") is None, "mostly a pronoun in meetings"
    assert critical_category("Twenty") == "number"
    assert critical_category("don't") == "negation"
    assert critical_category("Never") == "negation"
    assert critical_category("second") is None
    assert critical_category("remote") is None


def test_ami_letter_spellings_read_as_whisper_writes_them():
    assert normalize("the L_C_D_ and two T_V_s, the T_V_'s remote, anti-R_S_I_ E_") == [
        "the", "lcd", "and", "two", "tvs", "the", "tv's", "remote", "anti", "rsi", "e",
    ]
    assert normalize("the LCD and two TVs, the TV's remote, anti-RSI E") == normalize("the L.C.D. and two T.V.s, the TV's remote, anti-RSI E.")
    assert normalize("snake_case") == ["snake", "case"], "only letters each followed by an underscore are joined"


def test_number_and_is_dropped_over_the_stream_not_per_word():
    words = ["a", "hundred", "and", "fifty", "euros"]
    per_word = [token for word in words for token in tokenize(word)]

    assert per_word == ["a", "hundred", "and", "fifty", "euros"], "a word alone cannot tell"
    assert drop_number_and(per_word) == normalize(" a hundred and fifty euros") == ["a", "hundred", "fifty", "euros"]
    assert drop_number_and(tokenize("250 euros")) == ["two", "hundred", "fifty", "euros"]


def test_gate_opens_around_speech_with_fades():
    samples = np.ones(16000, dtype=np.float32)

    gated = make_fixtures.gate(samples, [(1.5, 1.6)], crop_start=1.0)

    def at(seconds: float) -> float:
        return float(gated[int(seconds * 16000)])

    assert at(0.1) == 0 and at(0.99) == 0
    assert 0 < at(0.175) < 1 and 0 < at(0.925) < 1, "fades just outside the padding"
    assert at(0.2) == 1 and at(0.5) == 1 and at(0.89) == 1, "open from 0.3 s before the word to 0.3 s after"


def test_loud_samples_are_clipped_and_counted():
    clipped, count = make_fixtures.limit(np.array([0.5, 1.5, -2.0, -0.2], dtype=np.float32))

    assert count == 2
    assert clipped.tolist() == [0.5, 1.0, -1.0, pytest.approx(-0.2)]


def test_make_fixtures_uses_the_corpus_channel_map(fixtures):
    folder = fixtures / "smoke"
    mic, rate = soundfile.read(str(folder / "mic.wav"), dtype="float32")
    system, _ = soundfile.read(str(folder / "system.wav"), dtype="float32")
    mixed, _ = soundfile.read(str(folder / "mixed.wav"), dtype="float32")

    def at(samples, seconds: float) -> float:
        return float(samples[int(seconds * 16000)])

    assert rate == 16000
    assert len(mic) == len(system) == len(mixed) == int(6.5 * 16000)
    assert np.allclose(mic, LEVEL, atol=1e-3), "A is on headset 2 in meetings.xml, and is not gated"
    # Clip time is meeting time minus 1 s. B speaks 2.6-3.7 and 4.5-4.8, C 2.7-2.9 and 6.0-6.4.
    assert at(system, 1.0) == pytest.approx(0, abs=1e-3), "only A speaks; A's crosstalk on B and C is gated out"
    assert at(system, 2.8) == pytest.approx(2 * LEVEL, abs=1e-3), "B and C each at the speech level"
    assert at(system, 3.5) == pytest.approx(LEVEL, abs=1e-3)
    assert at(system, 5.4) == pytest.approx(0, abs=1e-3)
    assert at(system, 6.2) == pytest.approx(LEVEL, abs=1e-3)
    assert np.allclose(mixed, mic + system, atol=2e-3)

    reference = json.loads((folder / "reference.json").read_text())
    words = {word["text"]: word for word in reference["words"]}
    assert reference["lead_in"] == 1.0 and reference["mic_speaker"] == "A"
    assert words["Okay"]["start"] == pytest.approx(0.2) and not words["Okay"]["scored"]
    assert words["so"]["track"] == "mic" and words["so"]["scored"]
    assert words["don't"]["track"] == "system" and words["don't"]["critical"] == "negation"
    assert words["twenty"]["critical"] == "number"
    assert words["Rose"]["critical"] == "name"
    assert words["No"]["overlap"] and words["Mm-hmm"]["overlap"] and not words["so"]["overlap"]
    assert "." not in words

    meta = json.loads((folder / "meta.json").read_text())
    assert meta["channel_map"] == {"A": 2, "B": 0, "C": 1}
    assert meta["vocabulary"] == ["Rose"]
    lock = json.loads((fixtures / make_fixtures.LOCK_FILE).read_text())
    assert lock["annotations_version"] == "1.6.2"
    assert lock["seed"] == 7 and lock["speech_level_dbfs"] == make_fixtures.SPEECH_LEVEL_DBFS
    gains = lock["clips"]["smoke"]["gains_db"]
    assert gains == {speaker: pytest.approx(make_fixtures.SPEECH_LEVEL_DBFS - 20 * np.log10(level), abs=0.01) for speaker, level in (("A", 0.3), ("B", 0.1), ("C", 0.2))}
    assert lock["system_gating"]["padding_seconds"] == make_fixtures.GATE_PADDING_SECONDS
    assert lock["system_gating"]["fade_seconds"] == make_fixtures.GATE_FADE_SECONDS
    assert lock["clips"]["smoke"]["clipped_samples"] == {"mic.wav": 0, "system.wav": 0, "mixed.wav": 0}
    assert lock["clips"]["smoke"]["split"] == "smoke"
    assert set(lock["clips"]["smoke"]["files"]) == set(make_fixtures.CLIP_FILES)


def test_make_fixtures_refuses_defective_meetings_and_an_existing_lock(tmp_path, fixtures):
    cache = write_ami(tmp_path / "other-ami")
    defective = write_clip_list(tmp_path / "defective.json", [clip_entry(meeting="IB4002")])
    with pytest.raises(FixtureError, match="IB4002.*channel mapping"):
        make_fixtures.make_fixtures(cache, defective, tmp_path / "new")

    leaking = write_clip_list(tmp_path / "leaking.json", [
        clip_entry(id="cal", split="calibration"),
        clip_entry(id="val", split="validation", meeting=MEETING[:-1] + "b"),
    ])
    with pytest.raises(FixtureError, match="other sessions"):
        make_fixtures.make_fixtures(cache, leaking, tmp_path / "new")

    again = write_clip_list(tmp_path / "again.json", [clip_entry()])
    with pytest.raises(FixtureError, match="frozen"):
        make_fixtures.make_fixtures(cache, again, fixtures)


def test_fixture_lock_rejects_hash_mismatch(fixtures):
    assert make_fixtures.verify_lock(fixtures)["clips"]["smoke"]

    mic = fixtures / "smoke" / "mic.wav"
    data = bytearray(mic.read_bytes())
    data[-1] ^= 0xFF
    mic.write_bytes(bytes(data))
    (fixtures / "smoke" / "reference.json").unlink()

    with pytest.raises(LockMismatch) as error:
        make_fixtures.verify_lock(fixtures)
    assert "smoke/mic.wav: hash differs" in str(error.value)
    assert "smoke/reference.json: missing" in str(error.value)
    with pytest.raises(LockMismatch, match="not in"):
        make_fixtures.verify_lock(fixtures, ["unknown"])


def test_mic_speaker_comes_from_the_seed_when_not_named(tmp_path):
    cache = write_ami(tmp_path / "ami")
    clips = write_clip_list(tmp_path / "clips.json", [clip_entry(mic_speaker=None)], seed=3)

    first = make_fixtures.make_fixtures(cache, clips, tmp_path / "one")["clips"]["smoke"]["mic_speaker"]
    second = make_fixtures.make_fixtures(cache, clips, tmp_path / "two")["clips"]["smoke"]["mic_speaker"]

    assert first == second and first in {"A", "B", "C"}
