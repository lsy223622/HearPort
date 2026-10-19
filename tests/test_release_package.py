import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.package_release import collect_runtime, validate_notices


class ReleasePackageTests(unittest.TestCase):
    def test_opus_license_is_required_for_static_linked_release(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("THIRD_PARTY_NOTICES.md", "rust-dependencies.md",
                         "licenses/hearport/LICENSE", "licenses/msquic/copyright",
                         "licenses/rust/example/LICENSE"):
                file = root / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("x86_64-pc-windows-msvc `licenses/rust/example/LICENSE`")
            with self.assertRaisesRegex(ValueError, "Missing"):
                validate_notices(root)

    def test_unrelated_folder_cannot_substitute_for_dependency_notices(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "unrelated.txt").write_text("not a license inventory")
            with self.assertRaisesRegex(ValueError, "Missing"):
                validate_notices(root)

    def test_transitive_runtime_is_bundled_without_unrelated_build_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build, runtime, system = [root / name for name in ("build", "runtime", "system")]
            for folder in (build, runtime, system):
                folder.mkdir()
            for file in (build / "HearPort.exe", build / "msquic.dll", build / "private.log",
                         build / "test.exe", runtime / "vcruntime140.dll", system / "kernel32.dll"):
                file.touch()
            graph = {"HearPort.exe": ["msquic.dll", "kernel32.dll"],
                     "msquic.dll": ["vcruntime140.dll"], "vcruntime140.dll": ["kernel32.dll"]}
            with patch("scripts.package_release.binary_imports", side_effect=lambda p, _: graph[p.name]):
                files = collect_runtime(build / "HearPort.exe", "dumpbin", [build, runtime], system)
            self.assertEqual({"HearPort.exe", "msquic.dll", "vcruntime140.dll"}, set(files))

    def test_debug_or_missing_runtime_cannot_be_hidden_by_developer_machine(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "HearPort.exe"
            executable.touch()
            with patch("scripts.package_release.binary_imports", return_value=["ucrtbased.dll"]):
                with self.assertRaisesRegex(ValueError, "Debug"):
                    collect_runtime(executable, "dumpbin", [root], root)
            (root / "vcruntime140.dll").touch()
            with patch("scripts.package_release.binary_imports", return_value=["vcruntime140.dll"]):
                with self.assertRaisesRegex(ValueError, "Missing"):
                    collect_runtime(executable, "dumpbin", [], root)
