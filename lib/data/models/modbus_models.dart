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

class ModbusPollingTask {
  const ModbusPollingTask({
    required this.id,
    required this.name,
    required this.unitId,
    required this.function,
    required this.address,
    required this.quantity,
    this.intervalMs = 1000,
    this.readRetries = 0,
    this.enabled = true,
  });

  final String id;
  final String name;
  final int unitId;
  final ModbusFunction function;
  final int address;
  final int quantity;
  final int intervalMs;
  final int readRetries;
  final bool enabled;

  ModbusPollingTask copyWith({bool? enabled}) => ModbusPollingTask(
    id: id,
    name: name,
    unitId: unitId,
    function: function,
    address: address,
    quantity: quantity,
    intervalMs: intervalMs,
    readRetries: readRetries,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'unitId': unitId,
    'function': function.name,
    'address': address,
    'quantity': quantity,
    'intervalMs': intervalMs,
    'readRetries': readRetries,
    'enabled': enabled,
  };

  static ModbusPollingTask? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = '${value['id'] ?? ''}'.trim();
    final name = '${value['name'] ?? ''}'.trim();
    final unitId = (value['unitId'] as num?)?.toInt();
    final address = (value['address'] as num?)?.toInt();
    final quantity = (value['quantity'] as num?)?.toInt();
    final intervalMs = (value['intervalMs'] as num?)?.toInt() ?? 1000;
    if (id.isEmpty ||
        name.isEmpty ||
        unitId == null ||
        unitId < 0 ||
        unitId > 255 ||
        address == null ||
        address < 0 ||
        address > 0xFFFF ||
        quantity == null ||
        quantity < 1 ||
        quantity > 2000 ||
        intervalMs < 50 ||
        intervalMs > 3600000) {
      return null;
    }
    final function = ModbusFunction.fromString(value['function'] as String?);
    if (!function.isRead) return null;
    return ModbusPollingTask(
      id: id,
      name: name,
      unitId: unitId,
      function: function,
      address: address,
      quantity: quantity,
      intervalMs: intervalMs,
      readRetries: ((value['readRetries'] as num?)?.toInt() ?? 0).clamp(0, 3),
      enabled: value['enabled'] as bool? ?? true,
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
