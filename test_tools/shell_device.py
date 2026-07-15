#!/usr/bin/env python3
"""
Shell/YMODEM virtual serial device for VScope Serial.

Typical virtual pair setup:
  - VScope Serial connects COM12
  - This script connects COM13

Examples:
  python test_tools/shell_device.py --port COM13 --mode terminal
  python test_tools/shell_device.py --port COM13 --mode ymodem-send --file E:\\temp\\tx.bin
  python test_tools/shell_device.py --port COM13 --mode ymodem-receive --output E:\\temp\\rx

Dependencies:
  pip install pyserial
"""

import argparse
import os
import sys
import time
from pathlib import Path
from typing import Optional

try:
    import serial
except ImportError:
    print("error: pyserial is required")
    print("  pip install pyserial")
    sys.exit(1)


SOH = 0x01
STX = 0x02
EOT = 0x04
ACK = 0x06
NAK = 0x15
CAN = 0x18
CRC_REQUEST = 0x43
EOF = 0x1A


class YmodemError(Exception):
    pass


def crc16_ccitt(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def read_exact(ser, count: int, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    data = bytearray()
    while len(data) < count:
        if time.monotonic() > deadline:
            raise YmodemError(f"timeout reading {count} bytes")
        chunk = ser.read(count - len(data))
        if chunk:
            data.extend(chunk)
    return bytes(data)


def read_byte(ser, timeout: float = 10.0) -> int:
    return read_exact(ser, 1, timeout)[0]


def wait_for_byte(ser, expected: int, label: str, timeout: float = 10.0) -> None:
    byte = read_byte(ser, timeout)
    if byte == CAN:
        raise YmodemError("peer cancelled transfer")
    if byte != expected:
        raise YmodemError(f"{label}: expected 0x{expected:02X}, got 0x{byte:02X}")


def build_packet(payload: bytes, block: int) -> bytes:
    if len(payload) == 128:
        header = SOH
    elif len(payload) == 1024:
        header = STX
    else:
        raise ValueError("payload must be 128 or 1024 bytes")
    crc = crc16_ccitt(payload)
    block &= 0xFF
    return bytes([header, block, 0xFF - block]) + payload + crc.to_bytes(2, "big")


def build_header_packet(name: str, size: int) -> bytes:
    payload = bytearray([0] * 128)
    metadata = f"{name}\0{size}".encode("ascii", errors="replace")
    payload[: min(len(metadata), 128)] = metadata[:128]
    return build_packet(bytes(payload), 0)


def read_packet(ser, timeout: float = 10.0):
    start = read_byte(ser, timeout)
    if start == CAN:
        raise YmodemError("peer cancelled transfer")
    if start == EOT:
        return ("eot", None, b"")
    if start not in (SOH, STX):
        raise YmodemError(f"unexpected packet start: 0x{start:02X}")

    size = 128 if start == SOH else 1024
    block = read_byte(ser, timeout)
    inverse = read_byte(ser, timeout)
    if ((block + inverse) & 0xFF) != 0xFF:
        raise YmodemError("invalid block inverse")

    payload = read_exact(ser, size, timeout)
    received_crc = int.from_bytes(read_exact(ser, 2, timeout), "big")
    actual_crc = crc16_ccitt(payload)
    if received_crc != actual_crc:
        raise YmodemError(
            f"crc mismatch on block {block}: got 0x{received_crc:04X}, "
            f"expected 0x{actual_crc:04X}"
        )
    return ("packet", block, payload)


def parse_header(payload: bytes):
    metadata = payload.split(b"\0", 2)
    name = metadata[0].decode("utf-8", errors="replace")
    size = 0
    if len(metadata) > 1 and metadata[1]:
        try:
            size = int(metadata[1].split(b" ", 1)[0])
        except ValueError:
            size = 0
    return name, size


def request_ymodem_header(ser, timeout: float = 60.0) -> bytes:
    deadline = time.monotonic() + timeout
    last_error: Optional[YmodemError] = None
    while time.monotonic() < deadline:
        ser.write(bytes([CRC_REQUEST]))
        try:
            kind, block, payload = read_packet(ser, timeout=2.0)
        except YmodemError as error:
            last_error = error
            if str(error).startswith("timeout reading"):
                continue
            raise
        if kind == "packet" and block == 0:
            return payload
        raise YmodemError("invalid ymodem header")
    if last_error is not None:
        raise YmodemError(f"timeout waiting for ymodem header: {last_error}")
    raise YmodemError("timeout waiting for ymodem header")


def safe_target(directory: Path, name: str) -> Path:
    clean = Path(name).name or "ymodem.bin"
    target = directory / clean
    if not target.exists():
        return target
    stem = target.stem
    suffix = target.suffix
    for index in range(1, 10000):
        candidate = directory / f"{stem}_{index}{suffix}"
        if not candidate.exists():
            return candidate
    raise YmodemError("could not find non-conflicting output name")


def ymodem_receive(ser, output_dir: Path) -> Optional[Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    print("[ymodem] requesting file from app...")

    payload = request_ymodem_header(ser)
    name, size = parse_header(payload)
    if not name:
        ser.write(bytes([ACK]))
        print("[ymodem] empty batch")
        return None

    target = safe_target(output_dir, name)
    print(f"[ymodem] receiving {name} ({size} bytes) -> {target}")
    ser.write(bytes([ACK, CRC_REQUEST]))

    received = 0
    expected_block = 1
    with target.open("wb") as handle:
        while True:
            kind, block, payload = read_packet(ser)
            if kind == "eot":
                ser.write(bytes([NAK]))
                kind, _, _ = read_packet(ser)
                if kind != "eot":
                    raise YmodemError("invalid EOT sequence")
                ser.write(bytes([ACK, CRC_REQUEST]))
                kind, final_block, final_payload = read_packet(ser)
                if kind != "packet" or final_block != 0:
                    raise YmodemError("invalid final header")
                ser.write(bytes([ACK]))
                break

            if block != expected_block:
                raise YmodemError(f"unexpected block {block}, expected {expected_block}")
            take = min(len(payload), max(0, size - received))
            handle.write(payload[:take])
            received += take
            expected_block = (expected_block + 1) & 0xFF
            ser.write(bytes([ACK]))
            print(f"[ymodem] received {received}/{size} bytes")

    print(f"[ymodem] receive complete: {target}")
    return target


def default_ymodem_payload() -> tuple[str, bytes]:
    text = (
        "VScope Shell YMODEM sample\r\n"
        f"generated: {time.strftime('%Y-%m-%d %H:%M:%S')}\r\n"
        "This file was sent by test_tools/shell_device.py.\r\n"
        "Use it to verify Shell YMODEM receive without preparing a file.\r\n"
    )
    return "vscope_shell_ymodem_sample.txt", text.encode("utf-8")


def ymodem_send_bytes(ser, name: str, data: bytes) -> None:
    print(f"[ymodem] waiting for app receive request, file={name}, size={len(data)}")
    wait_for_byte(ser, CRC_REQUEST, "initial CRC request", timeout=60.0)

    ser.write(build_header_packet(name, len(data)))
    wait_for_byte(ser, ACK, "header ACK")
    wait_for_byte(ser, CRC_REQUEST, "data CRC request")

    block = 1
    offset = 0
    while offset < len(data):
        size = 1024 if len(data) - offset > 128 else 128
        chunk = bytearray([EOF] * size)
        end = min(offset + size, len(data))
        chunk[: end - offset] = data[offset:end]
        ser.write(build_packet(bytes(chunk), block))
        wait_for_byte(ser, ACK, f"block {block} ACK")
        offset = end
        block = (block + 1) & 0xFF
        print(f"[ymodem] sent {offset}/{len(data)} bytes")

    ser.write(bytes([EOT]))
    wait_for_byte(ser, NAK, "first EOT NAK")
    ser.write(bytes([EOT]))
    wait_for_byte(ser, ACK, "second EOT ACK")
    wait_for_byte(ser, CRC_REQUEST, "final header request")
    ser.write(build_header_packet("", 0))
    wait_for_byte(ser, ACK, "final header ACK")
    print("[ymodem] send complete")


def ymodem_send(ser, file_path: Path) -> None:
    ymodem_send_bytes(ser, file_path.name, file_path.read_bytes())


def terminal_loop(ser, args) -> None:
    prompt = b"\x1b[36mVScope shell device\x1b[0m> "
    intro = (
        b"\r\n\x1b[32mShell test device ready.\x1b[0m\r\n"
        b"Type help to list test commands.\r\n"
    )
    ser.write(intro + prompt)
    buffer = bytearray()
    ignore_lf_after_cr = False
    print("[terminal] started. Press Ctrl+C to stop.")
    while True:
        byte = ser.read(1)
        if not byte:
            continue
        value = byte[0]
        # CRLF is one line ending. The command is handled on CR, then the
        # immediately following LF is consumed instead of creating an empty command.
        if value == 0x0A and ignore_lf_after_cr:
            ignore_lf_after_cr = False
            continue
        ignore_lf_after_cr = value == 0x0D
        if value == 0x03:
            buffer.clear()
            ser.write(b"^C\r\n" + prompt)
            print("[terminal] ctrl-c")
        elif value in (0x0D, 0x0A):
            command = buffer.decode("utf-8", errors="replace").strip()
            buffer.clear()
            print(f"[terminal] command: {command!r}")
            lower = command.lower()
            if lower in ("help", "?"):
                ser.write(
                    b"\r\nCommands:\r\n"
                    b"  help   - show this command list\r\n"
                    b"  ping   - reply with pong\r\n"
                    b"  status - show fake device status\r\n"
                    b"  time   - show host timestamp\r\n"
                    b"  color  - render ANSI foreground/background colors\r\n"
                    b"  ansi   - render bold/underline/reverse styles\r\n"
                    b"  long   - send multiple lines for scroll testing\r\n"
                    b"  clear  - send ANSI clear screen\r\n"
                    b"  ysend  - send a YMODEM file to the app\r\n"
                    b"  yrecv  - receive a YMODEM file from the app\r\n"
                    b"  exit   - close this script\r\n"
                    + prompt
                )
                continue
            if lower == "ping":
                ser.write(b"\r\npong\r\n" + prompt)
                continue
            if lower == "status":
                ser.write(
                    b"\r\nstatus: ok\r\n"
                    b"mode: terminal\r\n"
                    b"ansi: enabled\r\n"
                    b"ymodem: use ysend/yrecv commands or ymodem modes\r\n"
                    + f"ymodem output: {args.output}\r\n".encode("utf-8")
                    + prompt
                )
                continue
            if lower == "ysend":
                try:
                    if args.file:
                        file_path = Path(args.file)
                        name = file_path.name
                        data = file_path.read_bytes()
                    else:
                        name, data = default_ymodem_payload()
                    ser.write(
                        b"\r\nStart app Shell receive now. "
                        b"Waiting for YMODEM request...\r\n"
                    )
                    ymodem_send_bytes(ser, name, data)
                    ser.write(b"\r\nYMODEM send complete.\r\n" + prompt)
                except (OSError, YmodemError) as error:
                    ser.write(f"\r\nYMODEM send failed: {error}\r\n".encode("utf-8"))
                    ser.write(prompt)
                    print(f"[ymodem] send failed: {error}", file=sys.stderr)
                continue
            if lower == "yrecv":
                try:
                    ser.write(
                        b"\r\nStart app Shell send now. "
                        b"Waiting for YMODEM file...\r\n"
                    )
                    target = ymodem_receive(ser, Path(args.output))
                    if target is None:
                        ser.write(b"\r\nYMODEM receive complete: empty batch\r\n")
                    else:
                        ser.write(
                            f"\r\nYMODEM receive complete: {target}\r\n".encode(
                                "utf-8"
                            )
                        )
                    ser.write(prompt)
                except (OSError, YmodemError) as error:
                    ser.write(
                        f"\r\nYMODEM receive failed: {error}\r\n".encode("utf-8")
                    )
                    ser.write(prompt)
                    print(f"[ymodem] receive failed: {error}", file=sys.stderr)
                continue
            if lower == "time":
                now = time.strftime("%Y-%m-%d %H:%M:%S")
                ser.write(f"\r\nhost time: {now}\r\n".encode("ascii") + prompt)
                continue
            if command.lower() == "exit":
                ser.write(b"\r\nbye\r\n")
                return
            if command.lower() == "clear":
                ser.write(b"\x1b[2J\x1b[H" + prompt)
                continue
            if command.lower() == "color":
                ser.write(
                    b"\r\n\x1b[31mred\x1b[0m "
                    b"\x1b[32mgreen\x1b[0m "
                    b"\x1b[34mblue\x1b[0m "
                    b"\x1b[7mreverse\x1b[0m\r\n"
                    + prompt
                )
                continue
            if lower == "ansi":
                ser.write(
                    b"\r\nnormal "
                    b"\x1b[1mbold\x1b[0m "
                    b"\x1b[4munderline\x1b[0m "
                    b"\x1b[7mreverse\x1b[0m "
                    b"\x1b[31;47mred on white\x1b[0m\r\n"
                    + prompt
                )
                continue
            if lower == "long":
                ser.write(b"\r\n")
                for index in range(1, 31):
                    ser.write(f"line {index:02d}: scroll test data\r\n".encode("ascii"))
                ser.write(prompt)
                continue
            response = f"\r\n\x1b[33mecho\x1b[0m: {command}\r\n".encode(
                "utf-8"
            )
            ser.write(response + prompt)
        elif value in (0x08, 0x7F):
            if buffer:
                buffer.pop()
                ser.write(b"\b \b")
        else:
            buffer.append(value)
            ser.write(byte)


def open_serial(args):
    return serial.Serial(
        port=args.port,
        baudrate=args.baud,
        bytesize=8,
        parity="N",
        stopbits=1,
        timeout=args.timeout,
        write_timeout=args.timeout,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Shell/YMODEM virtual serial device for VScope Serial"
    )
    parser.add_argument("--port", required=True, help="serial port, for example COM14")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=0.1)
    parser.add_argument(
        "--mode",
        choices=["terminal", "ymodem-send", "ymodem-receive"],
        default="terminal",
    )
    parser.add_argument("--file", help="file to send in ymodem-send mode")
    parser.add_argument(
        "--output",
        default=str(Path.cwd() / "ymodem_rx"),
        help="directory for ymodem-receive mode",
    )
    args = parser.parse_args()

    try:
        with open_serial(args) as ser:
            print(f"[serial] opened {args.port} @ {args.baud}")
            if args.mode == "terminal":
                terminal_loop(ser, args)
            elif args.mode == "ymodem-send":
                if not args.file:
                    raise SystemExit("--file is required for ymodem-send")
                ymodem_send(ser, Path(args.file))
            elif args.mode == "ymodem-receive":
                ymodem_receive(ser, Path(args.output))
    except KeyboardInterrupt:
        print("\n[stop] interrupted")
    except (serial.SerialException, OSError, YmodemError) as error:
        print(f"[error] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
