#!/usr/bin/env python3
"""
众邦电控协议下位机模拟器

模拟一个众邦电控设备的行为：
- 监听串口，接收18字节配置帧（4个uint32通道号 + CRC16）
- 收到配置后，开始周期性发送10字节数据帧（4通道数据 + CRC16）
- 支持随机数据或正弦波数据

使用方法：
    python zobow_device.py --port COM14 --baud 921600
    python zobow_device.py --port COM14 --rate 4000 --baud 2000000
    python zobow_device.py --port COM14 --preset 8k --baud 3000000

依赖：
    pip install pyserial
"""

import argparse
import math
import queue
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


# ========== CRC16/MODBUS 计算 ==========

def crc16_modbus(data: bytes) -> int:
    """计算 CRC16/MODBUS 校验值
    
    与 Dart 端的 calculateCrc(data, crc16Polys['CRC-16/MODBUS']) 对应。
    """
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc


def build_frame(data_bytes: bytes) -> bytes:
    """构造完整帧：数据区 + CRC16（小端序）"""
    crc = crc16_modbus(data_bytes)
    return data_bytes + struct.pack('<H', crc)


# ========== 高精度定时器 ==========

class HighPrecisionTimer:
    """Windows高精度定时器，使用busy-wait实现亚毫秒精度"""
    
    def __init__(self, interval_ms: float):
        self.interval_ms = interval_ms
        self.interval_sec = interval_ms / 1000.0
        self._last_time = None
        self._send_count = 0
        self._last_report_time = None
    
    def start(self):
        """开始计时"""
        self._last_time = time.perf_counter()
        self._last_report_time = self._last_time
        self._send_count = 0
    
    def wait(self, frame_count: int = 1) -> float:
        """
        等待到下一个发送时刻，返回实际间隔(ms)
        使用busy-wait实现高精度定时
        """
        self._send_count += frame_count
        
        # 计算下一个目标时间
        target_time = self._last_time + self.interval_sec * frame_count
        
        # busy-wait直到目标时间（精度约0.1ms）
        while time.perf_counter() < target_time:
            pass
        
        now = time.perf_counter()
        actual_interval = (now - self._last_time) * 1000.0  # ms
        self._last_time = now
        
        # 每秒报告一次发送速率
        if now - self._last_report_time >= 1.0:
            elapsed = now - self._last_report_time
            rate = self._send_count / elapsed
            print(f"[统计] 发送速率: {rate:.1f} 帧/s | 目标: {1000.0/self.interval_ms:.1f}Hz | "
                  f"批量: {frame_count} 帧 | 实际批量间隔: {actual_interval:.3f}ms")
            self._send_count = 0
            self._last_report_time = now
        
        return actual_interval
    
    def set_interval(self, interval_ms: float):
        """动态修改发送间隔"""
        self.interval_ms = interval_ms
        self.interval_sec = interval_ms / 1000.0


# ========== 数据生成器 ==========

class DataGenerator:
    """生成4通道模拟数据"""
    
    def __init__(self, mode: str = 'sine', amplitude: int = 10000, channel_count: int = 4):
        self.mode = mode
        self.amplitude = amplitude
        self._tick = 0
        self.channel_count = channel_count
        self._update_phase()

    def set_channel_count(self, channel_count: int):
        self.channel_count = channel_count
        self._update_phase()

    def _update_phase(self):
        self._phase = [i * math.pi / 4 for i in range(self.channel_count)]
    
    def next(self) -> List[int]:
        """生成下一组4通道数据"""
        self._tick += 1
        # Slower sine sweep: 0.01 rad/sample gives a ~628-sample period.
        # At the default 1kHz send rate this is about 0.63s per cycle.
        t = self._tick * 0.01
        
        if self.mode == 'sine':
            # 正弦波，不同相位
            values = [
                int(self.amplitude * (1 + math.sin(t + self._phase[i]))) 
                for i in range(self.channel_count)
            ]
        elif self.mode == 'random':
            # 随机数据
            import random
            values = [random.randint(0, self.amplitude * 2) for _ in range(self.channel_count)]
        elif self.mode == 'ramp':
            # 锯齿波
            values = [
                int((self._tick * 100 + i * 500) % (self.amplitude * 2))
                for i in range(self.channel_count)
            ]
        else:
            # 固定递增
            values = [
                int((self._tick * 10 + i * 1000) % 65536)
                for i in range(self.channel_count)
            ]
        
        return values


# ========== 众邦电控设备模拟器 ==========

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


class ZobowDevice:
    """众邦电控协议下位机模拟器"""
    
    def __init__(
        self,
        port: str,
        baudrate: int = 115200,
        data_mode: str = 'sine',
        interval_ms: float = 50.0,
        batch_ms: float = 1.0,
        flush_every_batch: bool = False,
    ):
        self.port = port
        self.baudrate = baudrate
        self.data_mode = data_mode
        self.interval_ms = interval_ms
        self.batch_ms = batch_ms
        self.flush_every_batch = flush_every_batch
        
        self.serial: Optional[serial.Serial] = None
        self.channel_count = 4
        self.channel_ids = [0x0001, 0x0002, 0x0003, 0x0004]
        self.configured = False
        self.paused = False
        self.running = False
        self.data_gen = DataGenerator(mode=data_mode, channel_count=self.channel_count)
        self.timer = HighPrecisionTimer(interval_ms)
        self.verbose = False  # 是否打印每帧数据（高频率时关闭）
        self.frames_per_batch = self._calculate_frames_per_batch()

    def _calculate_frames_per_batch(self) -> int:
        """根据发送间隔计算每次串口写入的帧数，降低高频测试时的 Python 调用开销。"""
        if self.interval_ms <= 0 or self.batch_ms <= 0:
            return 1
        return max(1, int(round(self.batch_ms / self.interval_ms)))

    def _estimated_wire_baud(self) -> int:
        """估算 8N1 串口承载当前目标速率所需的最低波特率。"""
        payload_bytes = self.channel_count * 2 + 2
        target_rate_hz = 1000.0 / self.interval_ms
        return math.ceil(payload_bytes * target_rate_hz * 10)

    def _print_throughput_hint(self):
        required_baud = self._estimated_wire_baud()
        target_rate_hz = 1000.0 / self.interval_ms
        print(
            f"[设备] 目标速率: {target_rate_hz:.0f}Hz | "
            f"每帧: {self.channel_count * 2 + 2} bytes | "
            f"批量写入: {self.frames_per_batch} 帧/次"
        )
        if self.baudrate < required_baud:
            print(
                f"[警告] 当前波特率 {self.baudrate}bps 可能不足。"
                f"{self.channel_count}通道 {target_rate_hz:.0f}Hz 约需 >= {required_baud}bps"
            )

    def open(self) -> bool:
        """打开串口"""
        try:
            self.serial = serial.Serial(
                port=self.port,
                baudrate=self.baudrate,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=0.1,  # 非阻塞读取
            )
            print(f"[设备] 串口已打开: {self.port} @ {self.baudrate}bps")
            return True
        except serial.SerialException as e:
            print(f"[错误] 无法打开串口 {self.port}: {e}")
            return False
    
    def close(self):
        """关闭串口"""
        self.running = False
        if self.serial and self.serial.is_open:
            self.serial.close()
            print("[设备] 串口已关闭")
    
    def _parse_config_frame(self, data: bytes) -> bool:
        """解析配置帧，验证CRC
        
        配置帧格式：
        4个uint32 little-endian通道号 + 2字节CRC16/MODBUS little-endian
        """
        if len(data) not in (18, 34):
            return False

        payload_length = len(data) - 2
        channel_count = payload_length // 4
        
        # 验证CRC
        received_crc = struct.unpack('<H', data[payload_length:payload_length + 2])[0]
        calculated_crc = crc16_modbus(data[0:payload_length])
        
        if received_crc != calculated_crc:
            print(f"[设备] 配置帧CRC错误: received=0x{received_crc:04X}, calculated=0x{calculated_crc:04X}")
            return False
        
        # 提取通道号
        self.channel_count = channel_count
        self.channel_ids = [
            struct.unpack('<I', data[i * 4:(i + 1) * 4])[0]
            for i in range(channel_count)
        ]
        self.data_gen.set_channel_count(channel_count)
        
        print(f"[设备] 收到配置帧，通道号: {[f'0x{id:08X}' for id in self.channel_ids]}")
        return True

    def _toggle_pause(self):
        if not self.configured:
            print("[控制] 当前未开始发送，等待配置帧")
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
        print("[控制] 已复位，等待配置帧...")

    def _handle_console_commands(self, commands: List[str]) -> bool:
        """处理控制台命令。返回 True 表示需要清空串口输入缓冲。"""
        reset_requested = False
        for command in commands:
            if command == 'p':
                self._toggle_pause()
            elif command == 'r':
                self._reset_to_waiting()
                reset_requested = True
            elif command == 'c':
                print("[控制] 收到关闭命令")
                self.running = False
            else:
                print(f"[控制] 未知命令: {command}，可用命令: p 暂停/恢复 / r 复位 / c 关闭")
        return reset_requested
    
    def _build_data_frame(self) -> bytes:
        """构造一帧数据。"""
        values = self.data_gen.next()

        # 构造数据区（4个uint16小端序）
        data_bytes = b''.join(struct.pack('<H', v & 0xFFFF) for v in values)

        # 添加CRC
        frame = build_frame(data_bytes)

        if self.verbose:
            crc_offset = len(values) * 2
            print(f"[设备] 发送数据: {[f'0x{v:04X}' for v in values]} | CRC=0x{struct.unpack('<H', frame[crc_offset:crc_offset + 2])[0]:04X}")

        return frame

    def _send_data_frames(self, frame_count: int):
        """发送一批数据帧。高频测试时批量写入可显著降低 Python/串口调用开销。"""
        if not self.serial or not self.serial.is_open:
            return

        batch = b''.join(self._build_data_frame() for _ in range(max(1, frame_count)))
        self.serial.write(batch)
        if self.flush_every_batch:
            self.serial.flush()
    
    def run(self):
        """主循环：接收配置 → 发送数据"""
        if not self.open():
            return
        
        self.running = True
        buffer = bytearray()
        console = ConsoleCommandReader()
        console.start()
        
        print("[设备] 等待配置帧...")
        print("[控制] 按 p 暂停/恢复发送，r 复位等待配置，c 关闭脚本；也可按 Ctrl+C 退出")
        
        try:
            while self.running:
                if self._handle_console_commands(console.drain()):
                    buffer.clear()
                    if self.serial:
                        self.serial.reset_input_buffer()
                if not self.running:
                    break

                # 读取串口数据
                if self.serial.in_waiting > 0:
                    data = self.serial.read(self.serial.in_waiting)
                    buffer.extend(data)
                    
                    # 尝试解析配置帧
                    while len(buffer) >= 18:
                        frame_length = 0
                        if len(buffer) >= 34 and self._parse_config_frame(bytes(buffer[:34])):
                            frame_length = 34
                        elif self._parse_config_frame(bytes(buffer[:18])):
                            frame_length = 18

                        if frame_length > 0:
                            self.configured = True
                            self.paused = False
                            buffer = buffer[frame_length:]
                            print("[设备] 配置完成，开始发送数据...")
                            self.frames_per_batch = self._calculate_frames_per_batch()
                            self._print_throughput_hint()
                            # 高频率时关闭逐帧打印
                            if self.interval_ms < 5:
                                self.verbose = False
                                print(f"[设备] 发送间隔 {self.interval_ms}ms (<5ms)，关闭逐帧打印")
                            self.timer.start()
                            break
                        elif len(buffer) < 34:
                            break
                        else:
                            # CRC失败，滑动窗口
                            buffer.pop(0)
                
                # 如果已配置，周期性发送数据
                if self.configured and not self.paused:
                    self._send_data_frames(self.frames_per_batch)
                    self.timer.wait(self.frames_per_batch)
                elif self.paused:
                    time.sleep(0.05)
                else:
                    time.sleep(0.01)  # 10ms轮询
                    
        except KeyboardInterrupt:
            print("\n[设备] 用户中断")
        finally:
            self.close()


# ========== 主入口 ==========

RATE_PRESETS = {
    '1k': 1000.0,
    '4k': 4000.0,
    '8k': 8000.0,
}


def resolve_interval_ms(interval_ms: float, rate_hz: Optional[float], preset: Optional[str]) -> float:
    """按 preset > rate > interval 的优先级计算发送间隔。"""
    if preset:
        return 1000.0 / RATE_PRESETS[preset]
    if rate_hz is not None:
        if rate_hz <= 0:
            raise ValueError('--rate 必须大于 0')
        return 1000.0 / rate_hz
    if interval_ms <= 0:
        raise ValueError('--interval 必须大于 0')
    return interval_ms

def main():
    parser = argparse.ArgumentParser(
        description='众邦电控协议下位机模拟器',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python zobow_device.py --port COM14
  python zobow_device.py --port COM14 --baud 921600 --mode sine --interval 1
  python zobow_device.py --port COM14 --mode random --preset 4k --baud 2000000
  python zobow_device.py --port COM14 --mode ramp --preset 8k --baud 3000000
        """
    )
    parser.add_argument('--port', '-p', required=True, help='串口号 (如 COM14)')
    parser.add_argument('--baud', '-b', type=int, default=115200, help='波特率 (默认115200)')
    parser.add_argument('--mode', '-m', choices=['sine', 'random', 'ramp', 'fixed'], 
                        default='sine', help='数据模式 (默认sine)')
    parser.add_argument('--interval', '-i', type=float, default=1.0, 
                        help='发送间隔毫秒 (默认1ms = 1000Hz；会被 --rate 或 --preset 覆盖)')
    parser.add_argument('--rate', '-r', type=float,
                        help='目标发送频率Hz，例如 4000 或 8000；优先级高于 --interval')
    parser.add_argument('--preset', choices=sorted(RATE_PRESETS.keys()),
                        help='常用发送频率预设：1k、4k、8k；优先级最高')
    parser.add_argument('--batch-ms', type=float, default=1.0,
                        help='批量写入窗口毫秒，高频默认每约1ms写入一批 (默认1.0)')
    parser.add_argument('--flush-every-batch', action='store_true',
                        help='每批写入后调用 serial.flush()；更贴近阻塞串口但高频下可能明显降速')
    parser.add_argument('--amplitude', '-a', type=int, default=10000,
                        help='数据幅度 (默认10000)')
    
    args = parser.parse_args()
    try:
        interval_ms = resolve_interval_ms(args.interval, args.rate, args.preset)
    except ValueError as e:
        parser.error(str(e))
    
    print("=" * 50)
    print("众邦电控协议下位机模拟器")
    print("=" * 50)
    print(f"串口: {args.port}")
    print(f"波特率: {args.baud}")
    print(f"数据模式: {args.mode}")
    print(f"发送间隔: {interval_ms:.6g}ms ({1000.0/interval_ms:.0f}Hz)")
    print(f"批量窗口: {args.batch_ms}ms")
    print("=" * 50)
    
    device = ZobowDevice(
        port=args.port,
        baudrate=args.baud,
        data_mode=args.mode,
        interval_ms=interval_ms,
        batch_ms=args.batch_ms,
        flush_every_batch=args.flush_every_batch,
    )
    device.data_gen.amplitude = args.amplitude
    
    device.run()


if __name__ == '__main__':
    main()
