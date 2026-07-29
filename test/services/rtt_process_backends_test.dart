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
    expect(
      parseOpenOcdVersion('Open On-Chip Debugger 0.12.0+dev-01234'),
      'v0.12.0+dev-01234',
    );
    expect(parseJlinkVersion('unknown'), isNull);
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

  test('OpenOCD 配置选择器定位到 scripts 下对应类别目录', () async {
    final root = await Directory.systemTemp.createTemp('vscope-openocd-');
    addTearDown(() => root.delete(recursive: true));
    final executable = File(
      '${root.path}${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}openocd.exe',
    );
    await executable.parent.create(recursive: true);
    await executable.create();
    final interfaceDirectory = Directory(
      '${root.path}${Platform.pathSeparator}openocd'
      '${Platform.pathSeparator}scripts'
      '${Platform.pathSeparator}interface',
    );
    final targetDirectory = Directory(
      '${root.path}${Platform.pathSeparator}openocd'
      '${Platform.pathSeparator}scripts'
      '${Platform.pathSeparator}target',
    );
    await interfaceDirectory.create(recursive: true);
    await targetDirectory.create(recursive: true);

    expect(
      await findOpenOcdConfigDirectory(executable.path, 'interface'),
      interfaceDirectory.absolute.path,
    );
    expect(
      await findOpenOcdConfigDirectory(executable.path, 'target'),
      targetDirectory.absolute.path,
    );
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
        pollingIntervalMs: 77,
      ),
      19021,
    );

    expect(arguments, contains('-nohalt'));
    expect(arguments, contains('-noir'));
    expect(arguments, isNot(contains('-halt')));
    expect(arguments.join(' '), isNot(contains('polling_interval')));
    expect(backend.guaranteesNonIntrusiveTargetAccess, isTrue);
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

  test('OpenOCD 连接阶段只初始化目标，不配置或启动 RTT', () async {
    final backend = ExternalOpenOcdBackend(configuredPath: () => '');
    final arguments = await backend.buildArguments(
      const RttConnectionConfig(
        probeKind: RttProbeKind.cmsisDap,
        target: '',
        wireProtocol: RttWireProtocol.swd,
        clockKhz: 2000,
        controlBlockMode: RttControlBlockMode.range,
        controlBlockRangeStart: 0x20000000,
        controlBlockRangeEnd: 0x20010000,
        openOcdInterfaceConfig: 'interface/cmsis-dap.cfg',
        openOcdTargetConfig: 'target/stm32f4x.cfg',
      ),
      19021,
    );

    expect(
      arguments,
      containsAllInOrder([
        '-f',
        'interface/cmsis-dap.cfg',
        '-c',
        'transport select swd',
        '-f',
        'target/stm32f4x.cfg',
        '-c',
        'gdb port disabled',
        '-c',
        'telnet port disabled',
        '-c',
        startsWith('tcl port '),
      ]),
    );
    expect(arguments, isNot(contains('gdb_port disabled')));
    expect(arguments, isNot(contains('telnet_port disabled')));
    expect(arguments.where((item) => item.startsWith('tcl_port ')), isEmpty);
    expect(arguments, contains('adapter speed 2000'));
    expect(arguments, isNot(contains('halt')));
    expect(arguments, isNot(contains('reset')));
    expect(arguments, isNot(contains('resume')));
    expect(arguments.where((item) => item.startsWith('rtt setup ')), isEmpty);
    expect(arguments, isNot(contains('rtt polling_interval 10')));
    expect(arguments, isNot(contains('rtt start')));
    expect(
      arguments.where((item) => item.startsWith('rtt server start ')),
      isEmpty,
    );
    expect(backend.guaranteesNonIntrusiveTargetAccess, isTrue);
    await backend.dispose();
  });

  test('外部进程报告未插探针时立即失败而不是等待启动超时', () async {
    final backend = _ImmediateFailureBackend();
    addTearDown(backend.dispose);
    final stopwatch = Stopwatch()..start();

    await expectLater(
      backend.connect(
        const RttConnectionConfig(probeKind: RttProbeKind.cmsisDap, target: ''),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => '$error',
          'message',
          contains('未检测到调试探针'),
        ),
      ),
    );

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('OpenOCD RTT 不接受 Auto 控制块定位', () async {
    final backend = ExternalOpenOcdBackend(configuredPath: () => '');

    expect(
      () => backend.configureRttControlBlock(
        const RttControlBlockConfig(mode: RttControlBlockMode.automatic),
      ),
      throwsA(isA<FormatException>()),
    );
    await backend.dispose();
  });

  test('主动关闭延迟 RTT Socket 不会把目标进程连接标记为断开', () async {
    final backend = _DeferredTransportBackend();
    addTearDown(backend.dispose);
    await backend.connect(
      const RttConnectionConfig(probeKind: RttProbeKind.cmsisDap, target: ''),
    );
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      backend.rttTransportPort,
    );
    addTearDown(server.close);
    final accepted = server.first;

    await backend.ensureRttTransportConnected();
    final peer = await accepted;
    addTearDown(peer.close);
    expect(backend.isConnected, isTrue);

    await backend.closeRttTransport();
    await Future<void>.delayed(Duration.zero);

    expect(backend.isConnected, isTrue);
  });
}

class _ImmediateFailureBackend extends TcpProcessRttBackend {
  @override
  String get id => 'immediate-failure';

  @override
  String get displayName => '测试后端';

  @override
  bool get guaranteesNonIntrusiveTargetAccess => true;

  @override
  String? get nonIntrusiveSafetyBlockReason => null;

  @override
  Duration get startupTimeout => const Duration(seconds: 5);

  @override
  Future<String?> executablePath(RttProbeKind kind) async =>
      Platform.isWindows
          ? (Platform.environment['ComSpec'] ?? r'C:\Windows\System32\cmd.exe')
          : '/bin/sh';

  @override
  Future<List<String>> buildArguments(
    RttConnectionConfig config,
    int port,
  ) async =>
      Platform.isWindows
          ? [
            '/d',
            '/s',
            '/c',
            'echo NO_PROBE_MARKER 1>&2 & ping -n 11 127.0.0.1 >nul',
          ]
          : ['-c', 'echo NO_PROBE_MARKER >&2; sleep 10'];

  @override
  String? parseFailureDiagnostic(String line) =>
      line.contains('NO_PROBE_MARKER') ? '未检测到调试探针' : null;

  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async => const [];

  @override
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) async => const [];
}

class _DeferredTransportBackend extends TcpProcessRttBackend {
  @override
  String get id => 'deferred-transport';
  @override
  String get displayName => '延迟传输测试后端';
  @override
  bool get guaranteesNonIntrusiveTargetAccess => true;
  @override
  String? get nonIntrusiveSafetyBlockReason => null;
  @override
  bool get connectRttSocketOnConnect => false;
  @override
  Duration get startupStabilityDuration => const Duration(milliseconds: 50);

  @override
  Future<String?> executablePath(RttProbeKind kind) async =>
      Platform.isWindows
          ? (Platform.environment['ComSpec'] ?? r'C:\Windows\System32\cmd.exe')
          : '/bin/sh';

  @override
  Future<List<String>> buildArguments(
    RttConnectionConfig config,
    int port,
  ) async =>
      Platform.isWindows
          ? ['/d', '/s', '/c', 'ping -n 11 127.0.0.1 >nul']
          : ['-c', 'sleep 10'];

  @override
  Future<List<RttProbeInfo>> listProbes(RttProbeKind kind) async => const [];
  @override
  Future<List<RttTargetInfo>> listTargets(RttProbeKind kind) async => const [];
}
