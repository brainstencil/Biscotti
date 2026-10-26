import io
import json
import zipfile

import pytest

import ami
import fetch_ami
from fetch_ami import CacheCapExceeded


class FakeResponse:
    def __init__(self, body: bytes, announce: bool = True):
        self.headers = {"Content-Length": str(len(body))} if announce else {}
        self._body = io.BytesIO(body)

    def read(self, size: int = -1) -> bytes:
        return self._body.read(size)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


def opener_for(files: dict[str, bytes], announce: bool = True):
    requested = []

    def opener(url):
        requested.append(url)
        return FakeResponse(files[url], announce)

    opener.requested = requested
    return opener


def test_cache_cap_is_enforced(tmp_path):
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / "existing.bin").write_bytes(b"x" * 600)
    url = "https://groups.inf.ed.ac.uk/ami/file.wav"

    with pytest.raises(CacheCapExceeded, match="1000 bytes"):
        fetch_ami.download(url, cache / "audio" / "file.wav", cache, opener_for({url: b"y" * 500}), cap=1000)
    assert not (cache / "audio" / "file.wav").exists() and not list(cache.rglob("*.part"))

    with pytest.raises(CacheCapExceeded, match="while downloading"):
        fetch_ami.download(url, cache / "audio" / "file.wav", cache, opener_for({url: b"y" * 500}, announce=False), cap=1000)
    assert not (cache / "audio" / "file.wav").exists() and not list(cache.rglob("*.part"))

    opener = opener_for({url: b"y" * 300})
    assert fetch_ami.download(url, cache / "audio" / "file.wav", cache, opener, cap=1000)
    entry = json.loads((cache / "hashes.json").read_text())["audio/file.wav"]
    assert entry["bytes"] == 300 and entry["url"] == url and len(entry["sha256"]) == 64
    assert not fetch_ami.download(url, cache / "audio" / "file.wav", cache, opener, cap=1000), "a file with its recorded hash is not fetched again"


def test_fetch_uses_official_urls_and_the_channel_map(tmp_path):
    archive = io.BytesIO()
    with zipfile.ZipFile(archive, "w") as bundle:
        bundle.writestr(
            "corpusResources/meetings.xml",
            '<root><meeting observation="ES2003a"><speaker nxt_agent="A" channel="3"/><speaker nxt_agent="B" channel="1"/></meeting></root>',
        )
    files = {
        ami.ANNOTATIONS_URL: archive.getvalue(),
        ami.AUDIO_URL.format(meeting="ES2003a", channel=1): b"one",
        ami.AUDIO_URL.format(meeting="ES2003a", channel=3): b"three",
    }
    opener = opener_for(files)

    fetched = fetch_ami.fetch(tmp_path / "cache", ["ES2003a"], opener=opener)

    assert opener.requested == [ami.ANNOTATIONS_URL, ami.AUDIO_URL.format(meeting="ES2003a", channel=1), ami.AUDIO_URL.format(meeting="ES2003a", channel=3)]
    assert all(url.startswith("https://groups.inf.ed.ac.uk/ami/") for url in opener.requested)
    assert ami.headset_path(tmp_path / "cache", "ES2003a", 3).read_bytes() == b"three"
    assert len(fetched) == 3
    assert "CC BY 4.0" in (tmp_path / "cache" / "ATTRIBUTION.txt").read_text()
    with pytest.raises(ValueError, match="known defective"):
        fetch_ami.fetch(tmp_path / "cache", ["IB4002"], opener=opener)


def test_production_folders_are_refused(tmp_path):
    home = tmp_path / "home"
    protected = (home / "Library" / "Application Support" / "Biscotti", tmp_path / "Biscotti.app")

    with pytest.raises(ValueError, match="production Biscotti"):
        ami.refuse_production_path(home / "Library" / "Application Support" / "biscotti" / "fixtures", protected)
    with pytest.raises(ValueError, match="production Biscotti"):
        ami.refuse_production_path(ami.DATA_VOLUME / protected[1].resolve().relative_to("/") / "Contents", protected)
    assert ami.refuse_production_path(tmp_path / "data", protected) == (tmp_path / "data").resolve()
