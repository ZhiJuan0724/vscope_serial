#!/usr/bin/env python3
"""Modbus 从站（服务器）模拟器 —— 按 Modbus 标准实现，用于验证上位机主站。"""

"""
实现说明
--------
本工具严格按 Modbus 应用协议规范（Modbus Application Protocol Spec V1.1b3）实现，
不参照任何特定上位机的编解码细节，以便独立检验主站代码的协议正确性。

支持的三种传输：
    rtu   —— RTU 模式：1 地址 + PDU + CRC16（LSB 在前）；帧间 3.5 字符静默，帧内字符间隔 ≤1.5 字符
    ascii —— ASCII 模式：':' 起始、'\\r\\n' 结束，每字节 2 个十六进制字符 + LRC（二进制补码，不含 ':' 与 '\\r\\n'）
    tcp   —— TCP 模式：MBAP 头（事务ID2 + 协议ID2=0 + 长度2 + 单元ID1）+ PDU；事务ID必须回显，协议ID必须为0

支持功能码（PDU 层标准格式）：
    0x01 读线圈           0x02 读离散输入
    0x03 读保持寄存器     0x04 读输入寄存器
    0x05 写单线圈         0x06 写单寄存器
    0x0F 写多线圈         0x10 写多寄存器

异常码（标准）：
    0x01 非法功能        0x02 非法数据地址
    0x03 非法数据值      0x04 从站设备故障

严格校验点（常用来暴露主站实现缺陷）：
    - RTU 帧必须用静默间隔定界，CRC 校验失败即丢弃并重同步，不能按猜测长度截取
    - 读数量为 0 或超上限（线圈 0x7D0 / 寄存器 0x7D）→ 异常 0x03
    - 读地址+数量超出区域范围 → 异常 0x02
    - 写单线圈值必须为 0xFF00/0x0000，否则异常 0x03
    - 写多线圈/寄存器的字节计数字段与数量不符 → 异常 0x03
    - 未知功能码 → 异常 0x01
    - TCP MBAP 长度字段错误、协议 ID 非 0 → 直接忽略该帧

使用方法：
    RTU:  python modbus_device.py --mode rtu  --port COM14
    ASCII:python modbus_device.py --mode ascii --port COM14
    TCP:  python modbus_device.py --mode tcp  --port 502        # 打印监听地址

依赖：
    pip install pyserial
"""

import argparse
import socket
import struct
import sys
import threading
import time
from typing import List, Optional, Tuple

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


# ---------------------------------------------------------------- 协议常量

# 功能码
FC_READ_COILS = 0x01
FC_READ_DISCRETE_INPUTS = 0x02
FC_READ_HOLDING_REGISTERS = 0x03
FC_READ_INPUT_REGISTERS = 0x04
FC_WRITE_SINGLE_COIL = 0x05
FC_WRITE_SINGLE_REGISTER = 0x06
FC_WRITE_MULTIPLE_COILS = 0x0F
FC_WRITE_MULTIPLE_REGISTERS = 0x10

READ_FC = {
    FC_READ_COILS,
    FC_READ_DISCRETE_INPUTS,
    FC_READ_HOLDING_REGISTERS,
    FC_READ_INPUT_REGISTERS,
}
WRITE_FC = {
    FC_WRITE_SINGLE_COIL,
    FC_WRITE_SINGLE_REGISTER,
    FC_WRITE_MULTIPLE_COILS,
    FC_WRITE_MULTIPLE_REGISTERS,
}

# 标准异常码
EX_ILLEGAL_FUNCTION = 0x01
EX_ILLEGAL_DATA_ADDRESS = 0x02
EX_ILLEGAL_DATA_VALUE = 0x03
EX_SLAVE_DEVICE_FAILURE = 0x04

# 单帧读取数量上限（规范规定）
MAX_READ_COILS = 0x07D0          # 2000
MAX_READ_REGISTERS = 0x007D      # 125
MAX_WRITE_MULTI_COILS = 0x07B0   # 1968
MAX_WRITE_MULTI_REGISTERS = 0x007B  # 123

FC_LABELS = {
    FC_READ_COILS: "读线圈",
    FC_READ_DISCRETE_INPUTS: "读离散输入",
    FC_READ_HOLDING_REGISTERS: "读保持寄存器",
    FC_READ_INPUT_REGISTERS: "读输入寄存器",
    FC_WRITE_SINGLE_COIL: "写单线圈",
    FC_WRITE_SINGLE_REGISTER: "写单寄存器",
    FC_WRITE_MULTIPLE_COILS: "写多线圈",
    FC_WRITE_MULTIPLE_REGISTERS: "写多寄存器",
}


def _crc16(data: bytes) -> int:
    """RTU CRC16/MODBUS：init 0xFFFF，poly 0xA001，帧内低字节在前。"""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if (crc & 1) else crc >> 1
    return crc & 0xFFFF


def _lrc(data: bytes) -> int:
    """ASCII LRC：对地址+PDU 求和取二进制补码（不含 ':' 与 '\\r\\n'）。"""
    return (-sum(data)) & 0xFF


def _format_hex(data: bytes) -> str:
    return " ".join(f"{b:02X}" for b in data)


class ModbusFrameError(Exception):
    pass


# ---------------------------------------------------------------- 从站数据区

class ModbusSlaveStore:
    """从站数据区。地址均为协议层 0 基地址。"""

    def __init__(
        self,
        coils: int = 0x10000,
        discrete_inputs: int = 0x10000,
        holding_registers: int = 0x10000,
        input_registers: int = 0x10000,
        init_value: int = 0,
        auto_increment: bool = False,
    ):
        self._coils = bytearray((coils + 7) // 8)
        self._coil_count = coils
        self._discrete = bytearray((discrete_inputs + 7) // 8)
        self._discrete_count = discrete_inputs
        self._holding = [init_value & 0xFFFF] * holding_registers
        self._holding_count = holding_registers
        self._input = [init_value & 0xFFFF] * input_registers
        self._input_count = input_registers
        self._auto_increment = auto_increment
        self._lock = threading.Lock()

    def tick(self):
        """后台自增，用于模拟动态设备。"""
        if not self._auto_increment:
            return
        with self._lock:
            for i in range(min(64, self._holding_count)):
                self._holding[i] = (self._holding[i] + 1) & 0xFFFF
            for i in range(min(64, self._input_count)):
                self._input[i] = (self._input[i] + 1) & 0xFFFF

    # ---- 位区 ----
    def read_bits(self, area, address: int, quantity: int) -> bytes:
        if area == "coil":
            table, count = self._coils, self._coil_count
        elif area == "discrete":
            table, count = self._discrete, self._discrete_count
        else:
            raise ModbusFrameError(EX_ILLEGAL_FUNCTION)
        if address + quantity > count:
            raise ModbusFrameError(EX_ILLEGAL_DATA_ADDRESS)
        with self._lock:
            packed = bytearray((quantity + 7) // 8)
            for i in range(quantity):
                if (table[(address + i) >> 3] >> ((address + i) & 7)) & 1:
                    packed[i >> 3] |= 1 << (i & 7)
            return bytes(packed)

    def write_bits(self, area, address: int, quantity: int, packed: bytes) -> None:
        if area == "coil":
            table, count = self._coils, self._coil_count
        else:
            raise ModbusFrameError(EX_ILLEGAL_FUNCTION)
        if address + quantity > count:
            raise ModbusFrameError(EX_ILLEGAL_DATA_ADDRESS)
        with self._lock:
            for i in range(quantity):
                bit = (packed[i >> 3] >> (i & 7)) & 1 if i < len(packed) * 8 else 0
                index = address + i
                if bit:
                    table[index >> 3] |= 1 << (index & 7)
                else:
                    table[index >> 3] &= ~(1 << (index & 7))

    def write_single_bit(self, area, address: int, value: int) -> None:
        self.write_bits(area, address, 1, bytes([0xFF if value else 0x00]))

    # ---- 字区 ----
    def read_registers(self, area, address: int, quantity: int) -> List[int]:
        if area == "holding":
            table, count = self._holding, self._holding_count
        elif area == "input":
            table, count = self._input, self._input_count
        else:
            raise ModbusFrameError(EX_ILLEGAL_FUNCTION)
        if address + quantity > count:
            raise ModbusFrameError(EX_ILLEGAL_DATA_ADDRESS)
        with self._lock:
            return list(table[address:address + quantity])

    def write_registers(self, area, address: int, values: List[int]) -> None:
        if area != "holding":
            raise ModbusFrameError(EX_ILLEGAL_FUNCTION)
        if address + len(values) > self._holding_count:
            raise ModbusFrameError(EX_ILLEGAL_DATA_ADDRESS)
        with self._lock:
            for i, value in enumerate(values):
                self._holding[address + i] = value & 0xFFFF


# ---------------------------------------------------------------- PDU 处理

class ModbusPduProcessor:
    """按规范解析 PDU 并生成响应 PDU（异常时返回 FC|0x80 + 异常码）。"""

    def __init__(self, store: ModbusSlaveStore, inject_exception: Optional[int] = None):
        self.store = store
        self.inject_exception = inject_exception

    def handle(self, unit_id: int, pdu: bytes) -> Optional[bytes]:
        """返回响应 PDU（含 FC）；请求 PDU 不合法到无法解析时返回 None（不响应）。"""
        if not pdu:
            return None
        fc = pdu[0]
        if fc not in READ_FC and fc not in WRITE_FC:
            response = bytes([fc | 0x80, EX_ILLEGAL_FUNCTION])
            self._log_operation(unit_id, pdu, response)
            return response
        if self.inject_exception is not None:
            response = bytes([fc | 0x80, self.inject_exception])
            self._log_operation(unit_id, pdu, response)
            return response

        try:
            if fc in (FC_READ_COILS, FC_READ_DISCRETE_INPUTS,
                      FC_READ_HOLDING_REGISTERS, FC_READ_INPUT_REGISTERS):
                response = self._handle_read(fc, pdu)
            else:
                response = self._handle_write(fc, pdu)
        except ModbusFrameError as exc:
            response = bytes([fc | 0x80, exc.args[0]])
        self._log_operation(unit_id, pdu, response)
        return response

    def _log_operation(self, unit_id: int, pdu: bytes, response: bytes):
        timestamp = time.strftime("%H:%M:%S")
        millis = int((time.time() % 1) * 1000)
        fc = pdu[0]
        operation = "查询" if fc in READ_FC else "写入"
        label = FC_LABELS.get(fc, f"未知功能 0x{fc:02X}")
        details = self._request_details(fc, pdu)
        result = self._response_details(fc, pdu, response)
        print(
            f"[{timestamp}.{millis:03d}] {operation} | 从站={unit_id} | "
            f"FC=0x{fc:02X} {label}{details} | {result}",
            flush=True,
        )

    def _request_details(self, fc: int, pdu: bytes) -> str:
        if len(pdu) < 5:
            return f" | PDU={_format_hex(pdu)}"
        address = (pdu[1] << 8) | pdu[2]
        reference_bases = {
            FC_READ_COILS: 1,
            FC_READ_DISCRETE_INPUTS: 10001,
            FC_READ_HOLDING_REGISTERS: 40001,
            FC_READ_INPUT_REGISTERS: 30001,
            FC_WRITE_SINGLE_COIL: 1,
            FC_WRITE_SINGLE_REGISTER: 40001,
            FC_WRITE_MULTIPLE_COILS: 1,
            FC_WRITE_MULTIPLE_REGISTERS: 40001,
        }
        reference = reference_bases.get(fc, 0) + address
        if fc in READ_FC:
            quantity = (pdu[3] << 8) | pdu[4]
            return f" | 地址={address} (参考号={reference}) | 数量={quantity}"
        if fc == FC_WRITE_SINGLE_COIL:
            raw = (pdu[3] << 8) | pdu[4]
            value = "ON" if raw == 0xFF00 else "OFF" if raw == 0 else f"0x{raw:04X}"
            return f" | 地址={address} (参考号={reference}) | 值={value}"
        if fc == FC_WRITE_SINGLE_REGISTER:
            value = (pdu[3] << 8) | pdu[4]
            return f" | 地址={address} (参考号={reference}) | 值={value} (0x{value:04X})"
        quantity = (pdu[3] << 8) | pdu[4]
        values = self._write_values(fc, pdu, quantity)
        return (
            f" | 地址={address} (参考号={reference}) | 数量={quantity}"
            f" | 值={self._format_values(values)}"
        )

    @staticmethod
    def _write_values(fc: int, pdu: bytes, quantity: int) -> List[int]:
        if len(pdu) < 6:
            return []
        if fc == FC_WRITE_MULTIPLE_COILS:
            data = pdu[6:]
            return [
                1 if data[index // 8] & (1 << (index % 8)) else 0
                for index in range(min(quantity, len(data) * 8))
            ]
        data = pdu[6:]
        return [
            (data[index] << 8) | data[index + 1]
            for index in range(0, min(len(data), quantity * 2) - 1, 2)
        ]

    def _response_details(self, fc: int, pdu: bytes, response: bytes) -> str:
        if not response:
            return "无响应"
        if response[0] & 0x80:
            code = response[1] if len(response) > 1 else 0
            return f"异常 | 异常码=0x{code:02X}"
        if fc not in READ_FC:
            return "写入成功"
        if len(response) < 2:
            return f"响应异常 | PDU={_format_hex(response)}"
        data = response[2:2 + response[1]]
        if fc in (FC_READ_COILS, FC_READ_DISCRETE_INPUTS):
            quantity = (pdu[3] << 8) | pdu[4] if len(pdu) >= 5 else len(data) * 8
            values = [
                1 if data[index // 8] & (1 << (index % 8)) else 0
                for index in range(min(quantity, len(data) * 8))
            ]
        else:
            values = [
                (data[index] << 8) | data[index + 1]
                for index in range(0, len(data) - 1, 2)
            ]
        return f"查询成功 | 返回值={self._format_values(values)}"

    @staticmethod
    def _format_values(values: List[int], limit: int = 32) -> str:
        displayed = ", ".join(str(value) for value in values[:limit])
        suffix = f", ... (共{len(values)}项)" if len(values) > limit else ""
        return f"[{displayed}{suffix}]"

    def _check_read_request(self, pdu: bytes) -> Tuple[int, int]:
        if len(pdu) != 5:
            raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
        address = (pdu[1] << 8) | pdu[2]
        quantity = (pdu[3] << 8) | pdu[4]
        return address, quantity

    def _handle_read(self, fc, pdu: bytes) -> bytes:
        address, quantity = self._check_read_request(pdu)
        if quantity == 0:
            raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
        if fc in (FC_READ_COILS, FC_READ_DISCRETE_INPUTS):
            if quantity > MAX_READ_COILS:
                raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
            area = "coil" if fc == FC_READ_COILS else "discrete"
            packed = self.store.read_bits(area, address, quantity)
            return bytes([fc, len(packed)]) + packed
        # 寄存器读
        if quantity > MAX_READ_REGISTERS:
            raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
        area = "holding" if fc == FC_READ_HOLDING_REGISTERS else "input"
        values = self.store.read_registers(area, address, quantity)
        body = bytearray()
        for value in values:
            body += struct.pack(">H", value)
        return bytes([fc, len(body)]) + bytes(body)

    def _handle_write(self, fc, pdu: bytes) -> bytes:
        if fc == FC_WRITE_SINGLE_COIL:
            if len(pdu) != 5:
                raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
            address = (pdu[1] << 8) | pdu[2]
            value = (pdu[3] << 8) | pdu[4]
            if value not in (0x0000, 0xFF00):
                raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
            self.store.write_single_bit("coil", address, 0xFF00 if value else 0)
            return bytes(pdu)  # 回显请求

        if fc == FC_WRITE_SINGLE_REGISTER:
            if len(pdu) != 5:
                raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
            address = (pdu[1] << 8) | pdu[2]
            value = (pdu[3] << 8) | pdu[4]
            self.store.write_registers("holding", address, [value])
            return bytes(pdu)  # 回显请求

        if fc == FC_WRITE_MULTIPLE_COILS:
            if len(pdu) < 6:
                raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
            address = (pdu[1] << 8) | pdu[2]
            quantity = (pdu[3] << 8) | pdu[4]
            byte_count = pdu[5]
            if quantity == 0 or quantity > MAX_WRITE_MULTI_COILS:
                raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
            expected_bytes = (quantity + 7) // 8
            if byte_count != expected_bytes or len(pdu) != 6 + byte_count:
                raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
            self.store.write_bits("coil", address, quantity, pdu[6:6 + byte_count])
            return bytes([fc, (address >> 8), address & 0xFF,
                          (quantity >> 8), quantity & 0xFF])

        if fc == FC_WRITE_MULTIPLE_REGISTERS:
            if len(pdu) < 6:
                raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
            address = (pdu[1] << 8) | pdu[2]
            quantity = (pdu[3] << 8) | pdu[4]
            byte_count = pdu[5]
            if quantity == 0 or quantity > MAX_WRITE_MULTI_REGISTERS:
                raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
            if byte_count != quantity * 2 or len(pdu) != 6 + byte_count:
                raise ModbusFrameError(EX_ILLEGAL_DATA_VALUE)
            values = []
            for i in range(quantity):
                values.append((pdu[6 + i * 2] << 8) | pdu[6 + i * 2 + 1])
            self.store.write_registers("holding", address, values)
            return bytes([fc, (address >> 8), address & 0xFF,
                          (quantity >> 8), quantity & 0xFF])

        raise ModbusFrameError(EX_ILLEGAL_FUNCTION)


# ---------------------------------------------------------------- 传输封装

class ModbusTransport:
    def __init__(self, processor: ModbusPduProcessor, verbose: bool, unit: int):
        self.processor = processor
        self.verbose = verbose
        self.unit = unit
        self.running = True
        self.paused = False

    def send_frame(self, data: bytes):
        raise NotImplementedError

    def log_request(self, data: bytes, label: str):
        if not self.verbose:
            return
        print(f"[收] {label}: {_format_hex(data)}")

    def log_response(self, pdu: Optional[bytes], label: str):
        if pdu is None:
            print(f"[发] {label}: (不响应)")
            return
        if pdu[0] & 0x80:
            print(f"[发] {label}: 异常 FC=0x{pdu[0]:02X} 码=0x{pdu[1]:02X}")
        elif self.verbose:
            print(f"[发] {label}: {_format_hex(pdu)}")


class RtuTransport(ModbusTransport):
    """RTU：3.5 字符静默定界，帧内字节间隔 ≤1.5 字符，CRC16。"""

    def __init__(self, processor, verbose, unit, serial_port):
        super().__init__(processor, verbose, unit)
        self.serial = serial_port
        # 1 字符时间 = 11 bit / baud
        char_time = 11.0 / max(1, serial_port.baudrate)
        self.inter_frame = char_time * 3.5
        self.max_char = char_time * 1.5
        self._buffer = bytearray()
        self._last_char = 0.0

    def _feed(self, data: bytes):
        if not data:
            return
        self._buffer.extend(data)
        self._last_char = time.monotonic()

    def _poll(self):
        # 需要至少一个完整最小帧长度再判断；若无字节或仍在帧内，继续等
        if not self._buffer:
            return
        if time.monotonic() - self._last_char < self.inter_frame:
            return
        frame = bytes(self._buffer)
        self._buffer.clear()
        self._process_frame(frame)

    def _process_frame(self, frame: bytes):
        # 最小合法 RTU 请求：地址+FC+CRC(2)=4；校验 CRC
        if len(frame) < 4:
            print(f"[RTU] 帧过短丢弃: {_format_hex(frame)}")
            return
        body = frame[:-2]
        expected = _crc16(body)
        actual = (frame[-2]) | (frame[-1] << 8)  # 低字节在前
        if expected != actual:
            print(f"[RTU] CRC 校验失败丢弃: 期望=0x{expected:04X} "
                  f"实得=0x{actual:04X} 帧={_format_hex(frame)}")
            return
        unit = body[0]
        if unit != self.unit and unit != 0:
            # 非本从站地址，静默忽略（广播 0 只写不响应）
            return
        pdu = body[1:]
        self.log_request(frame, "RTU 请求")
        self._dispatch(unit, pdu, "RTU")

    def _dispatch(self, unit, pdu, label):
        if self.paused:
            print(f"[{label}] 暂停中，忽略请求")
            return
        resp_pdu = self.processor.handle(unit, pdu)
        if resp_pdu is None:
            return
        self.log_response(resp_pdu, label)
        if unit == 0:
            # 广播地址不回响应
            print(f"[{label}] 广播请求，不回响应")
            return
        resp_body = bytes([self.unit]) + resp_pdu
        crc = _crc16(resp_body)
        frame = resp_body + bytes([crc & 0xFF, crc >> 8])
        self.send_frame(frame)

    def send_frame(self, data: bytes):
        try:
            self.serial.write(data)
            self.serial.flush()
        except serial.SerialException as exc:
            print(f"[RTU] 发送失败: {exc}")

    def poll(self):
        self._poll()


class AsciiTransport(ModbusTransport):
    """ASCII：':' 起始 '\\r\\n' 结束，每字节 2 个十六进制字符，LRC 校验。"""

    def __init__(self, processor, verbose, unit, serial_port):
        super().__init__(processor, verbose, unit)
        self.serial = serial_port
        self._buffer = bytearray()

    def _feed(self, data: bytes):
        self._buffer.extend(data)

    def _poll(self):
        while True:
            start = self._buffer.find(b":")
            if start < 0:
                self._buffer.clear()
                return
            if start > 0:
                del self._buffer[:start]
            end = self._buffer.find(b"\r\n")
            if end < 0:
                return
            frame_bytes = bytes(self._buffer[1:end])
            del self._buffer[:end + 2]
            self._process_frame(frame_bytes)

    def _process_frame(self, body: bytes):
        try:
            text = body.decode("ascii")
        except UnicodeDecodeError:
            print("[ASCII] 非 ASCII 字符丢弃")
            return
        if len(text) % 2 != 0:
            print("[ASCII] 十六进制字符数为奇数丢弃")
            return
        raw = bytes.fromhex(text)
        if len(raw) < 2:
            print("[ASCII] 帧过短丢弃")
            return
        data = raw[:-1]
        if _lrc(data) != raw[-1]:
            print(f"[ASCII] LRC 校验失败丢弃: {_format_hex(raw)}")
            return
        unit = data[0]
        if unit != self.unit and unit != 0:
            return
        pdu = data[1:]
        self.log_request(raw, "ASCII 请求")
        if self.paused:
            print("[ASCII] 暂停中，忽略请求")
            return
        resp_pdu = self.processor.handle(unit, pdu)
        if resp_pdu is None:
            return
        self.log_response(resp_pdu, "ASCII")
        if unit == 0:
            print("[ASCII] 广播请求，不回响应")
            return
        resp_data = bytes([self.unit]) + resp_pdu + bytes([_lrc(bytes([self.unit]) + resp_pdu)])
        frame = b":" + resp_data.hex().upper().encode() + b"\r\n"
        self.send_frame(frame)

    def send_frame(self, data: bytes):
        try:
            self.serial.write(data)
            self.serial.flush()
        except serial.SerialException as exc:
            print(f"[ASCII] 发送失败: {exc}")

    def poll(self):
        self._poll()


class TcpTransport(ModbusTransport):
    """TCP：MBAP 头（事务ID + 协议ID=0 + 长度 + 单元ID）+ PDU，事务ID回显。"""

    def __init__(self, processor, verbose, unit, host, tcp_port):
        super().__init__(processor, verbose, unit)
        self.host = host
        self.port = tcp_port
        self._server: Optional[socket.socket] = None
        self._client: Optional[socket.socket] = None
        self._buffer = bytearray()
        self._lock = threading.Lock()

    def start(self):
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind((self.host, self.port))
        self._server.listen(1)
        self._server.setblocking(False)
        addrs = self._listen_addresses()
        print("[TCP] 正在监听 Modbus TCP")
        for addr in addrs:
            print(f"[TCP] 监听地址: {addr}")

    def _listen_addresses(self) -> List[str]:
        if self.host not in ("0.0.0.0", ""):
            return [f"{self.host}:{self.port}"]
        addresses = []
        try:
            hostname = socket.gethostname()
            for info in socket.getaddrinfo(hostname, self.port,
                                           socket.AF_INET, socket.SOCK_STREAM):
                ip = info[4][0]
                if not ip.startswith("127.") and ip not in addresses:
                    addresses.append(ip)
        except OSError:
            pass
        addresses.append(f"127.0.0.1:{self.port}")
        return addresses

    def _accept(self):
        if self._client is not None:
            return
        try:
            self._client, addr = self._server.accept()
        except BlockingIOError:
            return
        self._client.setblocking(False)
        print(f"[TCP] 客户端已连接: {addr[0]}:{addr[1]}")

    def _feed(self, data: bytes):
        self._buffer.extend(data)

    def _poll(self):
        if self._client is None:
            return
        while True:
            frame = self._take_mbap()
            if frame is None:
                return
            self._process_frame(frame)

    def _take_mbap(self) -> Optional[bytes]:
        if len(self._buffer) < 6:
            return None
        length = (self._buffer[4] << 8) | self._buffer[5]
        if length < 1 or length > 254:
            print("[TCP] MBAP 长度字段非法，丢弃当前缓冲")
            self._buffer.clear()
            return None
        if len(self._buffer) < 6 + length:
            return None
        frame = bytes(self._buffer[:6 + length])
        del self._buffer[:6 + length]
        return frame

    def _process_frame(self, frame: bytes):
        transaction = (frame[0] << 8) | frame[1]
        protocol = (frame[2] << 8) | frame[3]
        length = (frame[4] << 8) | frame[5]
        unit = frame[6]
        pdu = frame[7:]
        if protocol != 0:
            print(f"[TCP] 协议ID非0丢弃: 0x{protocol:04X}")
            return
        if length != 1 + len(pdu):
            print("[TCP] MBAP 长度与 PDU 不符丢弃")
            return
        self.log_request(frame, "TCP 请求")
        if self.paused:
            print("[TCP] 暂停中，忽略请求")
            return
        resp_pdu = self.processor.handle(unit, pdu)
        if resp_pdu is None:
            return
        self.log_response(resp_pdu, "TCP")
        resp = struct.pack(">HHHB", transaction, 0, 1 + len(resp_pdu), unit) + resp_pdu
        self.send_frame(resp)

    def send_frame(self, data: bytes):
        if self._client is None:
            return
        try:
            with self._lock:
                self._client.sendall(data)
        except OSError as exc:
            print(f"[TCP] 发送失败: {exc}")

    def poll(self):
        self._accept()
        if self._client is not None:
            try:
                data = self._client.recv(4096)
            except BlockingIOError:
                data = b""
            except OSError:
                data = None
            if data == b"":
                # 对端关闭
                print("[TCP] 客户端已断开")
                self._client.close()
                self._client = None
                self._buffer.clear()
                return
            if data:
                self._feed(data)
        self._poll()

    def close(self):
        if self._client:
            self._client.close()
        if self._server:
            self._server.close()


# ---------------------------------------------------------------- 控制台控制

class ConsoleCommandReader:
    """后台读取控制台命令（兼容 msvcrt 与 stdin 两种环境）。"""

    def __init__(self):
        self._commands = []
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()

    def _run(self):
        if msvcrt is not None:
            self._key_loop()
        else:
            self._line_loop()

    def _key_loop(self):
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
                with self._lock:
                    self._commands.append(command)

    def _line_loop(self):
        while True:
            line = sys.stdin.readline()
            if line == "":
                return
            command = line.strip().lower()
            if command:
                with self._lock:
                    self._commands.append(command)

    def drain(self) -> List[str]:
        with self._lock:
            commands = self._commands
            self._commands = []
            return commands


def _run_autoincrement(store, stop):
    while not stop.is_set():
        store.tick()
        time.sleep(1.0)


# ---------------------------------------------------------------- 主流程

def main():
    parser = argparse.ArgumentParser(
        description="Modbus 从站（服务器）模拟器 —— 按 Modbus 标准实现",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python modbus_device.py --mode rtu --port COM14
  python modbus_device.py --mode rtu --port COM14 --baud 115200 --unit 1 --verbose
  python modbus_device.py --mode ascii --port COM14
  python modbus_device.py --mode tcp --port 502
  python modbus_device.py --mode tcp --host 0.0.0.0 --port 502 --inject-exception 3

上位机连接提示:
  - RTU/ASCII 模式下，上位机连接同一串口对（如 COM13 <-> COM14），本脚本接 COM14。
  - TCP 模式下，上位机以 TCP 客户端连接本脚本吐出的监听地址。
""",
    )
    parser.add_argument(
        "--mode",
        choices=["rtu", "ascii", "tcp"],
        required=True,
        help="传输模式: rtu / ascii / tcp",
    )
    parser.add_argument(
        "--port",
        "-p",
        help="RTU/ASCII: 串口号 (如 COM14)；TCP: 监听端口 (默认 502)",
    )
    parser.add_argument("--baud", "-b", type=int, default=115200, help="RTU/ASCII 串口波特率 (默认 115200)")
    parser.add_argument("--host", default="127.0.0.1", help="TCP 监听地址 (默认 127.0.0.1)")
    parser.add_argument("--unit", "-u", type=int, default=1, help="从站单元号 (默认 1)")
    parser.add_argument("--verbose", "-v", action="store_true", help="额外打印接收/发送的完整原始帧")
    parser.add_argument(
        "--inject-exception",
        type=int,
        choices=[1, 2, 3, 4],
        help="对全部请求注入指定异常码 (1非法功能/2非法地址/3非法值/4设备故障)",
    )
    parser.add_argument(
        "--init-value",
        type=int,
        default=0,
        help="寄存器/线圈初始值 (默认 0)",
    )
    parser.add_argument(
        "--auto-increment",
        action="store_true",
        help="保持寄存器/输入寄存器前 64 个值每秒自增，模拟动态设备",
    )
    parser.add_argument("--coils", type=int, default=0x10000, help="线圈数量 (默认 65536)")
    parser.add_argument("--discrete-inputs", type=int, default=0x10000, help="离散输入数量 (默认 65536)")
    parser.add_argument("--holding-registers", type=int, default=0x10000, help="保持寄存器数量 (默认 65536)")
    parser.add_argument("--input-registers", type=int, default=0x10000, help="输入寄存器数量 (默认 65536)")

    args = parser.parse_args()

    if args.mode in ("rtu", "ascii") and not args.port:
        parser.error("RTU/ASCII 模式必须指定 --port 串口号")
    if args.mode == "tcp":
        if args.port is None:
            args.port = 502
        try:
            args.port = int(args.port)
        except (TypeError, ValueError):
            parser.error("TCP 模式的 --port 必须是端口号")

    print("=" * 56)
    print("Modbus 从站模拟器")
    print(f"模式: {args.mode.upper()} | 单元号: {args.unit}")
    if args.mode == "tcp":
        print(f"监听: {args.host}:{args.port}")
    else:
        print(f"串口: {args.port} @ {args.baud}bps")
    if args.inject_exception:
        print(f"异常注入: 0x{args.inject_exception:02X}")
    if args.auto_increment:
        print("自增模拟: 前 64 个寄存器每秒 +1")
    print("操作日志: 已开启（每次查询和写入都会输出）")
    print("=" * 56)

    store = ModbusSlaveStore(
        coils=args.coils,
        discrete_inputs=args.discrete_inputs,
        holding_registers=args.holding_registers,
        input_registers=args.input_registers,
        init_value=args.init_value,
        auto_increment=args.auto_increment,
    )
    processor = ModbusPduProcessor(store, inject_exception=args.inject_exception)

    stop = threading.Event()
    if args.auto_increment:
        threading.Thread(target=_run_autoincrement, args=(store, stop), daemon=True).start()

    if args.mode in ("rtu", "ascii"):
        try:
            ser = serial.Serial(
                port=args.port,
                baudrate=args.baud,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=0.01,
            )
        except serial.SerialException as exc:
            print(f"[错误] 无法打开串口 {args.port}: {exc}")
            sys.exit(1)
        print(f"[串口] 已打开: {args.port} @ {args.baud}bps")
        if args.mode == "rtu":
            transport = RtuTransport(processor, args.verbose, args.unit, ser)
        else:
            transport = AsciiTransport(processor, args.verbose, args.unit, ser)
    else:
        transport = TcpTransport(processor, args.verbose, args.unit, args.host, args.port)
        try:
            transport.start()
        except OSError as exc:
            print(f"[错误] TCP 监听失败: {exc}")
            sys.exit(1)

    console = ConsoleCommandReader()
    console.start()
    print("[控制] p 暂停/恢复应答 / r 复位数据 / c 关闭脚本；Ctrl+C 退出")

    try:
        while transport.running:
            for command in console.drain():
                if command == "p":
                    transport.paused = not transport.paused
                    print(f"[控制] 已{'暂停' if transport.paused else '恢复'}应答")
                elif command == "r":
                    store.tick()
                    print("[控制] 已复位数据")
                elif command == "c":
                    print("[控制] 收到关闭命令")
                    transport.running = False
                else:
                    print(f"[控制] 未知命令: {command}，可用: p 暂停/恢复 / r 复位 / c 关闭")

            if args.mode in ("rtu", "ascii"):
                if ser.in_waiting > 0:
                    transport._feed(ser.read(ser.in_waiting))
                transport.poll()
            else:
                transport.poll()
            time.sleep(0.005)
    except KeyboardInterrupt:
        print("\n[控制] 用户中断")
    finally:
        stop.set()
        if args.mode in ("rtu", "ascii"):
            ser.close()
            print("[串口] 已关闭")
        else:
            transport.close()
            print("[TCP] 已关闭")


if __name__ == "__main__":
    main()
