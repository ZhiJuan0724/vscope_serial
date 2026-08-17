import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/data_packet.dart';
import 'package:vscope_serial/data/models/modbus_models.dart';
import 'package:vscope_serial/services/modbus_client_service.dart';
import 'package:vscope_serial/services/modbus_codec.dart';
import 'package:vscope_serial/services/modbus_profile_service.dart';

class _FakeLink implements ModbusDataLink {
  final controller = StreamController<DataPacket>.broadcast();
  final disconnectController = StreamController<void>.broadcast();
  bool connected = true;
  bool acquired = false;
  int sendCount = 0;
  bool failSend = false;
  void Function(Uint8List data)? onSend;

  @override
  bool acquire() => acquired ? true : (acquired = true);

  @override
  Stream<DataPacket> get dataStream => controller.stream;

  @override
  Stream<void> get disconnectStream => disconnectController.stream;

  @override
  bool get isConnected => connected;

  @override
  void release() => acquired = false;

  @override
  Future<void> send(Uint8List data) async {
    sendCount++;
    if (failSend) throw StateError('写入失败');
    onSend?.call(data);
  }

  Future<void> close() async {
    await controller.close();
    await disconnectController.close();
  }
}

ModbusRegisterPage _page({
  bool enabled = false,
  List<ModbusRegisterRow> rows = const [],
  ModbusRegisterArea area = ModbusRegisterArea.holdingRegisters,
}) => ModbusRegisterPage(unitId: 1, area: area, enabled: enabled, rows: rows);

ModbusRegisterRow _row({
  String id = 'row',
  int address = 0,
  bool poll = false,
  bool send = false,
  int pollIntervalMs = 1000,
  int sendIntervalMs = 1000,
  ModbusVariableType type = ModbusVariableType.u16,
  ModbusSendValueMode sendMode = ModbusSendValueMode.fixed,
  String sendValue = '0',
}) => ModbusRegisterRow(
  id: id,
  address: address,
  variableType: type,
  pollEnabled: poll,
  sendEnabled: send,
  pollIntervalMs: pollIntervalMs,
  sendIntervalMs: sendIntervalMs,
  sendMode: sendMode,
  sendValue: sendValue,
);

void _respondRead(_FakeLink link, {int value = 42}) {
  final body = Uint8List.fromList([1, 3, 2, value >> 8, value & 0xFF]);
  final crc = ModbusCodec.crc16(body);
  scheduleMicrotask(
    () => link.controller.add(
      DataPacket(data: Uint8List.fromList([...body, crc & 0xFF, crc >> 8])),
    ),
  );
}

void main() {
  test('Modbus配置ID不能越出配置目录', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vscope_modbus_profile_id_test_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final service = ModbusProfileService(directoryOverride: directory);
    await service.init();
    await expectLater(
      service.save(
        const ModbusProfile(
          id: '../outside',
          name: '非法配置',
          source: '{"schemaVersion":1,"modbus":{}}',
        ),
      ),
      throwsFormatException,
    );
  });

  test('Modbus配置自动保存且重命名默认配置后补建空默认配置', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vscope_modbus_profile_test_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final link = _FakeLink();
    addTearDown(link.close);
    final profileService = ModbusProfileService(directoryOverride: directory);
    final service = ModbusClientService(link, profileService: profileService);

    await service.initializeProfiles();
    expect(service.selectedProfile?.name, '默认配置');
    expect(service.pages, isEmpty);

    service.addPage(_page(rows: [_row()]));
    final shared = File('${directory.path}/shared.json');
    await service.exportSelectedProfile(shared.path);
    expect(await shared.readAsString(), contains('"unitId": 1'));

    await service.renameSelectedProfile('现场设备');
    expect(service.selectedProfile?.name, '现场设备');
    expect(service.profiles.map((profile) => profile.name), contains('默认配置'));
    final defaultProfile = service.profiles.firstWhere(
      (profile) => profile.name == '默认配置',
    );
    await service.selectProfile(defaultProfile.id);
    expect(service.pages, isEmpty);

    await service.importProfile(shared.path);
    expect(service.selectedProfile?.id, isNot(defaultProfile.id));
    expect(service.pages, hasLength(1));
    expect(service.profiles.map((profile) => profile.name), contains('默认配置'));
  });

  test('手动请求排队一次并解析拆分响应', () async {
    final link = _FakeLink();
    addTearDown(link.close);
    final service = ModbusClientService(link, timeoutMs: 500);
    link.onSend = (_) {
      final body = Uint8List.fromList([1, 3, 2, 0, 42]);
      final crc = ModbusCodec.crc16(body);
      scheduleMicrotask(() {
        link.controller.add(
          DataPacket(
            data: Uint8List.sublistView(
              Uint8List.fromList([...body, crc & 0xFF, crc >> 8]),
              0,
              3,
            ),
          ),
        );
        link.controller.add(
          DataPacket(
            data: Uint8List.sublistView(
              Uint8List.fromList([...body, crc & 0xFF, crc >> 8]),
              3,
            ),
          ),
        );
      });
    };
    await service.startSession();
    final response = await service.execute(
      ModbusRequest(
        mode: ModbusMode.rtu,
        unitId: 1,
        function: ModbusFunction.readHoldingRegisters,
        address: 0,
      ),
    );
    expect(response.registerValues, [42]);
    expect(link.sendCount, 1);
    await service.stop();
    expect(link.acquired, isFalse);
  });

  test('写操作失败不自动重试', () async {
    final link = _FakeLink()..failSend = true;
    addTearDown(link.close);
    final service = ModbusClientService(link);
    await service.startSession();
    await expectLater(
      service.execute(
        ModbusRequest(
          mode: ModbusMode.rtu,
          unitId: 1,
          function: ModbusFunction.writeSingleRegister,
          address: 0,
          registerValues: const [1],
        ),
        readRetries: 3,
      ),
      throwsStateError,
    );
    expect(link.sendCount, 1);
    expect(service.records.last.status, contains('失败'));
    expect(service.records.last.status, contains('写入失败'));
    await service.stop();
  });

  test('Modbus启动期间锁定全局多寄存器排列', () async {
    final link = _FakeLink();
    addTearDown(link.close);
    final service = ModbusClientService(link);
    await service.startSession();
    service
      ..setByteOrder(ModbusByteOrder.lowByteFirst)
      ..setWordOrder(ModbusWordOrder.lowWordFirst);
    expect(service.byteOrder, ModbusByteOrder.highByteFirst);
    expect(service.wordOrder, ModbusWordOrder.highWordFirst);

    await service.stop();
    service
      ..setByteOrder(ModbusByteOrder.lowByteFirst)
      ..setWordOrder(ModbusWordOrder.lowWordFirst);
    expect(service.byteOrder, ModbusByteOrder.lowByteFirst);
    expect(service.wordOrder, ModbusWordOrder.lowWordFirst);
  });

  test('默认配置稀疏导出，非默认字段才写入', () {
    final link = _FakeLink();
    addTearDown(link.close);
    final service = ModbusClientService(
      link,
      initialPages: [
        _page(rows: [_row()]),
      ],
    );
    final defaults = service.exportConfiguration();
    expect(defaults, contains('"unitId": 1'));
    expect(defaults, isNot(contains('"enabled": true')));
    expect(defaults, isNot(contains('"layoutMode"')));
    service.setLayoutMode(ModbusRegisterLayoutMode.rowMajor);
    service
      ..setByteOrder(ModbusByteOrder.lowByteFirst)
      ..setWordOrder(ModbusWordOrder.lowWordFirst)
      ..setLogMaxLines(2500);
    service.updateRow(
      '1:holdingRegisters',
      _row(poll: true, pollIntervalMs: 250, type: ModbusVariableType.u32),
    );
    final changed = service.exportConfiguration();
    expect(changed, contains('"layoutMode": 2'));
    expect(changed, contains('"byteOrder": "lowByteFirst"'));
    expect(changed, contains('"wordOrder": "lowWordFirst"'));
    expect(changed, contains('"maxLines": 2500'));
    expect(changed, contains('"poll": {'));
    expect(changed, contains('"enabled": true'));
    expect(changed, contains('"intervalMs": 250'));
    expect(changed, contains('"variableType": "u32"'));
  });

  test('导入配置加入新页面并跳过重复页面', () async {
    final link = _FakeLink();
    addTearDown(link.close);
    final service = ModbusClientService(link, initialPages: [_page()]);
    final result = await service.importConfiguration('''
      {"schemaVersion":1,"modbus":{"pages":[
        {"unitId":1,"area":"holdingRegisters"},
        {"unitId":2,"area":"inputRegisters","rows":[{"address":3}]}
      ]}}
    ''');
    expect(result.pages, hasLength(1));
    expect(result.skippedPageKeys, ['1:holdingRegisters']);
    expect(service.pages.map((page) => page.key), contains('2:inputRegisters'));
    expect(service.pages.last.enabled, isFalse);
  });

  test('只读页面不能开启周期发送', () {
    final link = _FakeLink();
    addTearDown(link.close);
    final service = ModbusClientService(
      link,
      initialPages: [
        _page(
          area: ModbusRegisterArea.inputRegisters,
          rows: [_row(send: false)],
        ),
      ],
    );
    service.setRowSending('1:inputRegisters', 'row', true);
    expect(service.pages.single.rows.single.sendEnabled, isFalse);
  });

  test('页面级轮询按周期运行且解码行值', () async {
    final link = _FakeLink();
    addTearDown(link.close);
    link.onSend = (_) => _respondRead(link, value: 123);
    final page = _page(
      enabled: true,
      rows: [_row(poll: true, pollIntervalMs: 50)],
    );
    final service = ModbusClientService(
      link,
      timeoutMs: 200,
      initialPages: [page],
    );
    await service.startSession();
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (link.sendCount < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await service.stop();
    expect(link.sendCount, greaterThanOrEqualTo(2));
    expect(service.rowState(page.key, 'row').value, 123);
  });

  test('一次性行写入不启用周期发送', () async {
    final link = _FakeLink();
    addTearDown(link.close);
    link.onSend =
        (data) => scheduleMicrotask(
          () => link.controller.add(DataPacket(data: data)),
        );
    final page = _page(rows: [_row(send: false)]);
    final service = ModbusClientService(link, initialPages: [page]);
    await service.startSession();
    await service.sendRowOnce(page.key, 'row', '7');
    await service.stop();
    expect(link.sendCount, 1);
    expect(service.pages.single.rows.single.sendEnabled, isFalse);
  });
}
