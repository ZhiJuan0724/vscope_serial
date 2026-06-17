#!/usr/bin/env python3
"""Generate a portable ZIP and update metadata for a Windows release."""

import argparse
import hashlib
import json
import os
import re
import shutil
import tempfile
import zipfile
from pathlib import Path


EXCLUDED_TOP_LEVEL = {"settings", "config", "logs", "exports"}


def is_managed_path(relative: Path) -> bool:
    return (
        bool(relative.parts)
        and relative.parts[0].lower() not in EXCLUDED_TOP_LEVEL
        and relative.as_posix() != "app-files.json"
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def managed_files(bundle: Path) -> list[dict[str, object]]:
    files = []
    for path in sorted(bundle.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(bundle)
        if not is_managed_path(relative):
            continue
        files.append(
            {
                "path": relative.as_posix(),
                "sha256": sha256_file(path),
                "size": path.stat().st_size,
            }
        )
    return files


def generate(bundle: Path, tag: str, output_dir: Path) -> tuple[Path, Path]:
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-beta\.\d+)?", tag):
        raise ValueError("release tag must use vX.Y.Z or vX.Y.Z-beta.N format")
    if not (bundle / "vscope_serial.exe").exists():
        raise FileNotFoundError("bundle is missing vscope_serial.exe")
    if not (bundle / "vscope_updater.exe").exists():
        raise FileNotFoundError("bundle is missing vscope_updater.exe")

    output_dir.mkdir(parents=True, exist_ok=True)
    package_name = f"vscope_serial-windows-{tag}.zip"
    manifest_name = f"update-manifest-{tag}.json"
    package_path = output_dir / package_name
    manifest_path = output_dir / manifest_name

    with tempfile.TemporaryDirectory() as temp:
        staged = Path(temp) / "payload"
        staged.mkdir()
        for path in sorted(bundle.rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(bundle)
            if not is_managed_path(relative):
                continue
            destination = staged / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
        app_files = {
            "schemaVersion": 1,
            "files": managed_files(staged),
        }
        (staged / "app-files.json").write_text(
            json.dumps(app_files, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        with zipfile.ZipFile(
            package_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
        ) as archive:
            for path in sorted(staged.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(staged).as_posix())

    update_manifest = {
        "schemaVersion": 1,
        "version": tag[1:],
        "packageName": package_name,
        "packageSize": package_path.stat().st_size,
        "sha256": sha256_file(package_path),
        "executable": "vscope_serial.exe",
    }
    manifest_path.write_text(
        json.dumps(update_manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return package_path, manifest_path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    package, manifest = generate(
        args.bundle.resolve(), args.tag, args.output.resolve()
    )
    print(f"PACKAGE_PATH={package}")
    print(f"MANIFEST_PATH={manifest}")


if __name__ == "__main__":
    main()
