#!/usr/bin/env python3
"""Windows 发布目录组装器测试。"""

import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(PROJECT_ROOT / "tools"))

from prepare_windows_release_bundle import (  # noqa: E402
    assemble_windows_release_bundle,
    find_vc_runtime_directory,
    verify_windows_release_bundle,
)
from generate_update_assets import generate  # noqa: E402


class PrepareWindowsReleaseBundleTest(unittest.TestCase):
    def _create_runtime(self, root: Path, include_all: bool = True) -> Path:
        runtime = root / "Microsoft.VC143.CRT"
        runtime.mkdir(parents=True)
        names = ["MSVCP140.dll", "VCRUNTIME140.dll"]
        if include_all:
            names.append("VCRUNTIME140_1.dll")
        names.append("msvcp140_atomic_wait.dll")
        for name in names:
            (runtime / name).write_bytes(name.encode("ascii"))
        return runtime

    def _create_source(self, root: Path) -> Path:
        source = root / "source"
        source.mkdir()
        for name in (
            "vscope_serial.exe",
            "vscope_updater.exe",
            "native_serial_reader.dll",
        ):
            (source / name).write_bytes(name.encode("ascii"))
        (source / "native_serial_reader.pdb").write_bytes(b"symbols")
        (source / "logs").mkdir()
        (source / "logs" / "old.log").write_text("old", encoding="utf-8")
        (source / "data").mkdir()
        (source / "data" / "app.so").write_bytes(b"app")
        return source

    def test_assemble_copies_required_runtime_and_excludes_build_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = self._create_source(root)
            runtime = self._create_runtime(root)
            notices = root / "THIRD_PARTY_NOTICES.md"
            notices.write_text("notices", encoding="utf-8")
            destination = root / "bundle"

            copied = assemble_windows_release_bundle(
                source,
                destination,
                runtime,
                notices,
            )

            self.assertTrue((destination / "vscope_serial.exe").is_file())
            self.assertTrue((destination / "data" / "app.so").is_file())
            self.assertFalse((destination / "native_serial_reader.pdb").exists())
            self.assertFalse((destination / "logs").exists())
            self.assertEqual(
                {path.name for path in copied},
                {
                    "MSVCP140.dll",
                    "VCRUNTIME140.dll",
                    "VCRUNTIME140_1.dll",
                },
            )
            self.assertFalse((destination / "msvcp140_atomic_wait.dll").exists())
            verify_windows_release_bundle(destination, require_openocd=False)

    def test_explicit_runtime_directory_must_be_complete(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            runtime = self._create_runtime(Path(temp), include_all=False)
            with self.assertRaises(FileNotFoundError):
                find_vc_runtime_directory(runtime)

    def test_source_and_destination_cannot_contain_each_other(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = self._create_source(root)
            runtime = self._create_runtime(root)
            notices = root / "THIRD_PARTY_NOTICES.md"
            notices.write_text("notices", encoding="utf-8")
            with self.assertRaises(ValueError):
                assemble_windows_release_bundle(
                    source,
                    source / "bundle",
                    runtime,
                    notices,
                )

    def test_update_assets_reject_incomplete_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = self._create_source(root)
            runtime = self._create_runtime(root)
            notices = root / "THIRD_PARTY_NOTICES.md"
            notices.write_text("notices", encoding="utf-8")
            destination = root / "bundle"
            assemble_windows_release_bundle(
                source,
                destination,
                runtime,
                notices,
            )

            with self.assertRaises(FileNotFoundError):
                generate(destination, "v1.2.3", root / "dist")


if __name__ == "__main__":
    unittest.main()
