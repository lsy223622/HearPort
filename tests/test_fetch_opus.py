import io
import tarfile
import tempfile
import unittest
from pathlib import Path

from scripts.fetch_opus import FetchError, _extract


def _make_archive(path: Path, name: str, contents: bytes) -> None:
    with tarfile.open(path, "w:gz") as archive:
        entry = tarfile.TarInfo(name)
        entry.size = len(contents)
        archive.addfile(entry, io.BytesIO(contents))


class FetchOpusTests(unittest.TestCase):
    def test_extracts_files_only_from_the_pinned_release_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "opus.tar.gz"
            destination = root / "source"
            destination.mkdir()
            _make_archive(archive, "opus-1.6.1/include/opus.h", b"header")

            _extract(archive, destination)

            self.assertEqual(b"header", (destination / "include" / "opus.h").read_bytes())

    def test_rejects_archive_path_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "opus.tar.gz"
            destination = root / "source"
            destination.mkdir()
            _make_archive(archive, "opus-1.6.1/../../escape.txt", b"escape")

            with self.assertRaisesRegex(FetchError, "Unsafe path"):
                _extract(archive, destination)

            self.assertFalse((root / "escape.txt").exists())


if __name__ == "__main__":
    unittest.main()
