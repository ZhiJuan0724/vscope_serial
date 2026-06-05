# VScope Serial 项目上下文

> 本文件只记录长期有效的项目事实和开发约束，避免把每次小改动都堆进来。
> 提交信息使用中文，说明本次修改的具体任务；涉及 force push 必须先让用户确认。
> `CHANGELOG.md` 是 Release Notes 和应用内版本说明来源；涉及发布内容的提交，提交前必须让用户核对对应版本段落，且只记录用户可感知变化。

## 项目定位

VScope Serial 是一个 Flutter Windows 串口数据可视化工具，核心目标是稳定接收串口数据、按多种协议解析，并在百万级数据量下保持波形绘制和交互流畅。

当前只维护 Windows 桌面目标。仓库主开发分支为 `dev`，发布分支为 `main`。

## 当前能力

- 串口连接、配置、状态检测、原始收发显示和导出。
- 实时绘图、历史窗口回看、CSV/BIN 导入导出，以及旧版虚拟示波器 DAT 导入。
- 接收协议支持 FireWater、固定帧、Zobow、JustFloat。
- 发送协议与接收协议分离；内置发送协议为“无”和 `r协议`，Zobow 接收协议固定使用内置二进制初始化帧。
- 地址配置文件支持 Zobow/r 协议共享 JSON 结构，并支持 CSV 导入，CSV 两列为通道名称和通道地址。
- 多通道颜色、名称、显示、偏置、缩放、线宽和点半径配置；偏置通道右侧刻度列按文本宽度动态预留。
- X-X、Y-Y、统计范围、观察线、跟随光标、吸附高亮和通道偏置交互。
- 大数据绘图使用内存级 LOD 索引，当前精确窗口上限可配置为 `1M~40M`。
- 应用信息页显示版本、构建时间、更新检查、版本说明和高级设置；高级设置当前提供全局关闭临时提示信息。
- 测试工具可模拟 Zobow/JustFloat 设备，也可生成可直接导入绘图页的 BIN 数据文件。

## 模块边界

- `lib/core/`：日志、CRC 等底层工具。底层模块优先使用 `AppLogger`，不要直接 `print()`。
- `lib/data/`：数据模型、协议解析器、数据源和 LOD 索引。解析器统一通过 `IDataParser.feed()` 和 `outputStream` 工作。
- `lib/services/`：串口服务、设置持久化、应用信息、更新检查、通知和原生读取封装。
- `lib/viewmodels/`：页面状态和业务流程。`PlotViewModel` 是全局 Provider，页面切换不丢绘图状态。
- `lib/views/`：页面、弹窗、绘图 Painter 和手势处理。
- `test_tools/`：本地模拟设备和测试数据生成脚本。
- `windows/`：Flutter Windows runner 与原生串口读取 DLL 构建。

## 关键约束

- 设置持久化到 `<exe_dir>/settings/settings.json`。新增字段必须有默认值兼容旧配置，不做单独迁移脚本。
- 设置文件不加密，不要存放敏感数据。
- 关闭窗口前必须先断开串口，避免原生 DLL 读线程异常。
- Windows 原生串口打开在后台 isolate 执行，避免 `CreateFile` 阻塞 UI。
- 原始数据显示行数有限，完整导出以字节缓存为准。
- `PlotLodIndex` 只保存在内存中，不落盘，不改变原始数据和导出结果。
- Zobow 当前只支持 4/8 通道固定帧，不支持任意变长。
- FixedFrame 通道数固定为 `1~16`，不支持自动识别；帧头和帧尾不能同时全部为 `0`。
- FireWater 只面向 ASCII 数字文本。
- 随机源只输出 FireWater 格式。切换到其它解析器时保留开关状态，但不接入当前解析链。
- 绘图区动态布局不能在 Flutter build 阶段直接修改 ViewModel 状态；需要使用临时渲染状态或在事件阶段更新。
- 通道列表使用可回收列表，列表滚动时临时编辑状态可能丢失；编辑类状态要谨慎放在 item state 中。
- Flutter Windows 的 `ListView + Tooltip` 组合存在已知 accessibility 日志噪声，不影响功能。

## 发布与更新

- 版本号来自 `pubspec.yaml`，应用内显示带 `v` 前缀。
- 发布构建必须通过 GitHub Actions 或 `tools/build_release.py` 注入 `BUILD_TIME`；应用信息界面的构建时间优先读取该编译期值，不能依赖 exe 文件修改时间。
- 更新检查优先访问 GitHub Release，失败后尝试 Gitee Release；当前只提示更新，不自动覆盖安装。
- Windows 程序运行时不能可靠覆盖自身，后续自动安装需要外置更新程序在主程序退出后解压并替换文件。
- `.github/workflows/windows-release.yml` 负责 PR 检查、手动构建和 tag 发布。
- PR 到 `main` 会运行 `flutter analyze`、`flutter test` 和 Windows Release 构建。
- `v*` tag 会测试、构建、压缩发布包并创建 GitHub Release。
- `main` 直接 push 不触发 release workflow，避免合并后和 tag 发布重复执行。

## 开发检查

常规提交前检查：

```bash
dart format lib test
flutter test
flutter analyze
```

涉及绘图性能、导入和协议解析时，优先补充或运行相关定向测试：

```bash
flutter test test/data/models/plot_lod_index_test.dart
flutter test test/viewmodels/plot_viewmodel_test.dart
flutter test test/viewmodels/plot_viewmodel_window_test.dart
flutter test test/viewmodels/plot_viewmodel_stats_test.dart
flutter test test/parser/just_float_parser_test.dart
```

## Git 规则

- 不要回滚用户已有改动，除非用户明确要求。
- 提交前确认 `git status`，只暂存本次任务相关文件。
- 涉及发布内容时，提交前让用户核对 `CHANGELOG.md` 对应版本段落。
- 涉及 force push 时，必须先让用户确认具体目标分支或 tag。
