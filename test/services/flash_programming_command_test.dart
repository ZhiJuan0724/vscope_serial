import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/data/models/flash_programming_models.dart';
import 'package:vscope_serial/services/flash_programming_backend.dart';
import 'package:vscope_serial/services/jlink_programming_backend.dart';
import 'package:vscope_serial/services/openocd_programming_backend.dart';

void main() {
  test('BIN必须填写基地址', () {
    expect(
      () => const FlashProgramRequest(filePath: 'firmware.bin').validate(),
      throwsFormatException,
    );
  });

  test('J-Link命令保留Windows空格与中文路径且不经过Shell拼接', () {
    const request = FlashProgramRequest(
      filePath: r'C:\固件 目录\motor.bin',
      binAddress: 0x08000000,
    );
    expect(
      buildJLinkLoadFileCommand(request),
      r'LoadFile "C:\固件 目录\motor.bin" 0x8000000 noreset',
    );
  });

  test('OpenOCD命令使用Tcl路径引用并包含擦除与BIN偏移', () {
    const request = FlashProgramRequest(
      filePath: r'C:\固件 目录\motor.bin',
      binAddress: 0x08000000,
    );
    expect(
      buildOpenOcdWriteImageCommand(request),
      r'flash write_image erase {C:/固件 目录/motor.bin} 0x8000000 bin',
    );
    expect(quoteOpenOcdTclPath(r'C:\普通\app.elf'), r'{C:/普通/app.elf}');
  });
}
