#!/usr/bin/env python3
"""
JACK四通道协议下位机模拟器

模拟一个JACK四通道设备的行为：
- 监听串口，接收10字节配置帧（4通道号 + CRC16）
- 收到配置后，开始周期性发送10字节数据帧（4通道数据 + CRC16）
- 支持随机数据或正弦波数据

使用方法：
    python jack_four_channel_device.py --port COM14 --baud 115200

依赖：
    pip install pyserial
"""

import argparse
import math
import struct
import sys
import time
from typing import List, Optional

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


# ========== 数据生成器 ==========

class DataGenerator:
    """生成4通道模拟数据"""
    
    def __init__(self, mode: str = 'sine', amplitude: int = 10000):
        self.mode = mode
        self.amplitude = amplitude
        self._tick = 0
        self._phase = [0.0, math.pi / 4, math.pi / 2, 3 * math.pi / 4]
    
    def next(self) -> List[int]:
        """生成下一组4通道数据"""
        self._tick += 1
        t = self._tick * 0.1
        
        if self.mode == 'sine':
            # 正弦波，不同相位
            values = [
                int(self.amplitude * (1 + math.sin(t + self._phase[i]))) 
                for i in range(4)
            ]
        elif self.mode == 'random':
            # 随机数据
            import random
            values = [random.randint(0, self.amplitude * 2) for _ in range(4)]
        elif self.mode == 'ramp':
            # 锯齿波
            values = [
                int((self._tick * 100 + i * 500) % (self.amplitude * 2))
                for i in range(4)
            ]
        else:
            # 固定递增
            values = [
                int((self._tick * 10 + i * 1000) % 65536)
                for i in range(4)
            ]
        
        return values


# ========== JACK四通道设备模拟器 ==========

class JackFourChannelDevice:
    """JACK四通道协议下位机模拟器"""
    
    def __init__(
        self,
        port: str,
        baudrate: int = 115200,
        data_mode: str = 'sine',
        interval_ms: float = 50.0,
    ):
        self.port = port
        self.baudrate = baudrate
        self.data_mode = data_mode
        self.interval_ms = interval_ms
        
        self.serial: Optional[serial.Serial] = None
        self.channel_ids = [0x0001, 0x0002, 0x0003, 0x0004]
        self.configured = False
        self.running = False
        self.data_gen = DataGenerator(mode=data_mode)
    
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
        [Ch0_ID_Low][Ch0_ID_High][Ch1_ID_Low][Ch1_ID_High][Ch2_ID_Low][Ch2_ID_High][Ch3_ID_Low][Ch3_ID_High][CRC_Low][CRC_High]
        """
        if len(data) != 10:
            return False
        
        # 验证CRC
        received_crc = struct.unpack('<H', data[8:10])[0]
        calculated_crc = crc16_modbus(data[0:8])
        
        if received_crc != calculated_crc:
            print(f"[设备] 配置帧CRC错误: received=0x{received_crc:04X}, calculated=0x{calculated_crc:04X}")
            return False
        
        # 提取通道号
        self.channel_ids = [
            struct.unpack('<H', data[0:2])[0],
            struct.unpack('<H', data[2:4])[0],
            struct.unpack('<H', data[4:6])[0],
            struct.unpack('<H', data[6:8])[0],
        ]
        
        print(f"[设备] 收到配置帧，通道号: {[f'0x{id:04X}' for id in self.channel_ids]}")
        return True
    
    def _send_data_frame(self):
        """发送一帧数据"""
        if not self.serial or not self.serial.is_open:
            return
        
        values = self.data_gen.next()
        
        # 构造数据区（4个uint16小端序）
        data_bytes = b''.join(struct.pack('<H', v & 0xFFFF) for v in values)
        
        # 添加CRC
        frame = build_frame(data_bytes)
        
        self.serial.write(frame)
        self.serial.flush()
        
        print(f"[设备] 发送数据: {[f'0x{v:04X}' for v in values]} | CRC=0x{struct.unpack('<H', frame[8:10])[0]:04X}")
    
    def run(self):
        """主循环：接收配置 → 发送数据"""
        if not self.open():
            return
        
        self.running = True
        buffer = bytearray()
        
        print("[设备] 等待配置帧...")
        print("[设备] 按 Ctrl+C 退出")
        
        try:
            while self.running:
                # 读取串口数据
                if self.serial.in_waiting > 0:
                    data = self.serial.read(self.serial.in_waiting)
                    buffer.extend(data)
                    
                    # 尝试解析配置帧
                    while len(buffer) >= 10:
                        if self._parse_config_frame(bytes(buffer[:10])):
                            self.configured = True
                            buffer = buffer[10:]
                            print("[设备] 配置完成，开始发送数据...")
                            break
                        else:
                            # CRC失败，滑动窗口
                            buffer.pop(0)
                
                # 如果已配置，周期性发送数据
                if self.configured:
                    self._send_data_frame()
                    time.sleep(self.interval_ms / 1000.0)
                else:
                    time.sleep(0.01)  # 10ms轮询
                    
        except KeyboardInterrupt:
            print("\n[设备] 用户中断")
        finally:
            self.close()


# ========== 主入口 ==========

def main():
    parser = argparse.ArgumentParser(
        description='JACK四通道协议下位机模拟器',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python jack_four_channel_device.py --port COM14
  python jack_four_channel_device.py --port COM14 --baud 115200 --mode sine --interval 1
  python jack_four_channel_device.py --port COM14 --mode random --interval 1
        """
    )
    parser.add_argument('--port', '-p', required=True, help='串口号 (如 COM14)')
    parser.add_argument('--baud', '-b', type=int, default=115200, help='波特率 (默认115200)')
    parser.add_argument('--mode', '-m', choices=['sine', 'random', 'ramp', 'fixed'], 
                        default='sine', help='数据模式 (默认sine)')
    parser.add_argument('--interval', '-i', type=float, default=1.0, 
                        help='发送间隔毫秒 (默认1ms = 1000Hz)')
    parser.add_argument('--amplitude', '-a', type=int, default=10000,
                        help='数据幅度 (默认10000)')
    
    args = parser.parse_args()
    
    print("=" * 50)
    print("JACK四通道协议下位机模拟器")
    print("=" * 50)
    print(f"串口: {args.port}")
    print(f"波特率: {args.baud}")
    print(f"数据模式: {args.mode}")
    print(f"发送间隔: {args.interval}ms ({1000.0/args.interval:.0f}Hz)")
    print("=" * 50)
    
    device = JackFourChannelDevice(
        port=args.port,
        baudrate=args.baud,
        data_mode=args.mode,
        interval_ms=args.interval,
    )
    device.data_gen.amplitude = args.amplitude
    
    device.run()


if __name__ == '__main__':
    main()
