#ifndef RUNNER_CRASH_DUMP_HANDLER_H_
#define RUNNER_CRASH_DUMP_HANDLER_H_

/// 在 Flutter 引擎和业务 DLL 初始化前安装 Windows 未处理异常回调。
///
/// 转储默认开启；用户关闭后，Dart 层会在 settings 目录创建禁用标记，
/// 回调只检查该标记，不在崩溃现场解析 settings.json。
void InstallCrashDumpHandler();

#endif  // RUNNER_CRASH_DUMP_HANDLER_H_
