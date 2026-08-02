#!/usr/bin/env python3
"""准备 Windows Debug 附加运行时，然后构建并运行应用。"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).parent.parent.resolve()
DEBUG_BUNDLE_DIR = (
    PROJECT_ROOT / "build" / "windows" / "x64" / "runner" / "Debug"
)


def _configure_utf8_output() -> None:
    """确保 Windows 控制台能稳定显示中文诊断。"""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(
                encoding="utf-8",
                errors="backslashreplace",
                line_buffering=True,
            )


def _run(command: list[str]) -> None:
    print(f"[INFO] 执行：{' '.join(command)}")
    subprocess.run(command, cwd=PROJECT_ROOT, check=True)


def _prepare_openocd_runtime(source: str | None, cache: Path | None) -> None:
    """准备 flutter run 不会自动生成的内置 OpenOCD 压缩运行时。"""
    command = [
        sys.executable,
        str(PROJECT_ROOT / "tools" / "prepare_openocd_runtime.py"),
        "--bundle",
        str(DEBUG_BUNDLE_DIR),
    ]
    if source:
        command.extend(("--source", source))
    if cache:
        command.extend(("--cache", str(cache.resolve())))
    _run(command)


def _prepare_debug_runtime(source: str | None, cache: Path | None) -> None:
    """集中准备 Debug 附加内容，后续新增内容时在此登记。"""
    DEBUG_BUNDLE_DIR.mkdir(parents=True, exist_ok=True)
    _prepare_openocd_runtime(source, cache)


def _parse_args() -> tuple[argparse.Namespace, list[str]]:
    parser = argparse.ArgumentParser(
        description=(
            "先准备 flutter run 不会生成的 Windows Debug 附加内容，"
            "再构建并运行应用。"
        ),
    )
    parser.add_argument(
        "--openocd-source",
        help=(
            "可选的 xPack OpenOCD 根目录；未指定时使用 "
            "VSCOPE_OPENOCD_ROOT 或下载项目锁定版本"
        ),
    )
    parser.add_argument(
        "--openocd-cache",
        type=Path,
        help="可选的 OpenOCD 下载缓存目录",
    )
    parser.add_argument(
        "--build-only",
        action="store_true",
        help="只执行 Windows Debug 构建，不启动应用",
    )
    parser.add_argument(
        "flutter_args",
        nargs=argparse.REMAINDER,
        help="传给 flutter run 的额外参数，请放在 -- 之后",
    )
    args = parser.parse_args()
    flutter_args = list(args.flutter_args)
    if flutter_args[:1] == ["--"]:
        flutter_args.pop(0)
    return args, flutter_args


def main() -> int:
    _configure_utf8_output()
    args, flutter_args = _parse_args()

    flutter = shutil.which("flutter")
    if flutter is None:
        print("[ERROR] 未找到 flutter，请先把 Flutter SDK 加入 PATH。")
        return 1

    try:
        print("[STEP] 准备 Windows Debug 附加运行时")
        _prepare_debug_runtime(args.openocd_source, args.openocd_cache)

        if args.build_only:
            if flutter_args:
                print("[WARN] --build-only 模式会忽略 flutter run 额外参数。")
            print("[STEP] 构建 Windows Debug")
            _run([flutter, "build", "windows", "--debug"])
        else:
            print("[STEP] 构建并运行 Windows Debug")
            _run([flutter, "run", "-d", "windows", "--debug", *flutter_args])
    except KeyboardInterrupt:
        print("\n[INFO] 已停止 Debug 运行。")
        return 130
    except subprocess.CalledProcessError as error:
        print(f"[ERROR] 命令执行失败，退出码：{error.returncode}")
        return error.returncode

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
