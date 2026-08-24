import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/services/rtt_openocd_backend.dart';

void main() {
  test('OpenOCD RTT 生命周期隔离连接、临时枚举与正式接收', () async {
    final commands = <String>[];
    final lifecycle = OpenOcdRttLifecycle();
    Future<String> execute(String command) async {
      commands.add(command);
      return '';
    }

    expect(lifecycle.isStarted, isFalse);
    await lifecycle.runTemporarily(execute, 25, () async {
      expect(lifecycle.isStarted, isTrue);
      commands.add('list channels');
    });
    expect(lifecycle.isStarted, isFalse);
    expect(commands, [
      'rtt polling_interval 25',
      'rtt start',
      'list channels',
      'rtt stop',
    ]);

    commands.clear();
    await lifecycle.start(execute, 7);
    await lifecycle.start(execute, 7);
    expect(commands, ['rtt polling_interval 7', 'rtt start']);
    await lifecycle.stop(execute);
    await lifecycle.stop(execute);
    expect(commands.last, 'rtt stop');
    expect(lifecycle.isStarted, isFalse);
  });

  test('OpenOCD RTT 通道列表保留 Up 索引、名称和缓冲区信息', () {
    final channels = parseOpenOcdRttChannels('''
Channels: up=3, down=1
Up-channels:
0: Terminal 0 1024 0
1: JScope_i4u4 4096 0
2: Motor plot values 2048 1
Down-channels:
0: Terminal 0 16 0
''');

    expect(channels.map((item) => item.index), [0, 1, 2]);
    expect(channels[1].name, 'JScope_i4u4');
    expect(channels[2].name, 'Motor plot values');
    expect(channels[2].flags, 1);
  });

  test('OpenOCD 高频内存读取结果与普通诊断可区分', () {
    expect(isOpenOcdRealtimeDataLine('0x97 0xfc 0x44 0x1f'), isTrue);
    expect(
      isOpenOcdRealtimeDataLine('Info : [stm32f4x.cpu] Examination succeed'),
      isFalse,
    );
    expect(
      isOpenOcdRealtimeDataLine('Error: target not examined yet'),
      isFalse,
    );
  });

  test('OpenOCD 未插 CMSIS-DAP 时转换为明确中文提示', () async {
    final backend = ExternalOpenOcdBackend(configuredPath: () => '');

    for (final message in [
      'Error: unable to find a matching CMSIS-DAP device',
      'Error: unable to find CMSIS-DAP device',
      'Error: no device found',
    ]) {
      expect(backend.parseFailureDiagnostic(message), contains('未检测到调试探针'));
    }

    await backend.dispose();
  });

  test('OpenOCD 运行中拔出探针的 USB 错误识别为致命断线', () async {
    final backend = ExternalOpenOcdBackend(configuredPath: () => '');

    for (final message in [
      'Error: error submitting USB write: Input/Output Error',
      'Error: error submitting USB read: LIBUSB_ERROR_NO_DEVICE',
      'Error: USB bulk write failed',
    ]) {
      expect(
        backend.parseFatalDisconnectDiagnostic(message),
        contains('USB 连接已中断'),
      );
    }
    expect(
      backend.parseFatalDisconnectDiagnostic('Error: target not examined yet'),
      isNull,
    );

    await backend.dispose();
  });
}
