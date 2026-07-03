import 'package:flutter_test/flutter_test.dart';
import 'package:vscope_serial/core/utils/file_name_sanitizer.dart';

void main() {
  group('sanitizeFileName', () {
    test('保留普通中文配置名', () {
      expect(sanitizeFileName('  电机配置  '), '电机配置');
    });

    test('替换 Windows 文件名非法字符', () {
      expect(sanitizeFileName(r'A<B>C:D"E/F\G|H?I*J'), 'A_B_C_D_E_F_G_H_I_J');
    });

    test('移除末尾空格和点并在空名称时使用兜底名称', () {
      expect(sanitizeFileName('配置.   '), '配置');
      expect(sanitizeFileName('***', fallback: '新配置'), '___');
      expect(sanitizeFileName('   ', fallback: '新配置'), '新配置');
    });
  });
}
