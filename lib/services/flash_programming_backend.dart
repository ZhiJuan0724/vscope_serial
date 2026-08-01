import 'dart:async';

import '../data/models/flash_programming_models.dart';

typedef FlashProgressCallback = void Function(double progress, String stage);

/// 独立高权限编程后端。
///
/// 实现不得持有或复用RTT监控后端实例；连接建立后由服务层锁定具体后端，
/// 任一操作失败都不能静默切换工具。
abstract interface class FlashProgrammingBackend {
  ProgrammingBackendSelection get selection;
  String get displayName;
  Stream<String> get output;
  bool get isConnected;

  Future<bool> isAvailable(FlashConnectionConfig config);
  Future<void> connect(FlashConnectionConfig config);
  Future<void> disconnect();
  Future<void> program(
    FlashProgramRequest request,
    FlashProgressCallback onProgress,
  );
  Future<void> erase(
    FlashEraseRequest request,
    FlashProgressCallback onProgress,
  );
  Future<void> read(FlashReadRequest request, FlashProgressCallback onProgress);
  Future<void> forceTerminate();
}

String quoteJlinkPath(String path) => '"${path.replaceAll('"', '')}"';

String quoteOpenOcdTclPath(String path) =>
    '{${path.replaceAll('\\', '/').replaceAll('}', r'\}')}}';
