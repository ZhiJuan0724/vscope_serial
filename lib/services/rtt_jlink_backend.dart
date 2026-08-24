import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/utils/app_logger.dart';
import '../data/models/probe_connection_config.dart';
import 'probe_backend.dart';
import 'rtt_process_backend_base.dart';
import 'windows_file_version.dart';

class ExternalJLinkBackend extends TcpProcessProbeBackend
    implements ProbeBackendVersionProvider {
  ExternalJLinkBackend({
    required this.configuredPath,
    this.fileVersionReader = readWindowsFileVersion,
  });

  final String Function() configuredPath;
  final String? Function(String path) fileVersionReader;
  final JlinkRttBannerFilter _bannerFilter = JlinkRttBannerFilter();

  @override
  String get id => 'external-jlink';
  @override
  String get displayName => '外部 J-Link';
  @override
  bool get guaranteesNonIntrusiveTargetAccess => true;
  @override
  String? get nonIntrusiveSafetyBlockReason => null;
  @override
  Duration get startupStabilityDuration => const Duration(milliseconds: 1500);
  @override
  bool get connectRttSocketOnConnect => false;
  @override
  void resetRttDataFilter() => _bannerFilter.reset();
  @override
  Uint8List filterRttData(Uint8List data) => _bannerFilter.add(data);
  @override
  String? parseFailureDiagnostic(String line) =>
      parseJlinkConnectionFailure(line);

  @override
  Future<String?> executablePath(ProbeKind kind) async {
    if (kind != ProbeKind.jlink) return null;
    return findRttExecutable(
      configuredPath(),
      'JLinkGDBServerCL.exe',
      extraDirectories: [
        if (Platform.environment['ProgramFiles'] case final path?)
          '$path\\SEGGER',
        if (Platform.environment['ProgramFiles(x86)'] case final path?)
          '$path\\SEGGER',
      ],
    );
  }

  @override
  Future<String?> detectVersion(ProbeKind kind) async {
    final executable = await executablePath(kind);
    if (executable == null) return null;
    final resourceVersion = fileVersionReader(executable);
    if (resourceVersion != null) return normalizeJlinkVersion(resourceVersion);
    return parseJlinkVersionFromPath(executable);
  }

  @override
  Future<List<ProbeInfo>> listProbes(ProbeKind kind) async {
    final gdbServer = await executablePath(kind);
    if (gdbServer == null) return const [];
    final commander = File(
      '${File(gdbServer).parent.path}${Platform.pathSeparator}JLink.exe',
    );
    if (await commander.exists()) {
      final commandFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'serialtools-jlink-list-${DateTime.now().microsecondsSinceEpoch}.jlink',
      );
      try {
        await commandFile.writeAsString('ShowEmuList USB\nExit\n', flush: true);
        final process = await Process.start(commander.path, [
          '-NoGui',
          '1',
          '-ExitOnError',
          '1',
          '-CommandFile',
          commandFile.path,
        ], runInShell: false);
        final stdout = process.stdout.transform(utf8.decoder).join();
        final stderr = process.stderr.transform(utf8.decoder).join();
        try {
          await process.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          process.kill();
          throw TimeoutException('J-Link Commander 探针枚举超时');
        }
        final probes = parseJlinkProbeList('${await stdout}\n${await stderr}');
        if (probes.isNotEmpty) return probes;
      } catch (error) {
        AppLogger().warning('J-Link 探针枚举失败: $error', category: 'RTT');
      } finally {
        if (await commandFile.exists()) await commandFile.delete();
      }
    }
    return const [
      ProbeInfo(id: '', name: 'J-Link（自动选择）', kind: ProbeKind.jlink),
    ];
  }

  @override
  Future<List<ProbeTargetInfo>> listTargets(ProbeKind kind) async {
    final executable = await executablePath(kind);
    if (executable == null) return const [];
    final root = File(executable).parent;
    final names = <String>{};
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File ||
          !entity.path.toLowerCase().endsWith('jlinkdevices.xml')) {
        continue;
      }
      try {
        final content = await entity.readAsString();
        for (final match in RegExp(
          r'(?:Name|ChipName)\s*=\s*"([^"]+)"',
          caseSensitive: false,
        ).allMatches(content)) {
          final name = match.group(1)?.trim();
          if (name != null && name.isNotEmpty) names.add(name);
        }
      } catch (error) {
        AppLogger().warning(
          '读取 J-Link 设备数据库失败: ${entity.path}, $error',
          category: 'RTT',
        );
      }
    }
    return names
        .map((name) => ProbeTargetInfo(name: name, source: 'J-Link'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Future<List<String>> buildArguments(
    ProbeConnectionConfig config,
    int port,
  ) async {
    if (config.autoDetectTarget || config.target.trim().isEmpty) {
      throw const FormatException('J-Link 外部模式必须手动选择目标芯片');
    }
    final gdbPort = await reserveBackendPort();
    return [
      '-device',
      config.target,
      '-if',
      config.wireProtocol == ProbeWireProtocol.swd ? 'SWD' : 'JTAG',
      '-speed',
      '${config.clockKhz}',
      if (config.probeId.isNotEmpty) ...['-USB', config.probeId],
      '-port',
      '$gdbPort',
      '-RTTTelnetPort',
      '$port',
      '-nohalt',
      '-noir',
      '-singlerun',
      '-nogui',
    ];
  }

  @override
  Future<void> configureRttSocket(
    Socket socket,
    ProbeConnectionConfig config,
  ) async {
    final command = buildJlinkRttConfigString(config);
    if (command == null) return;
    socket.add(utf8.encode(command));
    await socket.flush();
  }

  @override
  Future<void> stopActivity() async {
    final config = connectionConfig;
    // J-Link GDB Server 没有公开与 `rtt stop` 对等的严格停止命令。
    // 杀死含 RTT Telnet 客户端的旧进程，再以同一参数建立不接收 RTT
    // 的空闲目标会话，确保上一轮后台轮询不会残留。
    await super.disconnect();
    await super.connect(config);
  }
}

class JlinkRttBannerFilter {
  static const int _maxProbeBytes = 4096;
  final List<int> _pending = [];
  int _removedLines = 0;
  bool _complete = false;

  Uint8List add(Uint8List data) {
    if (_complete || data.isEmpty) return data;
    _pending.addAll(data);
    if (_pending.length > _maxProbeBytes) return _finish();
    if (_removedLines == 0 && _pending.length >= 16) {
      final prefix = ascii.decode(
        _pending.take(16).toList(growable: false),
        allowInvalid: true,
      );
      if (!prefix.startsWith('SEGGER J-Link')) return _finish();
    }
    while (true) {
      final newline = _pending.indexOf(0x0a);
      if (newline < 0) return Uint8List(0);
      final line =
          ascii
              .decode(_pending.sublist(0, newline + 1), allowInvalid: true)
              .trim();
      if (!_isJlinkBannerLine(line)) return _finish();
      _pending.removeRange(0, newline + 1);
      _removedLines++;
      if (_removedLines >= 3) return _finish();
    }
  }

  void reset() {
    _pending.clear();
    _removedLines = 0;
    _complete = false;
  }

  Uint8List _finish() {
    _complete = true;
    final output = Uint8List.fromList(_pending);
    _pending.clear();
    return output;
  }
}

bool _isJlinkBannerLine(String line) {
  if (line.startsWith('SEGGER J-Link') &&
      line.contains('Real time terminal output')) {
    return true;
  }
  if (line.startsWith('SEGGER J-Link') && line.contains('SN=')) return true;
  return line == 'Process: JLinkGDBServerCL.exe';
}

String? parseJlinkConnectionFailure(String line) {
  final lower = line.toLowerCase();
  if (RegExp(r'target voltage:\s*0(?:\.0+)?\s*v').hasMatch(lower)) {
    return 'J-Link 未检测到目标板供电，请检查目标板电源、地线和调试接口';
  }
  if (lower.contains('could not connect to target') ||
      lower.contains('cannot connect to target') ||
      lower.contains('failed to connect to target') ||
      lower.contains('target connection failed')) {
    return 'J-Link 无法连接目标芯片，请检查供电、接线、芯片型号和调试接口';
  }
  if (lower.contains('no emulators connected') ||
      lower.contains('cannot connect to j-link')) {
    return '无法连接 J-Link 探针，请检查 USB 连接和探针占用状态';
  }
  if (lower.contains('error:')) return 'J-Link：${line.trim()}';
  return null;
}

String? buildJlinkRttConfigString(ProbeConnectionConfig config) {
  switch (config.controlBlockMode) {
    case RttControlBlockMode.automatic:
      return null;
    case RttControlBlockMode.address:
      final address = config.controlBlockAddress;
      if (address == null || address < 0) {
        throw const FormatException('指定地址模式需要有效的 RTT 控制块地址');
      }
      return r'$$SEGGER_TELNET_ConfigStr=SetRTTAddr;'
          '0x${address.toRadixString(16)};'
          r'$$';
    case RttControlBlockMode.range:
      final start = config.controlBlockRangeStart;
      final end = config.controlBlockRangeEnd;
      if (start == null || start < 0 || end == null || end <= start) {
        throw const FormatException('指定范围模式需要有效的起始地址和结束地址');
      }
      return r'$$SEGGER_TELNET_ConfigStr=SetRTTSearchRanges;'
          '0x${start.toRadixString(16)} 0x${(end - start).toRadixString(16)};'
          r'$$';
  }
}

List<ProbeInfo> parseJlinkProbeList(String output) {
  final probes = <ProbeInfo>[];
  final pattern = RegExp(
    r'J-Link\[\d+\]:.*?Serial number:\s*([^,\r\n]+)'
    r'(?:,\s*ProductName:\s*([^\r\n]+))?',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(output)) {
    final serial = match.group(1)?.trim() ?? '';
    if (serial.isEmpty) continue;
    final product = match.group(2)?.trim();
    probes.add(
      ProbeInfo(
        id: serial,
        name:
            product == null || product.isEmpty
                ? 'J-Link ($serial)'
                : '$product ($serial)',
        kind: ProbeKind.jlink,
      ),
    );
  }
  return probes;
}

String? parseJlinkVersion(String output) {
  final match = RegExp(
    r'J-Link GDB Server\s+V(\d+(?:\.\d+)*(?:[A-Za-z]+\d*)?)',
    caseSensitive: false,
  ).firstMatch(output);
  return match == null ? null : 'v${match.group(1)}';
}

String? normalizeJlinkVersion(String value) {
  final match = RegExp(
    r'v?(\d+(?:\.\d+)+(?:[A-Za-z]+\d*)?)',
    caseSensitive: false,
  ).firstMatch(value.trim());
  return match == null ? null : 'v${match.group(1)}';
}

String? parseJlinkVersionFromPath(String path) {
  final match = RegExp(
    r'JLink[_ -]?V?(\d)(\d{2})([A-Za-z]?)',
    caseSensitive: false,
  ).firstMatch(path);
  if (match == null) return null;
  return 'v${match.group(1)}.${match.group(2)}${match.group(3)}';
}
