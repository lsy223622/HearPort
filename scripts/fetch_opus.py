#!/usr/bin/env python3
"""Fetch the pinned Opus release source used by HearPort native builds."""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from urllib.error import URLError
from pathlib import Path, PurePosixPath


PROJECT_ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.6.1"
URL = f"https://downloads.xiph.org/releases/opus/opus-{VERSION}.tar.gz"
SHA256 = "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
VENDOR_PARENT = PROJECT_ROOT / "ios" / "HearPortReceiver" / "Vendor"
SOURCE_DIR = VENDOR_PARENT / "opus"
MARKER = ".hearport-opus-source.json"


class FetchError(RuntimeError):
    pass


def _marker_matches(path: Path) -> bool:
    try:
        marker = json.loads((path / MARKER).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return (
        marker == {"version": VERSION, "url": URL, "sha256": SHA256}
        and (path / "CMakeLists.txt").is_file()
        and (path / "COPYING").is_file()
        and (path / "include" / "opus.h").is_file()
    )


def _download(archive_path: Path) -> None:
    digest = hashlib.sha256()
    with urllib.request.urlopen(URL, timeout=60) as response, archive_path.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
            output.write(chunk)
    if digest.hexdigest() != SHA256:
        raise FetchError(
            f"SHA-256 mismatch for Opus {VERSION}: expected {SHA256}, got {digest.hexdigest()}"
        )


def _extract(archive_path: Path, destination: Path) -> None:
    expected_root = f"opus-{VERSION}"
    with tarfile.open(archive_path, mode="r:gz") as archive:
        for member in archive.getmembers():
            member_path = PurePosixPath(member.name)
            if (
                member_path.is_absolute()
                or ".." in member_path.parts
                or "\\" in member.name
                or any(":" in part for part in member_path.parts)
                or not member_path.parts
                or member_path.parts[0] != expected_root
                or member.issym()
                or member.islnk()
            ):
                raise FetchError(f"Unsafe path in Opus source archive: {member.name}")
            relative = member_path.parts[1:]
            if not relative:
                continue
            output_path = destination.joinpath(*relative)
            if member.isdir():
                output_path.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise FetchError(f"Unsupported entry in Opus source archive: {member.name}")
            output_path.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                raise FetchError(f"Cannot read Opus source archive entry: {member.name}")
            with source, output_path.open("wb") as output:
                shutil.copyfileobj(source, output)


def fetch() -> Path:
    VENDOR_PARENT.mkdir(parents=True, exist_ok=True)
    if SOURCE_DIR.exists():
        if _marker_matches(SOURCE_DIR):
            return SOURCE_DIR
        if not (SOURCE_DIR / MARKER).is_file():
            raise FetchError(f"Refusing to replace unmarked directory: {SOURCE_DIR}")

    with tempfile.TemporaryDirectory(prefix="opus-fetch-", dir=VENDOR_PARENT) as temporary:
        temporary_path = Path(temporary)
        archive_path = temporary_path / f"opus-{VERSION}.tar.gz"
        staging_path = temporary_path / "source"
        staging_path.mkdir()
        _download(archive_path)
        _extract(archive_path, staging_path)
        if not (staging_path / "CMakeLists.txt").is_file():
            raise FetchError("Pinned Opus archive does not contain its CMake project")
        (staging_path / MARKER).write_text(
            json.dumps({"version": VERSION, "url": URL, "sha256": SHA256}, indent=2) + "\n",
            encoding="utf-8",
        )
        if SOURCE_DIR.exists():
            shutil.rmtree(SOURCE_DIR)
        staging_path.replace(SOURCE_DIR)
    return SOURCE_DIR


def main() -> int:
    try:
        print(fetch())
    except (FetchError, OSError, tarfile.TarError, URLError) as error:
        print(f"fetch_opus.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
