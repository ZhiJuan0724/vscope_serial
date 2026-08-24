import 'dart:typed_data';

enum ModbusMode {
  rtu('rtu', 'RTU'),
  ascii('ascii', 'ASCII'),
  tcp('tcp', 'TCP');

  const ModbusMode(this.value, this.label);
  final String value;
  final String label;

  static ModbusMode fromString(String? value) => switch (value) {
    'ascii' => ascii,
    'tcp' => tcp,
    _ => rtu,
  };
}

enum ModbusFunction {
  readCoils(0x01, '读线圈', true, 1),
  readDiscreteInputs(0x02, '读离散输入', true, 10001),
  readHoldingRegisters(0x03, '读保持寄存器', true, 40001),
  readInputRegisters(0x04, '读输入寄存器', true, 30001),
  writeSingleCoil(0x05, '写单线圈', false, 1),
  writeSingleRegister(0x06, '写单寄存器', false, 40001),
  writeMultipleCoils(0x0F, '写多线圈', false, 1),
  writeMultipleRegisters(0x10, '写多寄存器', false, 40001);

  const ModbusFunction(this.code, this.label, this.isRead, this.referenceBase);
  final int code;
  final String label;
  final bool isRead;
  final int referenceBase;

  bool get isBitFunction =>
      this == readCoils ||
      this == readDiscreteInputs ||
      this == writeSingleCoil ||
      this == writeMultipleCoils;

  static ModbusFunction fromCode(int code) => values.firstWhere(
    (value) => value.code == code,
    orElse:
        () =>
            throw FormatException(
              '不支持的 Modbus 功能码：0x${code.toRadixString(16)}',
            ),
  );

  static ModbusFunction fromString(String? value) => values.firstWhere(
    (item) => item.name == value,
    orElse: () => readHoldingRegisters,
  );
}

class ModbusRequest {
  ModbusRequest({
    required this.mode,
    required this.unitId,
    required this.function,
    required this.address,
    this.quantity = 1,
    this.registerValues = const [],
    this.coilValues = const [],
    this.transactionId = 0,
  }) {
    if (unitId < 0 || unitId > 255) {
      throw ArgumentError.value(unitId, 'unitId');
    }
    if (address < 0 || address > 0xFFFF) {
      throw ArgumentError.value(address, 'address');
    }
    if (quantity < 1 || quantity > 2000) {
      throw ArgumentError.value(quantity, 'quantity');
    }
  }

  final ModbusMode mode;
  final int unitId;
  final ModbusFunction function;
  final int address;
  final int quantity;
  final List<int> registerValues;
  final List<bool> coilValues;
  final int transactionId;

  ModbusRequest copyWith({ModbusMode? mode, int? transactionId}) =>
      ModbusRequest(
        mode: mode ?? this.mode,
        unitId: unitId,
        function: function,
        address: address,
        quantity: quantity,
        registerValues: registerValues,
        coilValues: coilValues,
        transactionId: transactionId ?? this.transactionId,
      );
}

class ModbusResponse {
  const ModbusResponse({
    required this.request,
    required this.rawFrame,
    this.registerValues = const [],
    this.coilValues = const [],
    this.exceptionCode,
  });

  final ModbusRequest request;
  final Uint8List rawFrame;
  final List<int> registerValues;
  final List<bool> coilValues;
  final int? exceptionCode;

  bool get isException => exceptionCode != null;
}

enum ModbusRegisterArea {
  coils('coils', '线圈', ModbusFunction.readCoils, true, true),
  discreteInputs(
    'discreteInputs',
    '离散输入',
    ModbusFunction.readDiscreteInputs,
    false,
    true,
  ),
  holdingRegisters(
    'holdingRegisters',
    '保持寄存器',
    ModbusFunction.readHoldingRegisters,
    true,
    false,
  ),
  inputRegisters(
    'inputRegisters',
    '输入寄存器',
    ModbusFunction.readInputRegisters,
    false,
    false,
  );

  const ModbusRegisterArea(
    this.value,
    this.label,
    this.readFunction,
    this.isWritable,
    this.isBitArea,
  );

  final String value;
  final String label;
  final ModbusFunction readFunction;
  final bool isWritable;
  final bool isBitArea;

  static ModbusRegisterArea? fromString(Object? value) {
    for (final item in values) {
      if (item.value == value || item.name == value) return item;
    }
    return null;
  }
}

enum ModbusVariableType {
  boolean('bool', 'bool', 1),
  u8('u8', 'u8', 1),
  u16('u16', 'u16', 1),
  u32('u32', 'u32', 2),
  i8('i8', 'i8', 1),
  i16('i16', 'i16', 1),
  i32('i32', 'i32', 2),
  i64('i64', 'i64', 4),
  u64('u64', 'u64', 4),
  floatValue('float', 'float', 2),
  doubleValue('double', 'double', 4);

  const ModbusVariableType(this.value, this.label, this.registerWidth);
  final String value;
  final String label;
  final int registerWidth;

  bool get isFloatingPoint => this == floatValue || this == doubleValue;
  bool get isSigned => this == i8 || this == i16 || this == i32 || this == i64;
  int get bitWidth => registerWidth * 16;

  static ModbusVariableType? fromString(Object? value) {
    for (final item in values) {
      if (item.value == value || item.name == value) return item;
    }
    return null;
  }

  static ModbusVariableType defaultFor(ModbusRegisterArea area) =>
      area.isBitArea ? boolean : u16;
}

enum ModbusByteOrder {
  highByteFirst('highByteFirst', '高字节在前'),
  lowByteFirst('lowByteFirst', '低字节在前');

  const ModbusByteOrder(this.value, this.label);
  final String value;
  final String label;

  static ModbusByteOrder fromString(Object? value) => values.firstWhere(
    (item) => item.value == value || item.name == value,
    orElse: () => highByteFirst,
  );
}

enum ModbusWordOrder {
  highWordFirst('highWordFirst', '高位寄存器在前'),
  lowWordFirst('lowWordFirst', '低位寄存器在前');

  const ModbusWordOrder(this.value, this.label);
  final String value;
  final String label;

  static ModbusWordOrder fromString(Object? value) => values.firstWhere(
    (item) => item.value == value || item.name == value,
    orElse: () => highWordFirst,
  );
}

enum ModbusDisplayRadix {
  decimal('decimal', '十进制'),
  hexadecimal('hexadecimal', '十六进制');

  const ModbusDisplayRadix(this.value, this.label);
  final String value;
  final String label;

  static ModbusDisplayRadix fromString(Object? value) => values.firstWhere(
    (item) => item.value == value || item.name == value,
    orElse: () => decimal,
  );
}

enum ModbusRegisterLayoutMode {
  columnMajor(1, '按列排列'),
  rowMajor(2, '按行排列');

  const ModbusRegisterLayoutMode(this.value, this.label);
  final int value;
  final String label;

  static ModbusRegisterLayoutMode fromValue(Object? value) =>
      value is num && value.toInt() == 2 ? rowMajor : columnMajor;
}

enum ModbusSendValueMode {
  fixed('fixed', '固定值'),
  random('random', '随机值'),
  increment('increment', '自增'),
  decrement('decrement', '自减');

  const ModbusSendValueMode(this.value, this.label);
  final String value;
  final String label;

  static ModbusSendValueMode fromString(Object? value) => values.firstWhere(
    (item) => item.value == value || item.name == value,
    orElse: () => fixed,
  );
}

const int modbusMinIntervalMs = 10;
const int modbusMaxIntervalMs = 3600000;
const int modbusDefaultIntervalMs = 1000;
const int modbusDefaultLogMaxLines = 1000;
const int modbusMinLogMaxLines = 100;
const int modbusMaxLogMaxLines = 100000;

class ModbusRegisterRow {
  ModbusRegisterRow({
    required this.id,
    required this.address,
    this.variableType = ModbusVariableType.u16,
    this.displayRadix = ModbusDisplayRadix.decimal,
    this.pollEnabled = false,
    this.pollIntervalMs = modbusDefaultIntervalMs,
    this.readRetries = 0,
    this.sendEnabled = false,
    this.sendIntervalMs = modbusDefaultIntervalMs,
    this.sendMode = ModbusSendValueMode.fixed,
    this.sendValue = '0',
    this.sendStep = '1',
    this.note = '',
    this.backgroundArgb,
  });

  final String id;
  final int address;
  final ModbusVariableType variableType;
  final ModbusDisplayRadix displayRadix;
  final bool pollEnabled;
  final int pollIntervalMs;
  final int readRetries;
  final bool sendEnabled;
  final int sendIntervalMs;
  final ModbusSendValueMode sendMode;
  final String sendValue;
  final String sendStep;
  final String note;
  final int? backgroundArgb;

  ModbusRegisterRow copyWith({
    String? id,
    int? address,
    ModbusVariableType? variableType,
    ModbusDisplayRadix? displayRadix,
    bool? pollEnabled,
    int? pollIntervalMs,
    int? readRetries,
    bool? sendEnabled,
    int? sendIntervalMs,
    ModbusSendValueMode? sendMode,
    String? sendValue,
    String? sendStep,
    String? note,
    int? backgroundArgb,
    bool clearBackground = false,
  }) => ModbusRegisterRow(
    id: id ?? this.id,
    address: address ?? this.address,
    variableType: variableType ?? this.variableType,
    displayRadix: displayRadix ?? this.displayRadix,
    pollEnabled: pollEnabled ?? this.pollEnabled,
    pollIntervalMs: pollIntervalMs ?? this.pollIntervalMs,
    readRetries: readRetries ?? this.readRetries,
    sendEnabled: sendEnabled ?? this.sendEnabled,
    sendIntervalMs: sendIntervalMs ?? this.sendIntervalMs,
    sendMode: sendMode ?? this.sendMode,
    sendValue: sendValue ?? this.sendValue,
    sendStep: sendStep ?? this.sendStep,
    note: note ?? this.note,
    backgroundArgb:
        clearBackground ? null : (backgroundArgb ?? this.backgroundArgb),
  );

  Map<String, Object?> toSparseJson(ModbusRegisterArea area) {
    final result = <String, Object?>{'address': address};
    final defaultType = ModbusVariableType.defaultFor(area);
    if (!area.isBitArea && variableType != defaultType) {
      result['variableType'] = variableType.value;
    }
    if (displayRadix != ModbusDisplayRadix.decimal) {
      result['displayRadix'] = displayRadix.value;
    }
    if (pollEnabled ||
        pollIntervalMs != modbusDefaultIntervalMs ||
        readRetries != 0) {
      final poll = <String, Object?>{};
      if (pollEnabled) poll['enabled'] = true;
      if (pollIntervalMs != modbusDefaultIntervalMs) {
        poll['intervalMs'] = pollIntervalMs;
      }
      if (readRetries != 0) poll['readRetries'] = readRetries;
      result['poll'] = poll;
    }
    if (sendEnabled ||
        sendIntervalMs != modbusDefaultIntervalMs ||
        sendMode != ModbusSendValueMode.fixed ||
        sendValue != '0' ||
        sendStep != '1') {
      final send = <String, Object?>{};
      if (sendEnabled) send['enabled'] = true;
      if (sendIntervalMs != modbusDefaultIntervalMs) {
        send['intervalMs'] = sendIntervalMs;
      }
      if (sendMode != ModbusSendValueMode.fixed) send['mode'] = sendMode.value;
      if (sendValue != '0') send['value'] = sendValue;
      if (sendStep != '1') send['step'] = sendStep;
      result['send'] = send;
    }
    if (note.isNotEmpty) result['note'] = note;
    if (backgroundArgb != null) result['backgroundArgb'] = backgroundArgb;
    return result;
  }

  static ModbusRegisterRow? fromJson(
    Object? value,
    ModbusRegisterArea area, {
    String? generatedId,
  }) {
    if (value is! Map) return null;
    final address = (value['address'] as num?)?.toInt();
    if (address == null || address < 0 || address > 0xFFFF) return null;
    final defaultType = ModbusVariableType.defaultFor(area);
    final parsedType = ModbusVariableType.fromString(value['variableType']);
    final variableType =
        area.isBitArea ? defaultType : (parsedType ?? defaultType);
    final poll = value['poll'] is Map ? value['poll'] as Map : const {};
    final send = value['send'] is Map ? value['send'] as Map : const {};
    final pollInterval =
        ((poll['intervalMs'] as num?)?.toInt() ?? modbusDefaultIntervalMs)
            .clamp(modbusMinIntervalMs, modbusMaxIntervalMs)
            .toInt();
    final sendInterval =
        ((send['intervalMs'] as num?)?.toInt() ?? modbusDefaultIntervalMs)
            .clamp(modbusMinIntervalMs, modbusMaxIntervalMs)
            .toInt();
    final background = (value['backgroundArgb'] as num?)?.toInt();
    return ModbusRegisterRow(
      id: '${value['id'] ?? generatedId ?? DateTime.now().microsecondsSinceEpoch}',
      address: address,
      variableType: variableType,
      displayRadix: ModbusDisplayRadix.fromString(value['displayRadix']),
      pollEnabled: poll['enabled'] == true,
      pollIntervalMs: pollInterval,
      readRetries: ((poll['readRetries'] as num?)?.toInt() ?? 0).clamp(0, 3),
      sendEnabled: area.isWritable && send['enabled'] == true,
      sendIntervalMs: sendInterval,
      sendMode: ModbusSendValueMode.fromString(send['mode']),
      sendValue: '${send['value'] ?? '0'}',
      sendStep: '${send['step'] ?? '1'}',
      note: '${value['note'] ?? ''}',
      backgroundArgb: background,
    );
  }
}

class ModbusRegisterPage {
  ModbusRegisterPage({
    required this.unitId,
    required this.area,
    this.enabled = false,
    this.showVariableType = true,
    this.byteOrder = ModbusByteOrder.highByteFirst,
    this.wordOrder = ModbusWordOrder.highWordFirst,
    this.rows = const [],
  });

  final int unitId;
  final ModbusRegisterArea area;
  final bool enabled;
  final bool showVariableType;
  final ModbusByteOrder byteOrder;
  final ModbusWordOrder wordOrder;
  final List<ModbusRegisterRow> rows;

  String get key => '$unitId:${area.value}';

  ModbusRegisterPage copyWith({
    int? unitId,
    ModbusRegisterArea? area,
    bool? enabled,
    bool? showVariableType,
    ModbusByteOrder? byteOrder,
    ModbusWordOrder? wordOrder,
    List<ModbusRegisterRow>? rows,
  }) => ModbusRegisterPage(
    unitId: unitId ?? this.unitId,
    area: area ?? this.area,
    enabled: enabled ?? this.enabled,
    showVariableType: showVariableType ?? this.showVariableType,
    byteOrder: byteOrder ?? this.byteOrder,
    wordOrder: wordOrder ?? this.wordOrder,
    rows: List.unmodifiable(rows ?? this.rows),
  );

  Map<String, Object?> toSparseJson() {
    final result = <String, Object?>{'unitId': unitId, 'area': area.value};
    if (enabled) result['enabled'] = true;
    if (!showVariableType) result['showVariableType'] = false;
    if (byteOrder != ModbusByteOrder.highByteFirst) {
      result['byteOrder'] = byteOrder.value;
    }
    if (wordOrder != ModbusWordOrder.highWordFirst) {
      result['wordOrder'] = wordOrder.value;
    }
    if (rows.isNotEmpty) {
      result['rows'] = [for (final row in rows) row.toSparseJson(area)];
    }
    return result;
  }

  static ModbusRegisterPage? fromJson(Object? value) {
    if (value is! Map) return null;
    final unitId = (value['unitId'] as num?)?.toInt();
    final area = ModbusRegisterArea.fromString(value['area']);
    if (unitId == null || unitId < 0 || unitId > 255 || area == null) {
      return null;
    }
    final rowsValue = value['rows'];
    final rows = <ModbusRegisterRow>[];
    if (rowsValue is List) {
      for (var index = 0; index < rowsValue.length; index++) {
        final row = ModbusRegisterRow.fromJson(
          rowsValue[index],
          area,
          generatedId: '$unitId:${area.value}:$index',
        );
        if (row != null) rows.add(row);
      }
    }
    return ModbusRegisterPage(
      unitId: unitId,
      area: area,
      enabled: value['enabled'] == true,
      showVariableType: value['showVariableType'] != false,
      byteOrder: ModbusByteOrder.fromString(value['byteOrder']),
      wordOrder: ModbusWordOrder.fromString(value['wordOrder']),
      rows: List.unmodifiable(rows),
    );
  }
}

class ModbusFrameRecord {
  const ModbusFrameRecord({
    required this.timestamp,
    required this.outbound,
    required this.frame,
    required this.status,
    this.elapsed,
  });
  final DateTime timestamp;
  final bool outbound;
  final Uint8List frame;
  final String status;
  final Duration? elapsed;
}

int modbusReferenceNumber(ModbusFunction function, int zeroBasedAddress) =>
    function.referenceBase + zeroBasedAddress;
