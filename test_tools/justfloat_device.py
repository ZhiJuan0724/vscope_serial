#!/usr/bin/env python3
"""
VOFA JustFloat 协议下位机模拟器

接收文本配置命令：
    r [通道1地址] [通道2地址] ...\\n

收到命令后按地址数量自动识别通道数，并周期性发送 JustFloat 帧：
    [float32 little-endian values...] + 00 00 80 7F

使用方法：
    python justfloat_device.py --port COM14 --baud 115200

依赖：
    pip install pyserial
"""

import argparse
import math
import queue
import random
import struct
import sys
import threading
import time
from typing import List, Optional

try:
    import msvcrt
except ImportError:
    msvcrt = None

try:
    import serial
except ImportError:
    print("错误: 需要安装 pyserial")
    print("  pip install pyserial")
    sys.exit(1)


JUSTFLOAT_TAIL = b"\x00\x00\x80\x7F"
MAX_CHANNEL_COUNT = 16


class HighPrecisionTimer:
    """Windows 高精度定时器，使用 busy-wait 实现亚毫秒精度。"""

    def __init__(self, interval_ms: float):
        self.interval_ms = interval_ms
        self.interval_sec = interval_ms / 1000.0
        self._last_time: Optional[float] = None
        self._send_count = 0
        self._last_report_time: Optional[float] = None

    def start(self):
        self._last_time = time.perf_counter()
        self._last_report_time = self._last_time
        self._send_count = 0

    def wait(self) -> float:
        if self._last_time is None:
            self.start()

        self._send_count += 1
        target_time = self._last_time + self.interval_sec
        while time.perf_counter() < target_time:
            pass

        now = time.perf_counter()
        actual_interval = (now - self._last_time) * 1000.0
        self._last_time = now

        if self._last_report_time is not None and now - self._last_report_time >= 1.0:
            elapsed = now - self._last_report_time
            rate = self._send_count / elapsed
            print(
                f"[统计] 发送速率: {rate:.1f} 帧/s | "
                f"目标: {1000.0 / self.interval_ms:.1f}Hz | "
                f"实际间隔: {actual_interval:.3f}ms"
            )
            self._send_count = 0
            self._last_report_time = now

        return actual_interval


class DataGenerator:
    """按通道地址生成 float32 测试数据。"""

    def __init__(self, mode: str = "sine", amplitude: float = 100.0):
        self.mode = mode
        self.amplitude = amplitude
        self._tick = 0
        self._addresses: List[int] = []
        self._phase: List[float] = []

    def set_channels(self, addresses: List[int]):
        self._addresses = list(addresses)
        self._phase = [
            i * math.pi / max(1, len(addresses)) for i in range(len(addresses))
        ]

    def _channel_baseline(self, index: int) -> float:
        address_hint = float(self._addresses[index] % 97)
        return (index + 1) * self.amplitude * 1.8 + address_hint

    def _channel_amplitude(self, index: int) -> float:
        return self.amplitude * (0.35 + index * 0.12)

    def next(self) -> List[float]:
        self._tick += 1
        t = self._tick * 0.01
        channel_count = len(self._addresses)

        if self.mode == "sine":
            return [
                self._channel_baseline(i)
                + self._channel_amplitude(i) * math.sin(t * (1 + i * 0.08) + self._phase[i])
                for i in range(channel_count)
            ]
        if self.mode == "random":
            return [
                self._channel_baseline(i)
                + random.uniform(-self._channel_amplitude(i), self._channel_amplitude(i))
                for i in range(channel_count)
            ]
        if self.mode == "ramp":
            return [
                self._channel_baseline(i)
                + float(
                    (self._tick * (i + 1) + i * 17)
                    % int(max(1.0, self._channel_amplitude(i) * 2))
                )
                for i in range(channel_count)
            ]
        return [
            self._channel_baseline(i) + self._tick * (i + 1) * 0.1
            for i in range(channel_count)
        ]


def parse_read_command(line: str) -> Optional[List[int]]:
    """解析 `r addr...` 命令，返回通道地址列表。"""
    parts = line.strip().split()
    if not parts or parts[0].lower() != "r":
        return None

    address_parts = parts[1:]
    if not address_parts:
        print("[设备] r 命令未包含通道地址")
        return None
    if len(address_parts) > MAX_CHANNEL_COUNT:
        print(f"[设备] 通道数量超过 {MAX_CHANNEL_COUNT}: {len(address_parts)}")
        return None

    addresses = []
    for raw in address_parts:
        try:
            addresses.append(int(raw, 0))
        except ValueError:
            print(f"[设备] 无效通道地址: {raw}")
            return None
    return addresses


def build_justfloat_frame(values: List[float]) -> bytes:
    payload = b"".join(struct.pack("<f", float(value)) for value in values)
    return payload + JUSTFLOAT_TAIL


class ConsoleCommandReader:
    """后台读取控制台命令，避免阻塞串口收发循环。"""

    def __init__(self):
        self._commands: queue.Queue[str] = queue.Queue()
        self._thread = threading.Thread(target=self._read_loop, daemon=True)

    def start(self):
        self._thread.start()

    def _read_loop(self):
        if msvcrt is not None:
            self._read_key_loop()
            return

        while True:
            line = sys.stdin.readline()
            if line == "":
                return
            command = line.strip().lower()
            if command:
                self._commands.put(command)

    def _read_key_loop(self):
        while True:
            if not msvcrt.kbhit():
                time.sleep(0.05)
                continue

            key = msvcrt.getwch()
            if key in ("\x00", "\xe0"):
                # Consume extended-key suffix.
                if msvcrt.kbhit():
                    msvcrt.getwch()
                continue

            command = key.strip().lower()
            if command:
                self._commands.put(command)

    def drain(self) -> List[str]:
        commands: List[str] = []
        while True:
            try:
                commands.append(self._commands.get_nowait())
            except queue.Empty:
                return commands


class JustFloatDevice:
    """JustFloat 协议下位机模拟器。"""

    def __init__(
        self,
        port: str,
        baudrate: int = 115200,
        data_mode: str = "sine",
        interval_ms: float = 1.0,
        amplitude: float = 100.0,
    ):
        self.port = port
        self.baudrate = baudrate
        self.interval_ms = interval_ms
        self.serial: Optional[serial.Serial] = None
        self.running = False
        self.configured = False
        self.paused = False
        self.channel_addresses: List[int] = []
        self.data_gen = DataGenerator(mode=data_mode, amplitude=amplitude)
        self.timer = HighPrecisionTimer(interval_ms)
        self.verbose = False

    def open(self) -> bool:
        try:
            self.serial = serial.Serial(
                port=self.port,
                baudrate=self.baudrate,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=0.1,
            )
            print(f"[设备] 串口已打开: {self.port} @ {self.baudrate}bps")
            return True
        except serial.SerialException as e:
            print(f"[错误] 无法打开串口 {self.port}: {e}")
            return False

    def close(self):
        self.running = False
        if self.serial and self.serial.is_open:
            self.serial.close()
            print("[设备] 串口已关闭")

    def _apply_read_command(self, line: str) -> bool:
        addresses = parse_read_command(line)
        if addresses is None:
            return False

        self.channel_addresses = addresses
        self.data_gen.set_channels(addresses)
        self.configured = True
        self.paused = False
        self.timer.start()
        print(
            f"[设备] 收到读取命令，通道数: {len(addresses)}，"
            f"地址: {[f'0x{addr:X}' for addr in addresses]}"
        )
        return True

    def _toggle_pause(self):
        if not self.configured:
            print("[控制] 当前未开始发送，等待读取命令")
            return
        if self.paused:
            self.paused = False
            self.timer.start()
            print("[控制] 已恢复发送")
            return
        self.paused = True
        print("[控制] 已暂停发送；再次输入 p 恢复，输入 r 复位，输入 c 关闭脚本")

    def _reset_to_waiting(self):
        self.configured = False
        self.paused = False
        self.channel_addresses = []
        self.data_gen.set_channels([])
        print("[控制] 已复位，等待读取命令: r [通道1地址] [通道2地址] ...")

    def _handle_console_commands(self, commands: List[str]) -> bool:
        """处理控制台命令。返回 True 表示需要清空串口输入缓冲。"""
        reset_requested = False
        for command in commands:
            if command == "p":
                self._toggle_pause()
            elif command == "r":
                self._reset_to_waiting()
                reset_requested = True
            elif command == "c":
                print("[控制] 收到关闭命令")
                self.running = False
            else:
                print(f"[控制] 未知命令: {command}，可用命令: p 暂停/恢复 / r 复位 / c 关闭")
        return reset_requested

    def _send_data_frame(self):
        if not self.serial or not self.serial.is_open or not self.configured:
            return

        values = self.data_gen.next()
        frame = build_justfloat_frame(values)
        self.serial.write(frame)
        self.serial.flush()

        if self.verbose:
            print(f"[设备] 发送 JustFloat: {[round(v, 4) for v in values]}")

    def run(self):
        if not self.open():
            return

        self.running = True
        buffer = bytearray()
        console = ConsoleCommandReader()
        console.start()

        print("[设备] 等待读取命令: r [通道1地址] [通道2地址] ...")
        print("[控制] 按 p 暂停/恢复发送，r 复位等待读取命令，c 关闭脚本；也可按 Ctrl+C 退出")

        try:
            while self.running:
                if self._handle_console_commands(console.drain()):
                    buffer.clear()
                    if self.serial:
                        self.serial.reset_input_buffer()
                if not self.running:
                    break

                if self.serial and self.serial.in_waiting > 0:
                    data = self.serial.read(self.serial.in_waiting)
                    buffer.extend(data)

                    while b"\n" in buffer:
                        line_bytes, _, rest = buffer.partition(b"\n")
                        buffer = bytearray(rest)
                        line = line_bytes.decode("ascii", errors="ignore")
                        if self._apply_read_command(line) and self.interval_ms < 5:
                            self.verbose = False
                            print(f"[设备] 发送间隔 {self.interval_ms}ms (<5ms)，关闭逐帧打印")

                if self.configured and not self.paused:
                    self._send_data_frame()
                    self.timer.wait()
                elif self.paused:
                    time.sleep(0.05)
                else:
                    time.sleep(0.01)
        except KeyboardInterrupt:
            print("\n[设备] 用户中断")
        finally:
            self.close()


def main():
    parser = argparse.ArgumentParser(
        description="VOFA JustFloat 协议下位机模拟器",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python justfloat_device.py --port COM14
  python justfloat_device.py --port COM14 --baud 115200 --mode sine --interval 1
  python justfloat_device.py --port COM14 --mode random --interval 10

上位机发送示例:
  r 0x01 0x02 0x03\\n
        """,
    )
    parser.add_argument("--port", "-p", required=True, help="串口号 (如 COM14)")
    parser.add_argument("--baud", "-b", type=int, default=115200, help="波特率 (默认115200)")
    parser.add_argument(
        "--mode",
        "-m",
        choices=["sine", "random", "ramp", "fixed"],
        default="sine",
        help="数据模式 (默认sine)",
    )
    parser.add_argument(
        "--interval",
        "-i",
        type=float,
        default=1.0,
        help="发送间隔毫秒 (默认1ms = 1000Hz)",
    )
    parser.add_argument("--amplitude", "-a", type=float, default=100.0, help="数据幅度 (默认100)")

    args = parser.parse_args()

    print("=" * 50)
    print("VOFA JustFloat 协议下位机模拟器")
    print("=" * 50)
    print(f"串口: {args.port}")
    print(f"波特率: {args.baud}")
    print(f"数据模式: {args.mode}")
    print(f"发送间隔: {args.interval}ms ({1000.0 / args.interval:.0f}Hz)")
    print("=" * 50)

    device = JustFloatDevice(
        port=args.port,
        baudrate=args.baud,
        data_mode=args.mode,
        interval_ms=args.interval,
        amplitude=args.amplitude,
    )
    device.run()


if __name__ == "__main__":
    main()
