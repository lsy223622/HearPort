import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.collect_notices import NoticeCollectionError, collect


class CollectNoticesTests(unittest.TestCase):
    def _metadata(self, package_root: Path):
        package_root.mkdir()
        (package_root / "Cargo.toml").write_text("", encoding="utf-8")
        (package_root / "LICENSE-MIT").write_text("crate license", encoding="utf-8")
        return {
            "packages": [
                {
                    "id": "path+file:///provider#hearport-spake2-provider@0.1.0",
                    "name": "hearport-spake2-provider",
                    "version": "0.1.0",
                    "license": "MIT",
                    "license_file": None,
                    "manifest_path": str(package_root / "Cargo.toml"),
                    "source": None,
                    "dependencies": [],
                }
            ],
            "workspace_members": [
                "path+file:///provider#hearport-spake2-provider@0.1.0"
            ],
        }

    def test_copies_opus_license_and_pinned_source_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_root = root / "provider"
            metadata = self._metadata(package_root)
            opus_copying = root / "opus-COPYING"
            opus_copying.write_text("upstream Opus license", encoding="utf-8")
            output = root / "notices"

            with patch("scripts.collect_notices._cargo_metadata", return_value=metadata), patch(
                "scripts.collect_notices.OPUS_COPYING", opus_copying
            ):
                collect(output, None, target="aarch64-apple-ios")

            self.assertEqual(
                "upstream Opus license",
                (output / "licenses" / "opus" / "COPYING").read_text(encoding="utf-8"),
            )
            inventory = (output / "opus-dependencies.md").read_text(encoding="utf-8")
            self.assertIn("`1.6.1`", inventory)
            self.assertIn(
                "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1",
                inventory,
            )

    def test_requires_the_opus_license_source(self):
        with tempfile.TemporaryDirectory() as directory:
            missing_copying = Path(directory) / "missing-COPYING"
            with patch("scripts.collect_notices.OPUS_COPYING", missing_copying):
                with self.assertRaisesRegex(NoticeCollectionError, "Opus license not found"):
                    collect(Path(directory) / "notices", None, target="aarch64-apple-ios")


if __name__ == "__main__":
    unittest.main()
