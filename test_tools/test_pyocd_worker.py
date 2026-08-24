import importlib.util
import io
import json
import struct
import sys
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch


WORKER_PATH = (
    Path(__file__).resolve().parents[1] / "assets" / "runtime" / "pyocd_worker.py"
)
SPEC = importlib.util.spec_from_file_location("vscope_pyocd_worker", WORKER_PATH)
worker = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(worker)


class CaptureWriter:
    def __init__(self):
        self.frames = []

    def send(self, frame_type, request_id, payload):
        self.frames.append((frame_type, request_id, payload))

    def json(self, frame_type, request_id, value):
        self.send(
            frame_type,
            request_id,
            json.dumps(value, ensure_ascii=False).encode("utf-8"),
        )


class FakeMemAp:
    def __init__(self):
        self.memory = {}
        self.accesses = []

    def read32(self, address):
        self.accesses.append(("read32", address, 4))
        return self.memory.get(address, 0)

    def write32(self, address, value):
        self.accesses.append(("write32", address, 4))
        self.memory[address] = value

    def read_memory_block8(self, address, size):
        self.accesses.append(("read8", address, size))
        return [self.memory.get(address + index, 0) for index in range(size)]

    def read_memory_block32(self, address, count):
        self.accesses.append(("read32block", address, count * 4))
        return [self.memory.get(address + index * 4, 0) for index in range(count)]

    def write_memory_block8(self, address, data):
        self.accesses.append(("write8", address, len(data)))
        for index, value in enumerate(data):
            self.memory[address + index] = value


class FakeUp:
    name = "JScope_i4"
    size = 4096

    def __init__(self):
        self.reads = 0

    def read(self):
        self.reads += 1
        return b"\x01\x02" if self.reads == 1 else b""


class FakeDown:
    def __init__(self):
        self.writes = []

    def write(self, data, blocking=False):
        self.writes.append((bytes(data), blocking))
        return len(data)


class FakeRtt:
    def __init__(self):
        self.up_channels = [FakeUp()]
        self.down_channels = [FakeDown()]
        self.started = False

    def start(self):
        self.started = True


class PyOcdWorkerTests(unittest.TestCase):
    def test_frame_protocol_round_trip_and_fragment_safe_header(self):
        stream = io.BytesIO()
        writer = worker.FrameWriter(stream)
        writer.send(worker.FRAME_REQUEST, 42, b"abc")
        raw = stream.getvalue()
        self.assertEqual(raw[:4], b"VSPY")
        self.assertEqual(worker.read_frame(io.BytesIO(raw)), (1, 42, b"abc"))

    def test_explicit_v1_or_v2_discovers_only_selected_usb_backend(self):
        for selected in ("v1", "v2"):
            calls = []

            def find_descriptors(version):
                calls.append(version)
                return [
                    {
                        "id": "probe",
                        "name": "CMSIS-DAP",
                        "vendorId": 0x0D28,
                        "productId": 0x0202,
                        "cmsisDapVersion": version,
                    }
                ]

            with patch.object(
                worker.PyOcdMonitor,
                "_find_probe_descriptors",
                side_effect=find_descriptors,
            ):
                result = worker.PyOcdMonitor.list_probes(
                    {"cmsisDapVersion": selected}
                )
            self.assertEqual(calls, [selected])
            self.assertEqual(result[0]["id"], "probe")
            self.assertIn(f"({selected})", result[0]["name"])

    def test_selected_usb_device_skips_global_usb_pair_scan(self):
        response = types.SimpleNamespace(
            returncode=0,
            stdout=(
                '[{"id":"probe","name":"CMSIS-DAP",'
                '"vendorId":3368,"productId":514,'
                '"cmsisDapVersion":"v2"}]'
            ),
        )
        with patch.object(
            worker,
            "_usb_pairs",
            side_effect=AssertionError("must not scan all USB pairs"),
        ), patch.object(worker.subprocess, "run", return_value=response) as run:
            result = worker.PyOcdMonitor._find_probe_descriptors(
                "v2",
                vendor_id=0x0D28,
                product_id=0x0202,
            )

        self.assertEqual(result[0]["id"], "probe")
        command = run.call_args.args[0]
        self.assertIn("3368", command)
        self.assertIn("514", command)

    def test_monitor_memory_facade_blocks_core_control_and_comparators(self):
        facade = worker.MonitorMemoryTarget(FakeMemAp(), object())
        forbidden = [
            0xE000ED0C,
            0xE000EDF0,
            0xE000EDFC,
            0xE0001000,
            0xE0002000,
        ]
        for address in forbidden:
            with self.subTest(address=hex(address)):
                with self.assertRaises(worker.WorkerError):
                    facade.read32(address)
                with self.assertRaises(worker.WorkerError):
                    facade.write32(address, 0)

    def test_connect_uses_only_probe_dp_and_ap0_then_transport_disconnect(self):
        calls = []

        class Protocol:
            SWD = "swd"
            JTAG = "jtag"

        class DebugProbe:
            pass

        DebugProbe.Protocol = Protocol

        class MemAp(FakeMemAp):
            pass

        class AccessPort:
            @staticmethod
            def create(dp, address):
                calls.append(("create_ap", address.value))
                return MemAp()

        class APv1Address:
            def __init__(self, value):
                self.value = value

        class Probe:
            unique_id = "probe-id"
            wire_protocol = None
            is_open = False

            def open(self):
                calls.append("probe.open")
                self.is_open = True

            def set_clock(self, frequency):
                calls.append(("probe.set_clock", frequency))

            def disconnect(self):
                calls.append("probe.disconnect")
                self.wire_protocol = None

            def close(self):
                calls.append("probe.close")
                self.is_open = False

        Probe.__module__ = "pyocd.probe.cmsis_dap_probe"

        class Dp:
            adi_version = types.SimpleNamespace(name="ADIv5")

            def connect(self, protocol):
                calls.append(("dp.connect", protocol))
                probe.wire_protocol = protocol

        class Target:
            dp = Dp()

            def get_memory_map(self):
                return object()

        probe = Probe()
        board = types.SimpleNamespace(target=Target(), target_type="stm32f407zg")
        session = types.SimpleNamespace(probe=probe, board=board)

        def create_session(selected_probe, **kwargs):
            calls.append(("create_session", selected_probe, kwargs))
            return session

        modules = {
            "pyocd": types.ModuleType("pyocd"),
            "pyocd.core": types.ModuleType("pyocd.core"),
            "pyocd.core.session": types.ModuleType("pyocd.core.session"),
            "pyocd.coresight": types.ModuleType("pyocd.coresight"),
            "pyocd.coresight.ap": types.ModuleType("pyocd.coresight.ap"),
            "pyocd.probe": types.ModuleType("pyocd.probe"),
            "pyocd.probe.debug_probe": types.ModuleType(
                "pyocd.probe.debug_probe"
            ),
        }
        modules["pyocd.core.session"].Session = create_session
        modules["pyocd.coresight.ap"].APv1Address = APv1Address
        modules["pyocd.coresight.ap"].AccessPort = AccessPort
        modules["pyocd.coresight.ap"].MEM_AP = MemAp
        modules["pyocd.probe.debug_probe"].DebugProbe = DebugProbe

        monitor = worker.PyOcdMonitor(CaptureWriter())
        with patch.dict(sys.modules, modules), patch.object(
            worker.PyOcdMonitor,
            "_find_probes",
            return_value=[probe],
        ):
            result = monitor.connect(
                {
                    "profile": "nonIntrusiveMonitor",
                    "probeId": "probe-id",
                    "target": "stm32f407zg",
                    "wireProtocol": "swd",
                    "clockKhz": 2000,
                    "cmsisDapVersion": "v2",
                }
            )
            monitor.disconnect()

        self.assertEqual(result["profile"], "nonIntrusiveMonitor")
        self.assertIn(("dp.connect", "swd"), calls)
        self.assertIn(("create_ap", 0), calls)
        self.assertIn("probe.disconnect", calls)
        self.assertIn("probe.close", calls)
        self.assertFalse(
            any(
                name in repr(calls)
                for name in (
                    "Session.open",
                    "Session.close",
                    "Target.init",
                    "Target.disconnect",
                    "CortexM.init",
                )
            )
        )

    def test_rtt_three_locations_metadata_up_down_and_stop(self):
        capture = CaptureWriter()
        monitor = worker.PyOcdMonitor(capture)
        monitor._target = worker.MonitorMemoryTarget(FakeMemAp(), object())
        created = []

        class FakeControlBlock:
            @classmethod
            def from_target(cls, target, address=None, size=None, **_):
                rtt = FakeRtt()
                created.append((address, size, rtt))
                return rtt

        fake_module = types.ModuleType("pyocd.debug.rtt")
        fake_module.RTTControlBlock = FakeControlBlock
        with patch.dict(sys.modules, {"pyocd.debug.rtt": fake_module}):
            cases = [
                ({"mode": "automatic"}, (None, None)),
                ({"mode": "address", "address": 0x20000410}, (0x20000410, 0)),
                (
                    {
                        "mode": "range",
                        "rangeStart": 0x20000000,
                        "rangeEnd": 0x20010000,
                    },
                    (0x20000000, 0x10000),
                ),
            ]
            for config, expected in cases:
                monitor.configure_rtt({**config, "pollingIntervalMs": 1})
                channels = monitor.list_rtt_channels()
                self.assertEqual(created[-1][:2], expected)
                self.assertTrue(created[-1][2].started)
                self.assertEqual(channels[0]["name"], "JScope_i4")
                self.assertEqual(channels[0]["size"], 4096)

            monitor.start_rtt(0)
            time.sleep(0.02)
            monitor.stop_activity()
            rtt_frames = [
                frame for frame in capture.frames if frame[0] == worker.FRAME_RTT_DATA
            ]
            self.assertTrue(rtt_frames)
            channel = struct.unpack("<H", rtt_frames[0][2][:2])[0]
            self.assertEqual(channel, 0)
            self.assertEqual(rtt_frames[0][2][2:], b"\x01\x02")
            self.assertEqual(monitor.write_down0(b"down"), 4)
            self.assertEqual(created[-1][2].down_channels[0].writes, [(b"down", False)])

    def test_hss_decodes_values_and_stops(self):
        capture = CaptureWriter()
        mem = FakeMemAp()
        raw = struct.pack("<If", 1234, 2.5)
        for index, value in enumerate(raw):
            mem.memory[0x20000000 + index] = value
        monitor = worker.PyOcdMonitor(capture)
        monitor._target = worker.MonitorMemoryTarget(mem, object())
        monitor.start_hss(
            {
                "frequencyHz": 100,
                "variables": [
                    {"address": 0x20000000, "type": "uint32"},
                    {"address": 0x20000004, "type": "float32"},
                ],
            }
        )
        time.sleep(0.03)
        monitor.stop_activity()
        samples = [
            frame for frame in capture.frames if frame[0] == worker.FRAME_SAMPLE_DATA
        ]
        self.assertTrue(samples)
        _, count = struct.unpack("<QH", samples[0][2][:10])
        values = struct.unpack("<2d", samples[0][2][10:])
        self.assertEqual(count, 2)
        self.assertEqual(values[0], 1234.0)
        self.assertAlmostEqual(values[1], 2.5)

    def test_every_privileged_command_is_rejected_before_dispatch(self):
        for request_id, command in enumerate(
            sorted(worker.FORBIDDEN_MONITOR_COMMANDS), start=1
        ):
            payload = json.dumps({"command": command, "args": {}}).encode()
            raw = worker.HEADER.pack(
                worker.MAGIC,
                worker.PROTOCOL_VERSION,
                worker.FRAME_REQUEST,
                0,
                request_id,
                len(payload),
            ) + payload
            output = io.BytesIO()
            server = worker.WorkerServer(io.BytesIO(raw), output)
            server.run(io.BytesIO(raw))
            frame = worker.read_frame(io.BytesIO(output.getvalue()))
            self.assertIsNotNone(frame)
            response = json.loads(frame[2])
            self.assertFalse(response["ok"])
            self.assertIn("nonIntrusiveMonitor禁止操作", response["error"])

    def test_unknown_command_is_not_future_permission_escape(self):
        payload = json.dumps(
            {"command": "futurePowerfulOperation", "args": {}}
        ).encode()
        raw = worker.HEADER.pack(
            worker.MAGIC,
            worker.PROTOCOL_VERSION,
            worker.FRAME_REQUEST,
            0,
            1,
            len(payload),
        ) + payload
        output = io.BytesIO()
        server = worker.WorkerServer(io.BytesIO(raw), output)
        server.run(io.BytesIO(raw))
        response = json.loads(worker.read_frame(io.BytesIO(output.getvalue()))[2])
        self.assertFalse(response["ok"])
        self.assertIn("未授权操作", response["error"])


if __name__ == "__main__":
    unittest.main()
