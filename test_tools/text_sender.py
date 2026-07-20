#!/usr/bin/env python3
"""多编码文本发送工具，用于验证原始收发的流式解码与自动换行。"""
"""
多编码文本发送器

通过串口以指定编码周期发送文本数据，用于验证 VScope Serial
数据收发页面的解码方式切换功能。

支持编码:
    UTF-8, GBK, BIG5, Shift_JIS, EUC-KR, Latin-1, ASCII

文本模式:
    plain   — 每次发送一行固定文本
    line    — 逐行发送递增编号和时间戳
    mixed   — 中英日韩等多语言混排文本
    echo    — 收到串口数据后原样回复（无数据时发心跳）

使用方法:
    python text_sender.py --port COM14
    python text_sender.py --port COM14 --encoding GBK --mode mixed --interval 100
    python text_sender.py --port COM14 --encoding Shift_JIS --mode line --interval 500

依赖:
    pip install pyserial
"""

import argparse
import math
import queue
import sys
import threading
import time
from datetime import datetime
from typing import Dict, List, Optional

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


# ========== 编码映射 ==========

# Python codec name → 显示名
ENCODINGS: Dict[str, str] = {
    "UTF-8": "utf-8",
    "GBK": "gbk",
    "BIG5": "big5",
    "Shift_JIS": "shift_jis",
    "EUC-KR": "euc_kr",
    "Latin-1": "latin-1",
    "ASCII": "ascii",
}


def get_codec(name: str) -> str:
    """将 --encoding 参数名映射为 Python 内置 codec 名。"""
    return ENCODINGS.get(name, "utf-8")


# ========== 文本内容生成器 ==========

def _fmt_now() -> str:
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]


def _emoji(name: str) -> str:
    """返回与编码对应的示意文本（用于 mixed 模式）。"""
    return {
        "UTF-8": "Hello世界😀",
        "GBK": "你好，世界！",
        "BIG5": "繁體中文測試",
        "Shift_JIS": "こんにちは世界",
        "EUC-KR": "안녕하세요",
        "Latin-1": "Bonjour le monde",
        "ASCII": "Hello, world!",
    }.get(name, "Hello, world!")


class TextGenerator:
    """按模式生成要发送的文本行。"""

    def __init__(self, encoding_display: str, mode: str = "mixed"):
        self._encoding_display = encoding_display
        self._mode = mode
        self._counter = 0

    def set_mode(self, mode: str):
        self._mode = mode

    def next(self) -> str:
        """
        返回一行待发送文本。

        plain 模式使用大块固定文本，方便在接收区观察解码效果。
        """
        self._counter += 1
        n = self._counter
        now = _fmt_now()

        if self._mode == "plain":
            return (
                f"[{now} #%04d] VScope Serial 编码测试 | "
                f"编码:{self._encoding_display} | "
                f"0123456789 | "
                f"{_emoji(self._encoding_display)}"
            ) % n

        if self._mode == "line":
            return f"[#{n}] 行号: {n:06d} | 时间: {now} | 编码: {self._encoding_display}"

        if self._mode == "mixed":
            samples = [
                f"[{n}] 你好世界 | こんにちは | 안녕하세요",
                f"[{n}] Test 12345 | 測試資料 | テストデータ",
                f"[{n}] A=%.4f B=%.4f C=%.4f D=%.4f" % (
                    math.sin(n * 0.1) * 100,
                    math.cos(n * 0.1) * 100,
                    math.sin(n * 0.2) * 50,
                    math.cos(n * 0.2) * 50,
                ),
                f"[{n}] ---- 分隔线 ---- vscope",
                f"[{n}] 通道值: %.1f %.1f %.1f %.1f" % (
                    math.sin(n * 0.05) * 200 + 200,
                    math.cos(n * 0.05) * 200 + 200,
                    math.sin(n * 0.07 + 1) * 150 + 150,
                    math.cos(n * 0.07 + 1) * 150 + 150,
                ),
                f"[{n}] VScope 串口波形工具 | {_fmt_now()}",
                f"[{n}] 串口接收测试 | Serial Test",
                f"[{n}] 传感器数据 — 温度:%.2f°C 湿度:%.1f%% 气压:%.1fhPa" % (
                    20 + math.sin(n * 0.03) * 5,
                    50 + math.cos(n * 0.03) * 10,
                    1013 + math.sin(n * 0.05) * 3,
                ),
            ]
            return samples[(n - 1) % len(samples)]

        if self._mode == "echo":
            # echo 模式由主循环处理，此处返回空闲心跳
            return f"[{now}] idle"

        return f"[{n}] {_fmt_now()}"


# ========== 高精度定时器 ==========

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

    def set_interval(self, interval_ms: float):
        self.interval_ms = interval_ms
        self.interval_sec = interval_ms / 1000.0

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
                f"[统计] 发送速率: {rate:.1f} 行/s | "
                f"目标: {1000.0 / self.interval_ms:.1f}Hz | "
                f"实际间隔: {actual_interval:.3f}ms"
            )
            self._send_count = 0
            self._last_report_time = now

        return actual_interval


# ========== 控制台命令读取 ==========

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


# ========== 文本发送器 ==========

class TextSender:
    """多编码文本串口发送器。"""

    ENCODING_LIST = list(ENCODINGS.keys())

    def __init__(
        self,
        port: str,
        baudrate: int = 115200,
        encoding: str = "UTF-8",
        text_mode: str = "mixed",
        interval_ms: float = 100.0,
        add_line_ending: bool = True,
        line_ending: str = "\r\n",
    ):
        self.port = port
        self.baudrate = baudrate
        self.encoding_display = encoding
        self.codec = get_codec(encoding)
        self.text_mode = text_mode
        self.interval_ms = interval_ms
        self.add_line_ending = add_line_ending
        self.line_ending = line_ending

        self.serial: Optional[serial.Serial] = None
        self.running = False
        self.paused = False
        self.pending_encoding = encoding
        self.encoding_index = self.ENCODING_LIST.index(encoding)

        self.generator = TextGenerator(encoding, mode=text_mode)
        self.timer = HighPrecisionTimer(interval_ms)

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

    def _apply_encoding(self):
        """切换编码并通知用户。"""
        self.encoding_display = self.pending_encoding
        self.codec = get_codec(self.encoding_display)
        self.generator = TextGenerator(self.encoding_display, mode=self.text_mode)
        print(
            f"[编码] 切换为 {self.encoding_display} "
            f"(Python codec: {self.codec})"
        )

    def _cycle_encoding(self):
        """轮换到下一个编码。"""
        self.encoding_index = (self.encoding_index + 1) % len(self.ENCODING_LIST)
        self.pending_encoding = self.ENCODING_LIST[self.encoding_index]
        self._apply_encoding()

    def _toggle_pause(self):
        if self.paused:
            self.paused = False
            self.timer.start()
            print("[控制] 已恢复发送")
        else:
            self.paused = True
            print(
                "[控制] 已暂停发送；再次输入 p 恢复，e 切换编码，"
                "c 关闭脚本"
            )

    def _handle_console_commands(self, commands: List[str]) -> bool:
        """处理控制台命令。"""
        for command in commands:
            if command == "p":
                self._toggle_pause()
            elif command == "e":
                self._cycle_encoding()
            elif command == "c":
                print("[控制] 收到关闭命令")
                self.running = False
            elif command in ("1", "2", "3", "4", "5", "6", "7"):
                idx = int(command) - 1
                self.encoding_index = idx
                self.pending_encoding = self.ENCODING_LIST[idx]
                self._apply_encoding()
            elif command == "?":
                self._print_help()
            else:
                print(
                    f"[控制] 未知命令: {command}，"
                    f"可用: p 暂停/恢复 | e 轮换编码 | 1-7 选择编码 | c 关闭"
                )
        return False

    def _send_line(self, text: str):
        """以指定编码发送一行文本。"""
        if not self.serial or not self.serial.is_open:
            return

        try:
            payload = text
            if self.add_line_ending:
                payload = text + self.line_ending

            data = payload.encode(self.codec, errors="replace")
            self.serial.write(data)
            self.serial.flush()
        except (UnicodeEncodeError, ValueError) as e:
            print(f"[错误] 编码失败 ({self.codec}): {e}")

    def _print_help(self):
        enc_list = ", ".join(
            f"{i + 1}={e}" for i, e in enumerate(self.ENCODING_LIST)
        )
        print(f"[帮助] 编码: {enc_list}")
        print("[帮助] 按键: p=暂停  e=轮换编码  1-7=选编码  c=关闭")

    def run(self):
        if not self.open():
            return

        self.running = True
        console = ConsoleCommandReader()
        console.start()

        print("=" * 50)
        print("多编码文本发送器")
        print("=" * 50)
        print(f"串口: {self.port}  @ {self.baudrate}bps")
        print(f"编码: {self.encoding_display}")
        print(f"模式: {self.text_mode}")
        print(f"间隔: {self.interval_ms}ms")
        print("=" * 50)
        self._print_help()
        print("按 Ctrl+C 退出")

        try:
            while self.running:
                self._handle_console_commands(console.drain())
                if not self.running:
                    break

                # echo 模式：读取串口并回复
                if self.text_mode == "echo":
                    if (
                        self.serial
                        and self.serial.is_open
                        and self.serial.in_waiting > 0
                    ):
                        data = self.serial.read(self.serial.in_waiting)
                        if data:
                            print(
                                f"[接收] {len(data)} bytes: "
                                f"{data[:64].hex(' ')}{'...' if len(data) > 64 else ''}"
                            )
                            # 原样回复
                            self.serial.write(data)
                            self.serial.flush()
                    elif not self.paused:
                        # 空闲心跳
                        if self._counter_reached():
                            self._send_line(self.generator.next())
                    if not self.paused:
                        time.sleep(self.interval_ms / 1000.0)
                    continue

                if not self.paused:
                    self._send_line(self.generator.next())
                    self.timer.wait()
                else:
                    time.sleep(0.05)

        except KeyboardInterrupt:
            print("\n[设备] 用户中断")
        finally:
            self.close()

    def _counter_reached(self):
        """简易心跳节流。"""
        return (self.generator._counter % max(1, int(1000 / max(1, self.interval_ms)))) == 0


# ========== 主入口 ==========

def main():
    parser = argparse.ArgumentParser(
        description="多编码文本串口发送器 — 用于验证 VScope Serial 解码功能",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python text_sender.py --port COM14
  python text_sender.py --port COM14 --encoding GBK --mode mixed --interval 100
  python text_sender.py --port COM14 --encoding Shift_JIS --mode line --interval 500
  python text_sender.py --port COM14 --encoding BIG5 --mode plain

编码说明:
  UTF-8     — 国际通用编码（默认）
  GBK       — 简体中文
  BIG5      — 繁体中文
  Shift_JIS — 日文
  EUC-KR    — 韩文
  Latin-1   — 西欧语言
  ASCII     — 纯英文字符

运行中按键:
  p — 暂停 / 恢复发送
  e — 轮换编码
  1-7 — 直接切换编码 (1=UTF-8, 2=GBK, ...)
  c — 关闭
  Ctrl+C — 退出
        """,
    )
    parser.add_argument(
        "--port", "-p", required=True, help="串口号 (如 COM14)"
    )
    parser.add_argument(
        "--baud", "-b", type=int, default=115200, help="波特率 (默认 115200)"
    )
    parser.add_argument(
        "--encoding",
        "-e",
        choices=list(ENCODINGS.keys()),
        default="UTF-8",
        help="文本编码 (默认 UTF-8)",
    )
    parser.add_argument(
        "--mode",
        "-m",
        choices=["plain", "line", "mixed", "echo"],
        default="mixed",
        help="文本模式: plain=固定文本 line=行号 mixed=多语言混排 echo=串口回显 (默认 mixed)",
    )
    parser.add_argument(
        "--interval",
        "-i",
        type=float,
        default=100.0,
        help="发送间隔毫秒 (默认 100ms = 10行/s)",
    )
    parser.add_argument(
        "--no-line-ending",
        action="store_true",
        help="不自动添加行尾换行符",
    )
    parser.add_argument(
        "--line-ending",
        choices=["crlf", "lf", "cr"],
        default="crlf",
        help="行尾换行符: crlf=\\r\\n  lf=\\n  cr=\\r (默认 crlf)",
    )

    args = parser.parse_args()

    le_map = {"crlf": "\r\n", "lf": "\n", "cr": "\r"}

    sender = TextSender(
        port=args.port,
        baudrate=args.baud,
        encoding=args.encoding,
        text_mode=args.mode,
        interval_ms=args.interval,
        add_line_ending=not args.no_line_ending,
        line_ending=le_map[args.line_ending],
    )
    sender.run()


if __name__ == "__main__":
    main()
