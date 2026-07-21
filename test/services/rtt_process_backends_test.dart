import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/rtt_config.dart';
import 'package:vscope_serial/services/rtt_process_backends.dart';
import 'package:vscope_serial/services/windows_file_version.dart';

void main() {
  test('RTT 外部工具版本输出统一为带 v 的版本号', () {
    expect(
      parseJlinkVersion('SEGGER J-Link GDB Server V8.24a Command Line Version'),
      'v8.24a',
    );
    expect(parsePyOcdVersion('0.44.0'), 'v0.44.0');
    expect(parseJlinkVersion('unknown'), isNull);
    expect(parsePyOcdVersion('unknown'), isNull);
    expect(normalizeJlinkVersion('V7.52d'), 'v7.52d');
    expect(normalizeJlinkVersion('7.52.4.0'), 'v7.52.4.0');
    expect(
      parseJlinkVersionFromPath(r'C:\SEGGER\JLink_V752d\JLink.exe'),
      'v7.52d',
    );
  });

  test('J-Link 版本检测读取文件资源而不启动 GDB Server', () async {
    var requestedPath = '';
    final backend = ExternalJLinkBackend(
      configuredPath: () => Platform.resolvedExecutable,
      fileVersionReader: (path) {
        requestedPath = path;
        return 'V7.52d';
      },
    );

    expect(await backend.detectVersion(RttProbeKind.jlink), 'v7.52d');
    expect(requestedPath, File(Platform.resolvedExecutable).absolute.path);
    await backend.dispose();
  });

  test('Windows 文件版本读取器可直接读取系统文件资源', () {
    if (!Platform.isWindows) return;
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final version = readWindowsFileVersion(
      '$systemRoot${Platform.pathSeparator}System32'
      '${Platform.pathSeparator}kernel32.dll',
    );

    expect(version, isNotNull);
    expect(normalizeJlinkVersion(version!), isNotNull);
  });

  test('J-Link Commander 输出保留探针序列号和型号', () {
    final probes = parseJlinkProbeList(
      'J-Link[0]: Connection: USB, Serial number: 203201228, '
      'ProductName: J-Trace Cortex-M\r\n'
      'J-Link[1]: Connection: USB, Serial number: 580011111, '
      'ProductName: J-Link Plus\r\n',
    );

    expect(probes.map((probe) => probe.id), ['203201228', '580011111']);
    expect(probes.first.name, 'J-Trace Cortex-M (203201228)');
  });

  test('J-Link RTT 配置串区分 Auto、地址和范围', () {
    expect(
      buildJlinkRttConfigString(
        const RttConnectionConfig(probeKind: RttProbeKind.jlink, target: 'T'),
      ),
      isNull,
    );
    expect(
      buildJlinkRttConfigString(
        const RttConnectionConfig(
          probeKind: RttProbeKind.jlink,
          target: 'T',
          controlBlockMode: RttControlBlockMode.address,
          controlBlockAddress: 0x20001000,
        ),
      ),
      r'$$SEGGER_TELNET_ConfigStr=SetRTTAddr;0x20001000;$$',
    );
    expect(
      buildJlinkRttConfigString(
        const RttConnectionConfig(
          probeKind: RttProbeKind.jlink,
          target: 'T',
          controlBlockMode: RttControlBlockMode.range,
          controlBlockRangeStart: 0x20000000,
          controlBlockRangeEnd: 0x20010000,
        ),
      ),
      r'$$SEGGER_TELNET_ConfigStr=SetRTTSearchRanges;0x20000000 0x10000;$$',
    );
  });

  test('J-Link RTT 启动时保持目标核运行', () async {
    final backend = ExternalJLinkBackend(configuredPath: () => '');
    final arguments = await backend.buildArguments(
      const RttConnectionConfig(
        probeKind: RttProbeKind.jlink,
        target: 'TEST_DEVICE',
      ),
      19021,
    );

    expect(arguments, contains('-nohalt'));
    expect(arguments, isNot(contains('-halt')));
    await backend.dispose();
  });

  test('J-Link RTT Telnet banner 被过滤且保留同块目标输出', () {
    final filter = JlinkRttBannerFilter();
    final first = filter.add(
      Uint8List.fromList(
        utf8.encode(
          'SEGGER J-Link V7.52d - Real time terminal output\r\n'
          'SEGGER J-Link ARM V9.7, SN=602712939\r\n',
        ),
      ),
    );
    final second = filter.add(
      Uint8List.fromList(
        utf8.encode('Process: JLinkGDBServerCL.exe\r\ntarget output\n'),
      ),
    );

    expect(first, isEmpty);
    expect(utf8.decode(second), 'target output\n');
  });

  test('J-Link 常见连接错误转换为明确提示', () {
    expect(
      parseJlinkConnectionFailure('Target voltage: 0.000 V'),
      contains('目标板供电'),
    );
    expect(
      parseJlinkConnectionFailure('ERROR: Could not connect to target.'),
      contains('无法连接目标芯片'),
    );
  });

  test('pyOCD JSON 探针枚举保留短 UID 和非十六进制 UID', () {
    final probes = parsePyOcdProbeJson(
      jsonEncode({
        'status': 0,
        'boards': [
          {
            'unique_id': 'DAP-42',
            'info': 'Arm CMSIS-DAP v2',
            'product_name': 'CMSIS-DAP',
          },
        ],
      }),
    );

    expect(probes.single.id, 'DAP-42');
    expect(probes.single.name, contains('Arm CMSIS-DAP v2'));
  });

  test('pyOCD JSON 目标列表读取名称、厂商和来源', () {
    final targets = parsePyOcdTargetJson(
      jsonEncode({
        'status': 0,
        'targets': [
          {'name': 'stm32f407vg', 'vendor': 'ST', 'source': 'builtin'},
        ],
      }),
    );

    expect(targets.single.name, 'stm32f407vg');
    expect(targets.single.vendor, 'ST');
    expect(targets.single.source, 'builtin');
  });

  test('pyOCD 无探针输出转换为明确连接提示', () async {
    final backend = ExternalPyOcdBackend(configuredPath: () => '');

    expect(
      backend.parseFailureDiagnostic('No connected debug probes'),
      contains('未检测到 CMSIS-DAP 探针'),
    );
    expect(
      backend.parseFailureDiagnostic('No target device available'),
      contains('未检测到 CMSIS-DAP 探针'),
    );
    await backend.dispose();
  });

  test('pyOCD RTT 使用独立子命令、附着模式和指定搜索范围', () async {
    final backend = ExternalPyOcdBackend(configuredPath: () => '');
    final arguments = await backend.buildArguments(
      const RttConnectionConfig(
        probeKind: RttProbeKind.cmsisDap,
        target: 'test_target',
        probeId: 'DAP-42',
        controlBlockMode: RttControlBlockMode.range,
        controlBlockRangeStart: 0x20000000,
        controlBlockRangeEnd: 0x20010000,
      ),
      19021,
    );

    expect(arguments.first, 'rtt');
    expect(arguments, isNot(contains('gdbserver')));
    expect(arguments, containsAllInOrder(['--connect', 'attach']));
    expect(arguments, containsAllInOrder(['--uid', 'DAP-42']));
    expect(
      arguments,
      containsAllInOrder(['--address', '0x20000000', '--size', '0x10000']),
    );
    expect(arguments, contains('resume_on_disconnect=true'));
    await backend.dispose();
  });

  test('pyOCD RTT 指定地址不要求同时填写搜索范围', () async {
    final backend = ExternalPyOcdBackend(configuredPath: () => '');
    final arguments = await backend.buildArguments(
      const RttConnectionConfig(
        probeKind: RttProbeKind.cmsisDap,
        target: 'test_target',
        controlBlockMode: RttControlBlockMode.address,
        controlBlockAddress: 0x20001000,
      ),
      0,
    );

    expect(arguments, containsAllInOrder(['--address', '0x20001000']));
    expect(arguments, isNot(contains('--size')));
    await backend.dispose();
  });
}
