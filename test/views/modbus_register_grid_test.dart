import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/modbus_models.dart';
import 'package:vscope_serial/services/modbus_client_service.dart';
import 'package:vscope_serial/views/widgets/modbus_register_grid.dart';

void main() {
  testWidgets('寄存器失败时只显示失败并隐藏具体原因和旧值', (tester) async {
    final row = ModbusRegisterRow(id: 'row-1', address: 1);
    final page = ModbusRegisterPage(
      unitId: 1,
      area: ModbusRegisterArea.holdingRegisters,
      rows: [row],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ModbusRegisterGrid(
            page: page,
            layoutMode: ModbusRegisterLayoutMode.rowMajor,
            rowState:
                (_) => ModbusRowState(value: 123, error: StateError('具体失败原因')),
            onRowContextMenu: (_, _) {},
            onBlankContextMenu: (_) {},
          ),
        ),
      ),
    );

    expect(find.textContaining('失败', findRichText: true), findsOneWidget);
    expect(find.textContaining('具体失败原因', findRichText: true), findsNothing);
    expect(find.textContaining('123', findRichText: true), findsNothing);
  });
}
