#!/usr/bin/env python3
"""Prepare the pinned, minimal Windows OpenOCD runtime for a release bundle."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import urllib.request
import zipfile
from pathlib import Path


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

    bin_dir = destination / "bin"
    bin_dir.mkdir(parents=True)
    for name in RUNTIME_FILES:
        shutil.copy2(source / "bin" / name, bin_dir / name)

    shutil.copytree(
        source / "openocd" / "scripts",
        destination / "openocd" / "scripts",
    )
    readme = source / "README.md"
    if readme.is_file():
        shutil.copy2(readme, destination / "README.md")
    licenses = source / "distro-info" / "licenses"
    if licenses.is_dir():
        shutil.copytree(licenses, destination / "licenses")

    print(f"[OK] 已内置轻量 OpenOCD：{destination}")
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
