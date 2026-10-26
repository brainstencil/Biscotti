"""Download the AMI manual annotations and chosen headset tracks.

Run from Tools/live_bench, with the cache in a folder of your choice:

    uv run python fetch_ami.py --cache DIR                       # annotations only
    uv run python fetch_ami.py --cache DIR --meetings ES2003a,IS1009b

Files come only from the official AMI mirror. Each download is recorded in
<cache>/hashes.json (URL, size, SHA-256), the licence and attribution go to
<cache>/ATTRIBUTION.txt, and files already present with a matching hash are
skipped. The cache never grows past 2 GB: a download that would cross the
cap is refused before anything is written, and stopped if the server sends
more than it announced.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import urllib.request
import zipfile
from collections.abc import Callable
from pathlib import Path
from typing import BinaryIO

import ami

CACHE_CAP_BYTES = 2 * 1024**3
CHUNK_BYTES = 1 << 20
HASHES_FILE = "hashes.json"

Opener = Callable[[str], BinaryIO]


class CacheCapExceeded(RuntimeError):
    pass


def cache_size(cache: Path) -> int:
    """Bytes the cache holds now, partial downloads included."""
    return sum(path.stat().st_size for path in cache.rglob("*") if path.is_file())


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while block := file.read(CHUNK_BYTES):
            digest.update(block)
    return digest.hexdigest()


def load_hashes(cache: Path) -> dict:
    path = cache / HASHES_FILE
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def save_hashes(cache: Path, hashes: dict) -> None:
    (cache / HASHES_FILE).write_text(json.dumps(hashes, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")


def download(url: str, destination: Path, cache: Path, opener: Opener = urllib.request.urlopen, cap: int = CACHE_CAP_BYTES) -> bool:
    """Downloads `url` to `destination` inside `cache` and records its hash.

    Returns False when the file was already there with the recorded hash.
    Raises CacheCapExceeded, leaving nothing behind, when the cache would pass `cap`.
    """
    relative = destination.relative_to(cache).as_posix()
    hashes = load_hashes(cache)
    if destination.exists() and hashes.get(relative, {}).get("sha256") == sha256(destination):
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".part")
    partial.unlink(missing_ok=True)
    used = cache_size(cache) - (destination.stat().st_size if destination.exists() else 0)
    with opener(url) as response:
        announced = int(response.headers.get("Content-Length", 0) or 0)
        if used + announced > cap:
            raise CacheCapExceeded(f"{url} ({announced} bytes) would take the cache past {cap} bytes ({used} used)")
        written = 0
        try:
            with partial.open("wb") as file:
                while block := response.read(CHUNK_BYTES):
                    written += len(block)
                    if used + written > cap:
                        raise CacheCapExceeded(f"{url} passed the cache cap of {cap} bytes while downloading")
                    file.write(block)
        except BaseException:
            partial.unlink(missing_ok=True)
            raise
    partial.replace(destination)
    hashes[relative] = {"url": url, "bytes": written, "sha256": sha256(destination)}
    save_hashes(cache, hashes)
    return True


def extract_annotations(cache: Path, archive: Path, cap: int = CACHE_CAP_BYTES) -> None:
    """Unpacks the annotations zip into <cache>/annotations, within the cap."""
    target = cache / "annotations"
    if target.exists():
        return
    with zipfile.ZipFile(archive) as bundle:
        unpacked = sum(info.file_size for info in bundle.infolist())
        if cache_size(cache) + unpacked > cap:
            raise CacheCapExceeded(f"unpacking {archive.name} ({unpacked} bytes) would take the cache past {cap} bytes")
        partial = cache / "annotations.part"
        shutil.rmtree(partial, ignore_errors=True)
        bundle.extractall(partial)
    partial.replace(target)


def fetch(cache: Path, meetings: list[str], opener: Opener = urllib.request.urlopen, cap: int = CACHE_CAP_BYTES) -> list[Path]:
    """Fetches the annotations, then every headset of each meeting. Returns new files."""
    cache = ami.refuse_production_path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    (cache / "ATTRIBUTION.txt").write_text(ami.ATTRIBUTION, encoding="utf-8")
    fetched = []
    archive = cache / Path(ami.ANNOTATIONS_URL).name
    if download(ami.ANNOTATIONS_URL, archive, cache, opener, cap):
        fetched.append(archive)
    extract_annotations(cache, archive, cap)
    for meeting in meetings:
        if meeting in ami.EXCLUDED_MEETINGS:
            raise ValueError(f"{meeting} is a known defective recording: {ami.EXCLUDED_MEETINGS[meeting]}")
        for channel in sorted(ami.channel_map(cache, meeting).values()):
            destination = ami.headset_path(cache, meeting, channel)
            if download(ami.AUDIO_URL.format(meeting=meeting, channel=channel), destination, cache, opener, cap):
                fetched.append(destination)
    return fetched


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", type=Path, required=True, help="cache folder, outside the app's data")
    parser.add_argument("--meetings", default="", help="comma-separated meeting IDs whose headsets to fetch")
    args = parser.parse_args(argv)
    meetings = [meeting.strip() for meeting in args.meetings.split(",") if meeting.strip()]
    try:
        for path in fetch(args.cache, meetings):
            print(f"fetched {path}")
    except (CacheCapExceeded, ValueError, KeyError) as error:
        print(f"fetch_ami: {error}", file=sys.stderr)
        return 1
    print(f"cache: {cache_size(args.cache) / 1e6:.0f} MB of {CACHE_CAP_BYTES / 1e6:.0f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
