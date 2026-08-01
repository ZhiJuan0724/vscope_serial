#!/usr/bin/env python3
"""Prepare the pinned, minimal Windows OpenOCD runtime for a release bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path


def _configure_utf8_output() -> None:
    """确保 Windows CI 的非 UTF-8 控制台也能输出中文诊断信息。"""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8", errors="backslashreplace")


_configure_utf8_output()


PROJECT_ROOT = Path(__file__).parent.parent.resolve()
OPENOCD_VERSION = "0.12.0-7"
OPENOCD_ARCHIVE = f"xpack-openocd-{OPENOCD_VERSION}-win32-x64.zip"
OPENOCD_URL = (
    "https://github.com/xpack-dev-tools/openocd-xpack/releases/download/"
    f"v{OPENOCD_VERSION}/{OPENOCD_ARCHIVE}"
)
OPENOCD_SHA256 = "6bfd3c97135aafef8affc9af1acf34fd0e2b9ca26044506f6abd7f95b7630052"
RUNTIME_FILES = (
    "openocd.exe",
    "libftdi1.dll",
    "libusb-1.0.dll",
)
RUNTIME_ARCHIVE = "openocd-runtime.zip"
RUNTIME_MANIFEST = "openocd-runtime.json"
RUNTIME_MANIFEST_SCHEMA = 1
REQUIRED_ARCHIVE_PATHS = (
    "bin/openocd.exe",
    "bin/libftdi1.dll",
    "bin/libusb-1.0.dll",
    "openocd/scripts/interface/",
    "openocd/scripts/target/",
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _download_pinned_runtime(cache_dir: Path) -> Path:
    cache_dir.mkdir(parents=True, exist_ok=True)
    archive = cache_dir / OPENOCD_ARCHIVE
    if not archive.exists() or _sha256(archive) != OPENOCD_SHA256:
        if archive.exists():
            archive.unlink()
        print(f"[INFO] 下载 OpenOCD {OPENOCD_VERSION}: {OPENOCD_URL}")
        urllib.request.urlretrieve(OPENOCD_URL, archive)
    actual_hash = _sha256(archive)
    if actual_hash != OPENOCD_SHA256:
        raise RuntimeError(
            f"OpenOCD 压缩包 SHA-256 不匹配：{actual_hash}"
        )

    extracted = cache_dir / f"xpack-openocd-{OPENOCD_VERSION}"
    if extracted.exists():
        shutil.rmtree(extracted)
    with zipfile.ZipFile(archive) as package:
        package.extractall(cache_dir)
    if not extracted.exists():
        raise FileNotFoundError(f"OpenOCD 解压目录不存在：{extracted}")
    return extracted


def _resolve_source(explicit_source: str | None, cache_dir: Path) -> Path:
    configured = explicit_source or os.environ.get("VSCOPE_OPENOCD_ROOT", "")
    if configured:
        return Path(configured).expanduser().resolve()
    return _download_pinned_runtime(cache_dir)


def _validate_source(source: Path) -> None:
    missing = [
        source / "bin" / name
        for name in RUNTIME_FILES
        if not (source / "bin" / name).is_file()
    ]
    scripts = source / "openocd" / "scripts"
    if not scripts.is_dir():
        missing.append(scripts)
    if missing:
        raise FileNotFoundError(
            "OpenOCD 运行时不完整：" + "，".join(str(path) for path in missing)
        )


def prepare_runtime(source: Path, bundle: Path) -> Path:
    _validate_source(source)
    destination = bundle / "runtime" / "openocd"
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)

    entries: list[tuple[Path, str]] = [
        (source / "bin" / name, f"bin/{name}")
        for name in RUNTIME_FILES
    ]
    scripts = source / "openocd" / "scripts"
    entries.extend(
        (path, path.relative_to(source).as_posix())
        for path in scripts.rglob("*")
        if path.is_file()
    )
    readme = source / "README.md"
    if readme.is_file():
        entries.append((readme, "README.md"))
    licenses = source / "distro-info" / "licenses"
    if licenses.is_dir():
        entries.extend(
            (path, f"licenses/{path.relative_to(licenses).as_posix()}")
            for path in licenses.rglob("*")
            if path.is_file()
        )

    archive = destination / RUNTIME_ARCHIVE
    with zipfile.ZipFile(
        archive,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=6,
    ) as package:
        for path, archive_path in sorted(entries, key=lambda item: item[1]):
            package.write(path, archive_path)

    with zipfile.ZipFile(destination / RUNTIME_ARCHIVE) as package:
        names = set(package.namelist())
        missing = [
            path
            for path in REQUIRED_ARCHIVE_PATHS
            if not any(name == path.rstrip("/") or name.startswith(path) for name in names)
        ]
        if missing:
            raise RuntimeError("OpenOCD 运行时压缩包不完整：" + "，".join(missing))

    archive = destination / RUNTIME_ARCHIVE
    manifest = {
        "schemaVersion": RUNTIME_MANIFEST_SCHEMA,
        "version": OPENOCD_VERSION,
        "archive": RUNTIME_ARCHIVE,
        "size": archive.stat().st_size,
        "sha256": _sha256(archive),
    }
    (destination / RUNTIME_MANIFEST).write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(
        f"[OK] 已打包轻量 OpenOCD：{archive} "
        f"({archive.stat().st_size / 1024 / 1024:.2f} MiB)"
    )
    return destination


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument(
        "--source",
        help="可选的 xPack OpenOCD 根目录；默认下载并校验固定版本",
    )
    parser.add_argument(
        "--cache",
        type=Path,
        default=PROJECT_ROOT / "build" / "tool_cache" / "openocd",
    )
    args = parser.parse_args()
    source = _resolve_source(args.source, args.cache.resolve())
    prepare_runtime(source, args.bundle.resolve())


if __name__ == "__main__":
    main()
