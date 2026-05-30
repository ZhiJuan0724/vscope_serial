#!/usr/bin/env python3
"""
Generate VScope plot BIN files for import/performance testing.

The output matches PlotViewModel.importFromBin version 2:
  header(28 bytes) + metadata JSON + payload rows

Each payload row is:
  float64 x + channel_count * float64 values
"""

import argparse
import binascii
import json
import math
import os
import struct
import sys
from typing import BinaryIO, List


MAGIC = b"VSPLOTB1"
VERSION = 2
MAX_CHANNEL_COUNT = 16
MAX_U32 = 0xFFFFFFFF


def _channel_names(channel_count: int) -> List[str]:
    return [f"Ch{i}" for i in range(channel_count)]


def _value_for(mode: str, point_index: int, channel_index: int, amplitude: float) -> float:
    if mode == "sine":
        phase = channel_index * math.pi / max(1, channel_index + 2)
        baseline = (channel_index + 1) * amplitude * 1.8
        return baseline + amplitude * math.sin(point_index * 0.01 + phase)
    if mode == "step":
        segment = (point_index // 1000) % 4
        return float(segment * amplitude + channel_index * amplitude * 0.1)
    if mode == "ramp":
        period = max(1, int(amplitude * 20))
        return float((point_index * (channel_index + 1)) % period)
    if mode == "constant":
        return float((channel_index + 1) * amplitude)
    raise ValueError(f"unsupported mode: {mode}")


def _write_payload(
    file: BinaryIO,
    point_count: int,
    channel_count: int,
    mode: str,
    amplitude: float,
    progress_interval: int,
    initial_crc: int,
) -> int:
    crc = initial_crc
    row_format = "<" + "d" * (channel_count + 1)
    row_values = [0.0] * (channel_count + 1)

    for point_index in range(point_count):
        row_values[0] = float(point_index)
        for channel_index in range(channel_count):
            row_values[channel_index + 1] = _value_for(
                mode,
                point_index,
                channel_index,
                amplitude,
            )
        row = struct.pack(row_format, *row_values)
        file.write(row)
        crc = binascii.crc32(row, crc)

        if progress_interval > 0 and (point_index + 1) % progress_interval == 0:
            print(f"[生成] {point_index + 1}/{point_count} 包")

    return crc & 0xFFFFFFFF


def generate(args: argparse.Namespace) -> str:
    point_count = args.packets
    channel_count = args.channels
    if point_count <= 0:
        raise ValueError("packets must be > 0")
    if channel_count < 1 or channel_count > MAX_CHANNEL_COUNT:
        raise ValueError(f"channels must be 1~{MAX_CHANNEL_COUNT}")

    payload_length = point_count * (8 + channel_count * 8)
    if payload_length > MAX_U32:
        raise ValueError(
            "payload exceeds current VSPLOTB1 v2 4GB limit; "
            f"packets={point_count}, channels={channel_count}, payload={payload_length}"
        )

    metadata = {
        "channelNames": _channel_names(channel_count),
        "generator": "test_tools/generate_plot_bin.py",
        "mode": args.mode,
    }
    metadata_bytes = json.dumps(metadata, separators=(",", ":")).encode("utf-8")

    output = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)

    with open(output, "wb") as file:
        file.write(b"\x00" * 28)
        file.write(metadata_bytes)
        crc = binascii.crc32(metadata_bytes)
        crc = _write_payload(
            file,
            point_count,
            channel_count,
            args.mode,
            args.amplitude,
            args.progress,
            crc,
        )

        header = bytearray(28)
        header[0:8] = MAGIC
        struct.pack_into("<H", header, 8, VERSION)
        struct.pack_into("<H", header, 10, channel_count)
        struct.pack_into("<I", header, 12, point_count)
        struct.pack_into("<I", header, 16, payload_length)
        struct.pack_into("<I", header, 20, crc)
        struct.pack_into("<I", header, 24, len(metadata_bytes))
        file.seek(0)
        file.write(header)

    size_mb = os.path.getsize(output) / 1024 / 1024
    print(
        f"[完成] {output}\n"
        f"       包数={point_count}, 通道={channel_count}, 模式={args.mode}, "
        f"大小={size_mb:.1f} MB"
    )
    return output


def main() -> int:
    parser = argparse.ArgumentParser(
        description="生成可由 VScope 绘图界面导入的 BIN 测试文件",
    )
    parser.add_argument("--output", "-o", required=True, help="输出 .bin 路径")
    parser.add_argument("--packets", "-n", type=int, required=True, help="生成包数")
    parser.add_argument(
        "--channels",
        "-c",
        type=int,
        required=True,
        help="通道数，范围 1~16",
    )
    parser.add_argument(
        "--mode",
        "-m",
        choices=["sine", "step", "ramp", "constant"],
        default="sine",
        help="数据模式，默认 sine",
    )
    parser.add_argument(
        "--amplitude",
        "-a",
        type=float,
        default=1000.0,
        help="数据幅度，默认 1000",
    )
    parser.add_argument(
        "--progress",
        type=int,
        default=100000,
        help="每多少包打印一次进度，0 表示不打印",
    )
    args = parser.parse_args()

    try:
        generate(args)
        return 0
    except Exception as exc:
        print(f"[错误] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
