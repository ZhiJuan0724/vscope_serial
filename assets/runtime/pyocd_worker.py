#!/usr/bin/env python3
"""SerialTools 外置 pyOCD Worker。

监控配置刻意绕开 pyOCD 的 Board、Target、Core 初始化及目标清理路径。
连接只打开 CMSIS-DAP、建立 DP，并创建 AP0 MEM-AP；对上层仅开放 RTT
以及只读 HSS 采样，避免监控功能意外停核、复位或恢复目标。
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import enum
import json
import logging
import os
import struct
import subprocess
import sys
import threading
import time
import traceback
from typing import Any, BinaryIO, Callable, Optional


MAGIC = b"VSPY"
PROTOCOL_VERSION = 1
HEADER = struct.Struct("<4sBBHII")

FRAME_REQUEST = 1
FRAME_RESPONSE = 2
FRAME_DIAGNOSTIC = 3
FRAME_RTT_DATA = 4
FRAME_SAMPLE_DATA = 5
FRAME_DOWN_DATA = 6

PROFILE_NON_INTRUSIVE_MONITOR = "nonIntrusiveMonitor"
KNOWN_PROFILES = (
    PROFILE_NON_INTRUSIVE_MONITOR,
    "programming",
    "interactiveDebug",
)
SUPPORTED_PYOCD_MAJOR = 0
SUPPORTED_PYOCD_MINOR = 45

FORBIDDEN_MONITOR_COMMANDS = frozenset(
    {
        "flash",
        "erase",
        "readCoreRegister",
        "writeCoreRegister",
        "halt",
        "reset",
        "resume",
        "step",
        "setBreakpoint",
        "removeBreakpoint",
        "setWatchpoint",
        "removeWatchpoint",
        "setVectorCatch",
    }
)
MONITOR_COMMANDS = frozenset(
    {
        "hello",
        "listProbes",
        "listUsbDevices",
        "listTargets",
        "connect",
        "configureRtt",
        "listRttChannels",
        "startRttViewer",
        "startRttPlot",
        "startHss",
        "stopActivity",
        "disconnect",
        "shutdown",
    }
)

# 即使用户误把下列地址填成 HSS 变量或 RTT 扫描范围，受限内存门面也必须
# 阻止访问 Cortex-M 核心控制寄存器和调试比较器，不能只依赖上层输入校验。
FORBIDDEN_MONITOR_MEMORY_RANGES = (
    (0xE000ED0C, 0xE000ED10),  # AIRCR
    (0xE000EDF0, 0xE000EE00),  # DHCSR, DCRSR, DCRDR, DEMCR
    (0xE0001000, 0xE0002000),  # DWT and watchpoint comparators
    (0xE0002000, 0xE0003000),  # FPB and breakpoint comparators
)

_SCALAR_FORMATS = {
    "bool": "<?",
    "int8": "<b",
    "int16": "<h",
    "int32": "<i",
    "int64": "<q",
    "uint8": "<B",
    "uint16": "<H",
    "uint32": "<I",
    "uint64": "<Q",
    "float32": "<f",
    "float64": "<d",
}


class WorkerError(RuntimeError):
    pass


class AccessProfile(enum.Enum):
    NON_INTRUSIVE_MONITOR = PROFILE_NON_INTRUSIVE_MONITOR
    PROGRAMMING = "programming"
    INTERACTIVE_DEBUG = "interactiveDebug"


def _pyocd_version() -> str:
    import pyocd

    return str(pyocd.__version__)


def _validate_pyocd_version(version: str) -> None:
    parts = version.split(".", 2)
    try:
        major = int(parts[0])
        minor = int(parts[1])
    except (ValueError, IndexError) as exc:
        raise WorkerError(f"无法解析 pyOCD 版本：{version}") from exc
    if (major, minor) != (SUPPORTED_PYOCD_MAJOR, SUPPORTED_PYOCD_MINOR):
        raise WorkerError(
            f"仅支持 pyOCD 0.45.x，当前版本为 {version}"
        )


def _usb_pairs() -> list[tuple[int, int]]:
    """只枚举 USB VID/PID，不读取接口和字符串描述符。

    pyOCD 的常规 v2 枚举会在扫描全部 USB 设备时读取描述符。某些 Windows
    设备或驱动可能让这一步长期阻塞，因此这里只做低成本 ID 枚举；需要读取
    描述符时，再按单个 VID/PID 放进可超时终止的子进程。
    """

    try:
        from libusb_package import find as usb_find
    except ImportError:
        from usb.core import find as usb_find

    devices = usb_find(find_all=True)
    return sorted(
        {
            (int(device.idVendor), int(device.idProduct))
            for device in devices
        }
    )


def _restrict_cmsis_dap_backends(
    mode: str,
    vendor_id: int,
    product_id: int,
) -> None:
    """把 pyOCD 的所有 CMSIS-DAP 枚举入口限制到一个 VID/PID。"""

    from pyocd.probe.pydapaccess import dap_access_cmsis_dap
    from pyocd.probe.pydapaccess.interface import (
        INTERFACE,
        USB_BACKEND,
        USB_BACKEND_V2,
    )
    from pyocd.probe.pydapaccess.interface import hidapi_backend
    from pyocd.probe.pydapaccess.interface import pyusb_backend
    from pyocd.probe.pydapaccess.interface import pyusb_v2_backend

    original_hid_enumerate = hidapi_backend.hid.enumerate

    def filtered_hid_enumerate(*_args: Any, **_kwargs: Any) -> Any:
        return original_hid_enumerate(vendor_id, product_id)

    hidapi_backend.hid.enumerate = filtered_hid_enumerate

    def restrict_usb_find(module: Any) -> None:
        original_find = module.usb_find

        def filtered_find(*args: Any, **kwargs: Any) -> Any:
            kwargs["idVendor"] = vendor_id
            kwargs["idProduct"] = product_id
            return original_find(*args, **kwargs)

        module.usb_find = filtered_find

    restrict_usb_find(pyusb_backend)
    restrict_usb_find(pyusb_v2_backend)

    def selected_interfaces() -> list[Any]:
        backend = USB_BACKEND if mode == "v1" else USB_BACKEND_V2
        return INTERFACE[backend].get_all_connected_interfaces()

    dap_access_cmsis_dap._get_interfaces = selected_interfaces


def _interface_descriptor(interface: Any, mode: str) -> dict[str, Any]:
    return {
        "id": str(interface.serial_number or ""),
        "name": str(
            interface.product_name
            or interface.get_info()
            or "CMSIS-DAP"
        ),
        "vendorId": int(interface.vid),
        "productId": int(interface.pid),
        "cmsisDapVersion": mode,
    }


def _inspect_usb_pair(mode: str, vendor_id: int, product_id: int) -> int:
    """子进程入口：只对指定 VID/PID 执行 CMSIS-DAP 定向识别。"""

    _restrict_cmsis_dap_backends(mode, vendor_id, product_id)
    from pyocd.probe.pydapaccess import dap_access_cmsis_dap

    interfaces = dap_access_cmsis_dap._get_interfaces()
    print(
        json.dumps(
            [_interface_descriptor(item, mode) for item in interfaces],
            ensure_ascii=False,
        )
    )
    return 0


def _safe_usb_string(device: Any, attribute: str) -> str:
    try:
        return str(getattr(device, attribute) or "").strip()
    except Exception:
        return ""


def _inspect_usb_device(vendor_id: int, product_id: int) -> int:
    """子进程入口：尽力读取指定 USB 设备的显示名称。"""

    try:
        from libusb_package import find as usb_find
    except ImportError:
        from usb.core import find as usb_find

    devices = usb_find(
        find_all=True,
        idVendor=vendor_id,
        idProduct=product_id,
    )
    result = []
    for device in devices:
        product = _safe_usb_string(device, "product")
        manufacturer = _safe_usb_string(device, "manufacturer")
        label = " ".join(item for item in (manufacturer, product) if item)
        result.append(
            {
                "vendorId": vendor_id,
                "productId": product_id,
                "name": label or "USB 设备",
            }
        )
    print(json.dumps(result, ensure_ascii=False))
    return 0


class FrameWriter:
    """带锁写入 VSPY 帧，防止控制响应与实时数据交叉破坏帧边界。"""

    def __init__(self, stream: BinaryIO):
        self._stream = stream
        self._lock = threading.Lock()

    def send(self, frame_type: int, request_id: int, payload: bytes) -> None:
        header = HEADER.pack(
            MAGIC,
            PROTOCOL_VERSION,
            frame_type,
            0,
            request_id,
            len(payload),
        )
        with self._lock:
            self._stream.write(header)
            self._stream.write(payload)
            self._stream.flush()

    def json(self, frame_type: int, request_id: int, value: Any) -> None:
        self.send(
            frame_type,
            request_id,
            json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode(
                "utf-8"
            ),
        )


def read_frame(stream: BinaryIO) -> Optional[tuple[int, int, bytes]]:
    """从标准输入读取一个完整 VSPY 请求帧并校验边界。"""

    header = stream.read(HEADER.size)
    if not header:
        return None
    if len(header) != HEADER.size:
        raise WorkerError("Worker 输入帧头不完整")
    magic, version, frame_type, _flags, request_id, length = HEADER.unpack(header)
    if magic != MAGIC:
        raise WorkerError("Worker 输入帧 magic 无效")
    if version != PROTOCOL_VERSION:
        raise WorkerError(f"不支持的 Worker 协议版本：{version}")
    if length > 64 * 1024 * 1024:
        raise WorkerError("Worker 输入帧过大")
    payload = stream.read(length)
    if len(payload) != length:
        raise WorkerError("Worker 输入帧 payload 不完整")
    return frame_type, request_id, payload


class MonitorMemoryTarget:
    """供 pyOCD 通用 RTT 解析器使用的最小内存访问门面。

    RTT 代码只能看到读写内存所需的方法，拿不到 Core、Flash、断点管理器
    或 Target 控制对象，从结构上限制可执行的操作。
    """

    def __init__(self, mem_ap: Any, memory_map: Any):
        self._mem_ap = mem_ap
        self._memory_map = memory_map

    def get_memory_map(self) -> Any:
        return self._memory_map

    def read_memory_block8(self, address: int, size: int) -> list[int]:
        self._check_access(address, size)
        return list(self._mem_ap.read_memory_block8(address, size))

    def read_memory_block32(self, address: int, count: int) -> list[int]:
        self._check_access(address, count * 4)
        return list(self._mem_ap.read_memory_block32(address, count))

    def read32(self, address: int) -> int:
        self._check_access(address, 4)
        return int(self._mem_ap.read32(address))

    def write_memory_block8(self, address: int, data: list[int] | bytes) -> None:
        self._check_access(address, len(data))
        self._mem_ap.write_memory_block8(address, list(data))

    def write32(self, address: int, value: int) -> None:
        self._check_access(address, 4)
        self._mem_ap.write32(address, value)

    @staticmethod
    def _check_access(address: int, size: int) -> None:
        end = address + max(0, size)
        for forbidden_start, forbidden_end in FORBIDDEN_MONITOR_MEMORY_RANGES:
            if address < forbidden_end and end > forbidden_start:
                raise WorkerError(
                    f"nonIntrusiveMonitor禁止访问调试控制区域：0x{address:08x}"
                )


class PyOcdMonitor:
    """持有一个严格非侵入式的 CMSIS-DAP 监控会话。"""

    def __init__(self, writer: FrameWriter):
        self._writer = writer
        self._session: Any = None
        self._probe: Any = None
        self._dp: Any = None
        self._target: Optional[MonitorMemoryTarget] = None
        self._rtt: Any = None
        self._rtt_config: dict[str, Any] = {
            "mode": "automatic",
            "pollingIntervalMs": 10,
        }
        self._activity_stop = threading.Event()
        self._activity_thread: Optional[threading.Thread] = None
        self._activity_error: Optional[str] = None

    @staticmethod
    def _cmsis_dap_version(args: dict[str, Any]) -> str:
        version = str(args.get("cmsisDapVersion") or "automatic")
        if version not in ("automatic", "v1", "v2"):
            raise WorkerError(f"不支持的 CMSIS-DAP 版本选择：{version}")
        return version

    @staticmethod
    def _enumerate_targeted_probes(
        descriptor: dict[str, Any],
    ) -> list[Any]:
        """在父 Worker 中只实例化已确认 VID/PID 对应的探针。"""

        from pyocd.probe.cmsis_dap_probe import CMSISDAPProbe
        from pyocd.probe.pydapaccess.dap_access_cmsis_dap import (
            DAPAccessCMSISDAP,
        )
        from pyocd.probe.pydapaccess import dap_access_cmsis_dap

        version = str(descriptor["cmsisDapVersion"])
        vendor_id = int(descriptor["vendorId"])
        product_id = int(descriptor["productId"])
        _restrict_cmsis_dap_backends(version, vendor_id, product_id)
        interfaces = dap_access_cmsis_dap._get_interfaces()
        probes = []
        for interface in interfaces:
            if (
                descriptor.get("id")
                and str(interface.serial_number or "") != descriptor["id"]
            ):
                continue
            probe = CMSISDAPProbe(
                DAPAccessCMSISDAP(None, interface=interface)
            )
            probe._vscope_cmsis_dap_version = version
            probe._vscope_usb_vendor_id = vendor_id
            probe._vscope_usb_product_id = product_id
            probes.append(probe)
        return probes

    @classmethod
    def _find_probe_descriptors(
        cls,
        version: str,
        *,
        inspect_timeout: float = 2.0,
        vendor_id: Optional[int] = None,
        product_id: Optional[int] = None,
    ) -> list[dict[str, Any]]:
        """通过限时子进程识别 CMSIS-DAP，隔离异常 USB 驱动。

        用户已选择 USB 设备时只检查指定 VID/PID；自动选择时才先获取全部
        VID/PID，并并行定向检查。任何单项超时都不会卡死主 Worker。
        """

        versions = ("v2", "v1") if version == "automatic" else (version,)
        pairs = (
            [(vendor_id, product_id)]
            if vendor_id is not None and product_id is not None
            else _usb_pairs()
        )
        requests = [
            (selected, vendor_id, product_id)
            for vendor_id, product_id in pairs
            for selected in versions
        ]

        def inspect(
            request: tuple[str, int, int],
        ) -> list[dict[str, Any]]:
            selected, vendor_id, product_id = request
            command = [
                sys.executable,
                "-I",
                "-u",
                __file__,
                "--inspect-probe",
                "--mode",
                selected,
                "--vid",
                str(vendor_id),
                "--pid",
                str(product_id),
            ]
            try:
                result = subprocess.run(
                    command,
                    capture_output=True,
                    text=True,
                    timeout=inspect_timeout,
                    check=False,
                )
            except subprocess.TimeoutExpired:
                return []
            if result.returncode != 0 or not result.stdout.strip():
                return []
            try:
                value = json.loads(result.stdout)
            except json.JSONDecodeError:
                return []
            return (
                [dict(item) for item in value if isinstance(item, dict)]
                if isinstance(value, list)
                else []
            )

        descriptors: list[dict[str, Any]] = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
            for items in executor.map(inspect, requests):
                descriptors.extend(items)

        # 同一物理探针可能同时暴露 v1 与 v2；序列号重复时遵循 pyOCD 的
        # 默认优先级，只保留吞吐更高的 v2。
        deduplicated: dict[str, dict[str, Any]] = {}
        for descriptor in descriptors:
            key = (
                str(descriptor.get("id") or "")
                or (
                    f"{descriptor.get('vendorId')}:"
                    f"{descriptor.get('productId')}:"
                    f"{descriptor.get('cmsisDapVersion')}"
                )
            )
            existing = deduplicated.get(key)
            if (
                existing is None
                or descriptor.get("cmsisDapVersion") == "v2"
            ):
                deduplicated[key] = descriptor
        return list(deduplicated.values())

    @staticmethod
    def list_usb_devices(
        *,
        inspect_timeout: float = 1.5,
    ) -> list[dict[str, Any]]:
        """轻量返回供用户选择的 USB 名称和 VID/PID。

        Windows 优先读取系统缓存的即插即用设备表，不打开 USB 设备；只有
        系统查询不可用时，才回退到按 VID/PID 隔离的 libusb 名称读取。
        """

        windows_devices = PyOcdMonitor._list_windows_usb_devices()
        if windows_devices is not None:
            return windows_devices

        pairs = _usb_pairs()

        def inspect(pair: tuple[int, int]) -> list[dict[str, Any]]:
            vendor_id, product_id = pair
            command = [
                sys.executable,
                "-I",
                "-u",
                __file__,
                "--inspect-usb-device",
                "--vid",
                str(vendor_id),
                "--pid",
                str(product_id),
            ]
            try:
                result = subprocess.run(
                    command,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=inspect_timeout,
                    check=False,
                )
            except subprocess.TimeoutExpired:
                result = None
            if result is not None and result.returncode == 0:
                try:
                    value = json.loads(result.stdout)
                    if isinstance(value, list) and value:
                        return [
                            dict(item)
                            for item in value
                            if isinstance(item, dict)
                        ]
                except json.JSONDecodeError:
                    pass
            return [
                {
                    "vendorId": vendor_id,
                    "productId": product_id,
                    "name": "USB 设备",
                }
            ]

        devices: list[dict[str, Any]] = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
            for items in executor.map(inspect, pairs):
                devices.extend(items)

        deduplicated: dict[tuple[int, int], dict[str, Any]] = {}
        for item in devices:
            key = (int(item["vendorId"]), int(item["productId"]))
            existing = deduplicated.get(key)
            if existing is None or existing.get("name") == "USB 设备":
                deduplicated[key] = item
        return sorted(
            deduplicated.values(),
            key=lambda item: (
                item.get("name") == "USB 设备",
                str(item.get("name") or "").lower(),
                int(item["vendorId"]),
                int(item["productId"]),
            ),
        )

    @staticmethod
    def _list_windows_usb_devices() -> Optional[list[dict[str, Any]]]:
        """读取 Windows 缓存的 PnP 名称，全程不打开 USB 设备。"""

        if sys.platform != "win32":
            return None
        system_root = os.environ.get("SystemRoot", r"C:\Windows")
        powershell = os.path.join(
            system_root,
            "System32",
            "WindowsPowerShell",
            "v1.0",
            "powershell.exe",
        )
        if not os.path.isfile(powershell):
            return None
        script = r"""
$items = @(
  Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.InstanceId -match '^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') {
      [PSCustomObject]@{
        vendorId = [Convert]::ToInt32($Matches[1], 16)
        productId = [Convert]::ToInt32($Matches[2], 16)
        name = [string]$_.FriendlyName
      }
    }
  }
)
$json = ConvertTo-Json -InputObject $items -Compress
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
"""
        try:
            result = subprocess.run(
                [
                    powershell,
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-Command",
                    script,
                ],
                capture_output=True,
                text=True,
                encoding="utf-8-sig",
                errors="replace",
                timeout=4.0,
                check=False,
                creationflags=getattr(
                    subprocess,
                    "CREATE_NO_WINDOW",
                    0,
                ),
            )
            encoded = (result.stdout or "").strip()
            decoded = base64.b64decode(encoded).decode("utf-8")
            value = json.loads(decoded or "[]")
        except (
            OSError,
            subprocess.TimeoutExpired,
            ValueError,
            json.JSONDecodeError,
        ):
            return None
        if result.returncode != 0 or not isinstance(value, list):
            return None

        generic_names = {
            "",
            "USB Composite Device",
            "USB Input Device",
            "USB Serial Device",
            "USB 复合设备",
            "USB 输入设备",
        }
        grouped: dict[tuple[int, int], list[str]] = {}
        for item in value:
            if not isinstance(item, dict):
                continue
            try:
                key = (int(item["vendorId"]), int(item["productId"]))
            except (KeyError, TypeError, ValueError):
                continue
            if key[0] <= 0 or key[1] <= 0:
                continue
            name = str(item.get("name") or "").strip()
            grouped.setdefault(key, []).append(name)

        devices = []
        for (vendor_id, product_id), names in grouped.items():
            preferred = next(
                (name for name in names if name not in generic_names),
                next((name for name in names if name), "USB 设备"),
            )
            devices.append(
                {
                    "vendorId": vendor_id,
                    "productId": product_id,
                    "name": preferred,
                }
            )
        return sorted(
            devices,
            key=lambda item: (
                str(item["name"]).lower(),
                int(item["vendorId"]),
                int(item["productId"]),
            ),
        )

    @classmethod
    def _find_probes(
        cls,
        version: str,
        probe_id: Optional[str] = None,
        *,
        vendor_id: Optional[int] = None,
        product_id: Optional[int] = None,
    ) -> list[Any]:
        """把发现结果转换成连接所需的 pyOCD 探针对象。"""

        descriptors = cls._find_probe_descriptors(
            version,
            vendor_id=vendor_id,
            product_id=product_id,
        )
        if probe_id:
            descriptors = [
                descriptor
                for descriptor in descriptors
                if str(descriptor.get("id") or "") == probe_id
            ]
        elif descriptors:
            # 未指定序列号时沿用 pyOCD 的首个探针行为。只实例化首个发现项，
            # 还能保证父 Worker 后续始终绑定同一个 VID/PID。
            descriptors = descriptors[:1]
        probes: list[Any] = []
        for descriptor in descriptors:
            probes.extend(cls._enumerate_targeted_probes(descriptor))
        return probes

    @classmethod
    def list_probes(cls, args: dict[str, Any]) -> list[dict[str, Any]]:
        version = cls._cmsis_dap_version(args)
        return [
            {
                "id": str(item.get("id") or ""),
                "name": (
                    f"{item.get('name') or 'CMSIS-DAP'} "
                    f"({item.get('cmsisDapVersion') or version})"
                ),
                "vendorId": item.get("vendorId"),
                "productId": item.get("productId"),
            }
            for item in cls._find_probe_descriptors(version)
        ]

    @staticmethod
    def list_targets() -> list[dict[str, str]]:
        # 导入内置目标只注册芯片类，不会访问探针或目标硬件。
        from pyocd.target import TARGET
        import pyocd.target.builtin  # noqa: F401

        return [
            {"name": str(name), "source": "pyOCD"}
            for name in sorted(TARGET.keys())
        ]

    @property
    def connected(self) -> bool:
        return self._probe is not None and self._target is not None

    def connect(self, args: dict[str, Any]) -> dict[str, Any]:
        """建立受限监控连接，不调用完整 Session.open 或 Core 初始化。"""

        if args.get("profile") != PROFILE_NON_INTRUSIVE_MONITOR:
            raise WorkerError("当前版本只实现 nonIntrusiveMonitor 会话")
        self.disconnect()

        from pyocd.core.session import Session
        from pyocd.coresight.ap import APv1Address, AccessPort, MEM_AP
        from pyocd.probe.debug_probe import DebugProbe

        cmsis_dap_version = self._cmsis_dap_version(args)
        target_name = str(args.get("target") or "").strip()
        auto_detect = bool(args.get("autoDetectTarget"))
        probe_id = str(args.get("probeId") or "").strip() or None
        usb_vendor_id = args.get("usbVendorId")
        usb_product_id = args.get("usbProductId")
        if not isinstance(usb_vendor_id, int):
            usb_vendor_id = None
        if not isinstance(usb_product_id, int):
            usb_product_id = None
        protocol_name = str(args.get("wireProtocol") or "swd").lower()
        frequency = int(args.get("clockKhz") or 4000) * 1000
        options = {
            "frequency": frequency,
            "connect_mode": "attach",
            "auto_unlock": False,
            "resume_on_disconnect": False,
            "warning.cortex_m_default": False,
            "no_config": True,
        }
        if target_name:
            options["target_override"] = target_name

        probes = self._find_probes(
            cmsis_dap_version,
            probe_id,
            vendor_id=usb_vendor_id,
            product_id=usb_product_id,
        )
        if not probes:
            raise WorkerError("未检测到可用的 CMSIS-DAP 探针")
        probe = probes[0]
        session = Session(
            probe,
            auto_open=False,
            options=options,
        )
        if probe is None or "cmsis_dap_probe" not in probe.__class__.__module__:
            raise WorkerError("外置 pyOCD 后端只允许 CMSIS-DAP 探针")
        if not target_name and not auto_detect:
            raise WorkerError("请选择目标芯片或开启自动识别")
        if not target_name:
            detected = session.board.target_type if session.board else "cortex_m"
            if not detected or detected == "cortex_m":
                raise WorkerError("pyOCD 未能自动识别目标芯片，请手动选择")

        try:
            probe.open()
            probe.set_clock(frequency)
            protocol = (
                DebugProbe.Protocol.JTAG
                if protocol_name == "jtag"
                else DebugProbe.Protocol.SWD
            )
            # DebugPort.connect 只维护 DP 链路，不创建或初始化 Cortex-M Core。
            target = session.board.target
            dp = target.dp
            dp.connect(protocol)
            if dp.adi_version.name != "ADIv5":
                raise WorkerError("首版外置 pyOCD 仅支持 ADIv5 CMSIS-DAP 目标")
            ap = AccessPort.create(dp, APv1Address(0))
            if not isinstance(ap, MEM_AP):
                raise WorkerError("AP0 不是可用的 MEM-AP；为避免危险扫描已停止连接")
            memory_target = MonitorMemoryTarget(ap, target.get_memory_map())
        except Exception:
            try:
                if probe.wire_protocol is not None:
                    probe.disconnect()
            finally:
                if probe.is_open:
                    probe.close()
            raise

        self._session = session
        self._probe = probe
        self._dp = dp
        self._target = memory_target
        return {
            "probeId": str(probe.unique_id or ""),
            "target": str(session.board.target_type),
            "profile": PROFILE_NON_INTRUSIVE_MONITOR,
        }

    def configure_rtt(self, args: dict[str, Any]) -> None:
        """保存当前功能的 RTT 定位参数，开始读取时再解析控制块。"""

        mode = str(args.get("mode") or "automatic")
        if mode not in ("automatic", "address", "range"):
            raise WorkerError(f"不支持的 RTT 控制块模式：{mode}")
        polling = max(1, min(1000, int(args.get("pollingIntervalMs") or 10)))
        config: dict[str, Any] = {"mode": mode, "pollingIntervalMs": polling}
        if mode == "address":
            address = args.get("address")
            if not isinstance(address, int) or address < 0:
                raise WorkerError("指定地址模式需要有效地址")
            config["address"] = address
        elif mode == "range":
            start = args.get("rangeStart")
            end = args.get("rangeEnd")
            if (
                not isinstance(start, int)
                or not isinstance(end, int)
                or start < 0
                or end <= start
            ):
                raise WorkerError("指定范围模式需要有效起止地址")
            config["rangeStart"] = start
            config["rangeEnd"] = end
        self._rtt_config = config
        self._rtt = None

    def _ensure_rtt(self) -> Any:
        """按配置定位 RTT 控制块，并复用同一次连接中的解析结果。"""

        if self._target is None:
            raise WorkerError("探针尚未连接")
        if self._rtt is not None:
            return self._rtt
        from pyocd.debug.rtt import RTTControlBlock

        mode = self._rtt_config["mode"]
        if mode == "automatic":
            address = None
            size = None
        elif mode == "address":
            address = self._rtt_config["address"]
            size = 0
        else:
            address = self._rtt_config["rangeStart"]
            size = self._rtt_config["rangeEnd"] - address
        rtt = RTTControlBlock.from_target(
            self._target,
            address=address,
            size=size,
            control_block_id=b"SEGGER RTT",
        )
        rtt.start()
        self._rtt = rtt
        return rtt

    def list_rtt_channels(self) -> list[dict[str, Any]]:
        rtt = self._ensure_rtt()
        return [
            {
                "index": index,
                "name": channel.name or f"Up {index}",
                "size": int(channel.size),
                "flags": 0,
            }
            for index, channel in enumerate(rtt.up_channels)
        ]

    def start_rtt(self, channel: int) -> None:
        """只启动指定 Up 通道的轮询任务，连接本身保持不变。"""

        rtt = self._ensure_rtt()
        if channel < 0 or channel >= len(rtt.up_channels):
            raise WorkerError(f"RTT Up 通道不存在：{channel}")
        self.stop_activity()
        self._activity_stop.clear()
        self._activity_error = None
        polling = self._rtt_config["pollingIntervalMs"] / 1000.0

        def loop() -> None:
            try:
                while not self._activity_stop.is_set():
                    data = bytes(rtt.up_channels[channel].read())
                    if data:
                        payload = struct.pack("<H", channel) + data
                        self._writer.send(FRAME_RTT_DATA, 0, payload)
                    self._activity_stop.wait(polling)
            except Exception as exc:
                self._activity_error = str(exc)
                self._diagnostic(f"pyOCD RTT读取失败：{exc}", fatal=True)

        self._activity_thread = threading.Thread(
            target=loop,
            name="pyocd-rtt",
            daemon=True,
        )
        self._activity_thread.start()

    def start_hss(self, args: dict[str, Any]) -> None:
        """按用户给定地址定时只读采样，不访问核心寄存器。"""

        if self._target is None:
            raise WorkerError("探针尚未连接")
        variables = list(args.get("variables") or [])
        if not variables or len(variables) > 12:
            raise WorkerError("HSS必须配置1～12个变量")
        decoded: list[tuple[int, str, int]] = []
        for item in variables:
            scalar_type = str(item.get("type") or "")
            fmt = _SCALAR_FORMATS.get(scalar_type)
            address = item.get("address")
            if fmt is None or not isinstance(address, int) or address < 0:
                raise WorkerError("HSS变量类型或地址无效")
            decoded.append((address, fmt, struct.calcsize(fmt)))
        frequency = max(1, min(5000, int(args.get("frequencyHz") or 1)))
        period = 1.0 / frequency
        target = self._target
        self.stop_activity()
        self._activity_stop.clear()
        self._activity_error = None

        def loop() -> None:
            deadline = time.perf_counter()
            try:
                while not self._activity_stop.is_set():
                    values = []
                    for address, fmt, size in decoded:
                        raw = bytes(target.read_memory_block8(address, size))
                        value = struct.unpack(fmt, raw)[0]
                        values.append(1.0 if value is True else 0.0 if value is False else float(value))
                    monotonic_us = time.perf_counter_ns() // 1000
                    payload = struct.pack("<QH", monotonic_us, len(values))
                    payload += struct.pack(f"<{len(values)}d", *values)
                    self._writer.send(FRAME_SAMPLE_DATA, 0, payload)
                    deadline += period
                    delay = deadline - time.perf_counter()
                    if delay > 0:
                        self._activity_stop.wait(delay)
                    else:
                        deadline = time.perf_counter()
            except Exception as exc:
                self._activity_error = str(exc)
                self._diagnostic(f"pyOCD HSS读取失败：{exc}", fatal=True)

        self._activity_thread = threading.Thread(
            target=loop,
            name="pyocd-hss",
            daemon=True,
        )
        self._activity_thread.start()

    def write_down0(self, data: bytes) -> int:
        rtt = self._ensure_rtt()
        if not rtt.down_channels:
            raise WorkerError("目标没有RTT Down 0")
        return int(rtt.down_channels[0].write(data, blocking=False))

    def stop_activity(self) -> None:
        """停止数据轮询；不会断开探针，也不会改变目标运行状态。"""

        self._activity_stop.set()
        thread = self._activity_thread
        self._activity_thread = None
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=2.0)
            if thread.is_alive():
                raise WorkerError("pyOCD数据活动未能在2秒内停止")
        self._activity_stop.clear()

    def disconnect(self) -> None:
        """释放主机侧传输资源，不执行任何目标恢复或清理动作。"""

        try:
            self.stop_activity()
        except WorkerError:
            pass
        self._rtt = None
        probe = self._probe
        self._probe = None
        self._target = None
        self._dp = None
        self._session = None
        if probe is None:
            return
        # 严禁调用 Session.close、Target.disconnect 或 DebugPort.disconnect：
        # 这些路径可能修改核心/调试状态。这里只让 CMSIS-DAP 释放传输连接。
        try:
            if probe.wire_protocol is not None:
                probe.disconnect()
        finally:
            if probe.is_open:
                probe.close()

    def _diagnostic(self, message: str, *, fatal: bool = False) -> None:
        self._writer.json(
            FRAME_DIAGNOSTIC,
            0,
            {"message": message, "fatal": fatal},
        )


class WorkerServer:
    """按会话白名单分发控制命令，并复用同一个监控连接。"""

    def __init__(self, input_stream: BinaryIO, output_stream: BinaryIO):
        self._writer = FrameWriter(output_stream)
        self._monitor = PyOcdMonitor(self._writer)
        self._running = True

    def run(self, input_stream: BinaryIO) -> None:
        while self._running:
            frame = read_frame(input_stream)
            if frame is None:
                break
            frame_type, request_id, payload = frame
            try:
                if frame_type == FRAME_DOWN_DATA:
                    written = self._monitor.write_down0(payload)
                    self._respond(request_id, {"written": written})
                    continue
                if frame_type != FRAME_REQUEST:
                    raise WorkerError(f"不支持的请求帧类型：{frame_type}")
                request = json.loads(payload.decode("utf-8"))
                command = str(request.get("command") or "")
                args = request.get("args") or {}
                if command in FORBIDDEN_MONITOR_COMMANDS:
                    self._monitor.stop_activity()
                    raise WorkerError(
                        f"nonIntrusiveMonitor禁止操作：{command}"
                    )
                if command not in MONITOR_COMMANDS:
                    self._monitor.stop_activity()
                    raise WorkerError(
                        f"nonIntrusiveMonitor未授权操作：{command}"
                    )
                self._dispatch(request_id, command, args)
            except Exception as exc:
                self._writer.json(
                    FRAME_RESPONSE,
                    request_id,
                    {"ok": False, "error": str(exc)},
                )

    def _respond(self, request_id: int, result: Any = None) -> None:
        self._writer.json(
            FRAME_RESPONSE,
            request_id,
            {"ok": True, "result": result},
        )

    def _dispatch(self, request_id: int, command: str, args: dict[str, Any]) -> None:
        if command == "hello":
            self._respond(
                request_id,
                {
                    "protocolVersion": PROTOCOL_VERSION,
                    "pythonVersion": sys.version.split()[0],
                    "pyocdVersion": _pyocd_version(),
                    "profiles": list(KNOWN_PROFILES),
                    "implementedProfiles": [PROFILE_NON_INTRUSIVE_MONITOR],
                },
            )
        elif command == "listProbes":
            self._respond(request_id, self._monitor.list_probes(args))
        elif command == "listUsbDevices":
            self._respond(request_id, self._monitor.list_usb_devices())
        elif command == "listTargets":
            self._respond(request_id, self._monitor.list_targets())
        elif command == "connect":
            self._respond(request_id, self._monitor.connect(args))
        elif command == "configureRtt":
            self._monitor.configure_rtt(args)
            self._respond(request_id)
        elif command == "listRttChannels":
            self._respond(request_id, self._monitor.list_rtt_channels())
        elif command == "startRttViewer":
            self._monitor.start_rtt(0)
            self._respond(request_id)
        elif command == "startRttPlot":
            self._monitor.start_rtt(int(args.get("channel") or 0))
            self._respond(request_id)
        elif command == "startHss":
            self._monitor.start_hss(args)
            self._respond(request_id)
        elif command == "stopActivity":
            self._monitor.stop_activity()
            self._respond(request_id)
        elif command == "disconnect":
            self._monitor.disconnect()
            self._respond(request_id)
        elif command == "shutdown":
            self._monitor.disconnect()
            self._respond(request_id)
            self._running = False
        else:
            raise WorkerError(f"未知Worker命令：{command}")


def _check() -> int:
    try:
        version = _pyocd_version()
        _validate_pyocd_version(version)
        print(
            json.dumps(
                {
                    "ok": True,
                    "protocolVersion": PROTOCOL_VERSION,
                    "pythonVersion": sys.version.split()[0],
                    "pyocdVersion": version,
                    "profiles": [PROFILE_NON_INTRUSIVE_MONITOR],
                },
                ensure_ascii=False,
            )
        )
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--inspect-probe", action="store_true")
    parser.add_argument("--inspect-usb-device", action="store_true")
    parser.add_argument("--mode", choices=("v1", "v2"))
    parser.add_argument("--vid", type=int)
    parser.add_argument("--pid", type=int)
    args = parser.parse_args()
    if args.check:
        return _check()
    if args.inspect_probe:
        if args.mode is None or args.vid is None or args.pid is None:
            parser.error("--inspect-probe 需要 --mode、--vid 和 --pid")
        return _inspect_usb_pair(args.mode, args.vid, args.pid)
    if args.inspect_usb_device:
        if args.vid is None or args.pid is None:
            parser.error("--inspect-usb-device 需要 --vid 和 --pid")
        return _inspect_usb_device(args.vid, args.pid)
    try:
        version = _pyocd_version()
        _validate_pyocd_version(version)
        logging.basicConfig(
            stream=sys.stderr,
            level=logging.WARNING,
            format="%(levelname)s:%(name)s:%(message)s",
        )
        # 先保留帧协议 stdout 的不可变句柄，再把普通 print 和库输出重定向
        # 到 stderr，防止文本日志混入二进制帧导致 Dart 端协议失步。
        protocol_output = sys.stdout.buffer
        sys.stdout = sys.stderr
        WorkerServer(sys.stdin.buffer, protocol_output).run(sys.stdin.buffer)
        return 0
    except Exception:
        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
