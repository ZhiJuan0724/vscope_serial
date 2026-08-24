#!/usr/bin/env python3
"""组装本地发布与 CI 共用的 Windows 发布目录。"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).parent.parent.resolve()
REQUIRED_VC_RUNTIME_DLLS = {
    "msvcp140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll",
}
EXCLUDED_TOP_LEVEL = {
    "settings",
    "config",
    "logs",
    "exports",
    ".flutter-plugins",
    ".flutter-plugins-dependencies",
    "native_assets.json",
}
EXCLUDED_SUFFIXES = {".lib", ".exp", ".pdb"}


def _runtime_version_key(path: Path) -> tuple[int, ...]:
    numbers = re.findall(r"\d+", path.as_posix())
    return tuple(int(number) for number in numbers)


def _is_valid_vc_runtime_directory(path: Path) -> bool:
    if not path.is_dir():
        return False
    names = {item.name.lower() for item in path.iterdir() if item.is_file()}
    return REQUIRED_VC_RUNTIME_DLLS <= names


def _runtime_directories_for_installation(installation: Path) -> list[Path]:
    return list(
        installation.glob("VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT")
    )


def _generator_installation_from_build(source: Path) -> Path | None:
    for directory in (source, *source.parents):
        cache = directory / "CMakeCache.txt"
        if not cache.is_file():
            continue
        for line in cache.read_text(encoding="utf-8", errors="replace").splitlines():
            prefix = "CMAKE_GENERATOR_INSTANCE:INTERNAL="
            if line.startswith(prefix):
                value = line[len(prefix) :].strip()
                return Path(value) if value else None
        return None
    return None


def find_vc_runtime_directory(
    explicit: Path | None = None,
    preferred_installation: Path | None = None,
) -> Path:
    """定位与本机 Visual Studio 工具链匹配的 x64 CRT 可再发行目录。"""
    candidates: list[Path] = []

    def add_candidate(path: Path) -> None:
        resolved = path.expanduser()
        if resolved not in candidates:
            candidates.append(resolved)

    if explicit is not None:
        explicit = explicit.expanduser().resolve()
        if not _is_valid_vc_runtime_directory(explicit):
            raise FileNotFoundError(f"显式指定的 VC++ Runtime 目录无效: {explicit}")
        return explicit

    if preferred_installation is not None:
        preferred = [
            path.resolve()
            for path in _runtime_directories_for_installation(preferred_installation)
            if _is_valid_vc_runtime_directory(path)
        ]
        if not preferred:
            raise FileNotFoundError(
                "当前 Windows 构建使用的 Visual Studio 缺少必要 x64 VC++ Runtime: "
                f"{preferred_installation}"
            )
        return max(preferred, key=_runtime_version_key)

    tools_redist = os.environ.get("VCToolsRedistDir")
    if tools_redist:
        base = Path(tools_redist)
        add_candidate(base)
        for path in base.glob("x64/Microsoft.VC*.CRT"):
            add_candidate(path)

    program_roots = {
        Path(os.environ.get("ProgramFiles", "C:/Program Files")),
        Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")),
    }
    for program_root in program_roots:
        visual_studio_root = program_root / "Microsoft Visual Studio"
        if visual_studio_root.is_dir():
            for path in visual_studio_root.glob(
                "*/*/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT"
            ):
                add_candidate(path)

    vswhere = (
        Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)"))
        / "Microsoft Visual Studio"
        / "Installer"
        / "vswhere.exe"
    )
    if vswhere.is_file():
        result = subprocess.run(
            [
                str(vswhere),
                "-all",
                "-products",
                "*",
                "-property",
                "installationPath",
            ],
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        for line in result.stdout.splitlines():
            installation = Path(line.strip())
            if not line.strip():
                continue
            for path in _runtime_directories_for_installation(installation):
                add_candidate(path)

    valid = [path.resolve() for path in candidates if _is_valid_vc_runtime_directory(path)]
    if not valid:
        searched = "\n".join(f"- {path}" for path in candidates) or "- 未发现候选目录"
        raise FileNotFoundError(
            "未找到包含必要 x64 VC++ Runtime 的 Visual Studio 可再发行目录。\n"
            f"已检查：\n{searched}"
        )
    return max(valid, key=_runtime_version_key)


def _is_release_file(source: Path, path: Path) -> bool:
    relative = path.relative_to(source)
    if not relative.parts:
        return False
    if relative.parts[0].lower() in EXCLUDED_TOP_LEVEL:
        return False
    return path.suffix.lower() not in EXCLUDED_SUFFIXES


def assemble_windows_release_bundle(
    source: Path,
    destination: Path,
    vc_runtime_directory: Path,
    notices_path: Path,
) -> list[Path]:
    """复制构建产物并部署同一工具链中当前所需的 x64 CRT。"""
    source = source.resolve()
    destination = destination.resolve()
    vc_runtime_directory = vc_runtime_directory.resolve()
    notices_path = notices_path.resolve()

    if not source.is_dir():
        raise FileNotFoundError(f"Windows Release 构建目录不存在: {source}")
    if (
        source == destination
        or destination in source.parents
        or source in destination.parents
    ):
        raise ValueError("发布目录不能与构建目录相同，也不能相互包含")
    if destination == Path(destination.anchor) or destination == PROJECT_ROOT:
        raise ValueError("发布目录不能是文件系统根目录或项目根目录")
    if not notices_path.is_file():
        raise FileNotFoundError(f"第三方许可文件不存在: {notices_path}")
    if not _is_valid_vc_runtime_directory(vc_runtime_directory):
        raise FileNotFoundError(
            f"VC++ Runtime 目录缺少必要 DLL: {vc_runtime_directory}"
        )

    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)

    for path in sorted(source.rglob("*")):
        if not path.is_file() or not _is_release_file(source, path):
            continue
        target = destination / path.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)

    runtime_files = {
        item.name.lower(): item
        for item in vc_runtime_directory.iterdir()
        if item.is_file()
    }
    copied_runtime: list[Path] = []
    for name in sorted(REQUIRED_VC_RUNTIME_DLLS):
        runtime_dll = runtime_files[name]
        target = destination / runtime_dll.name
        shutil.copy2(runtime_dll, target)
        copied_runtime.append(target)

    shutil.copy2(notices_path, destination / "THIRD_PARTY_NOTICES.md")
    verify_windows_release_bundle(destination, require_openocd=False)
    return copied_runtime


def verify_windows_release_bundle(bundle: Path, require_openocd: bool = True) -> None:
    """验证发布目录中的核心程序、运行库和附加运行时。"""
    bundle = bundle.resolve()
    required_files = {
        "vscope_serial.exe",
        "vscope_updater.exe",
        "native_serial_reader.dll",
        "THIRD_PARTY_NOTICES.md",
        *REQUIRED_VC_RUNTIME_DLLS,
    }
    names = {item.name.lower() for item in bundle.iterdir() if item.is_file()}
    missing = sorted(name for name in required_files if name.lower() not in names)
    if missing:
        raise FileNotFoundError(f"Windows 发布目录缺少文件: {', '.join(missing)}")

    if require_openocd:
        openocd_root = bundle / "runtime" / "openocd"
        for name in ("openocd-runtime.zip", "openocd-runtime.json"):
            if not (openocd_root / name).is_file():
                raise FileNotFoundError(f"Windows 发布目录缺少 OpenOCD 运行时: {name}")


def prepare_windows_release_bundle(
    source: Path,
    destination: Path,
    vc_runtime_directory: Path | None = None,
    openocd_source: Path | None = None,
    openocd_cache: Path | None = None,
) -> list[Path]:
    """执行本地与 CI 完全一致的 Windows 发布目录组装流程。"""
    build_installation = _generator_installation_from_build(source.resolve())
    runtime_directory = find_vc_runtime_directory(
        vc_runtime_directory,
        preferred_installation=build_installation,
    )
    copied_runtime = assemble_windows_release_bundle(
        source,
        destination,
        runtime_directory,
        PROJECT_ROOT / "THIRD_PARTY_NOTICES.md",
    )

    command = [
        sys.executable,
        str(PROJECT_ROOT / "tools" / "prepare_openocd_runtime.py"),
        "--bundle",
        str(destination.resolve()),
    ]
    if openocd_source is not None:
        command.extend(["--source", str(openocd_source.resolve())])
    if openocd_cache is not None:
        command.extend(["--cache", str(openocd_cache.resolve())])
    subprocess.run(command, cwd=PROJECT_ROOT, check=True)

    verify_windows_release_bundle(destination, require_openocd=True)
    return copied_runtime


def main() -> None:
    parser = argparse.ArgumentParser(description="组装完整的 Windows 发布目录")
    parser.add_argument("--source", required=True, type=Path, help="Flutter Release 构建目录")
    parser.add_argument("--output", required=True, type=Path, help="完整发布目录")
    parser.add_argument("--vc-runtime-dir", type=Path, help="显式指定 x64 VC++ CRT 目录")
    parser.add_argument("--openocd-source", type=Path, help="使用本地 OpenOCD 源目录")
    parser.add_argument("--openocd-cache", type=Path, help="指定 OpenOCD 下载缓存")
    args = parser.parse_args()

    copied_runtime = prepare_windows_release_bundle(
        args.source,
        args.output,
        vc_runtime_directory=args.vc_runtime_dir,
        openocd_source=args.openocd_source,
        openocd_cache=args.openocd_cache,
    )
    build_installation = _generator_installation_from_build(args.source.resolve())
    runtime_source = find_vc_runtime_directory(
        args.vc_runtime_dir,
        preferred_installation=build_installation,
    )
    print(f"VC_RUNTIME_SOURCE={runtime_source}")
    print("VC_RUNTIME_FILES=" + ",".join(path.name for path in copied_runtime))
    print(f"BUNDLE_PATH={args.output.resolve()}")


if __name__ == "__main__":
    main()
