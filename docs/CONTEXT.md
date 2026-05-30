# VScope Serial 项目上下文

> 本文档记录当前实现状态、关键约束和后续开发时需要遵守的约定。
> 提交信息使用中文，说明本次修改的具体任务；涉及 force push 时必须先让用户校验。

## 项目定位

VScope Serial 是一个 Flutter Windows 串口数据可视化工具，核心目标是稳定接收串口数据、按多种协议解析，并在百万级数据量下保持波形绘制和交互流畅。

当前只维护 Windows 桌面目标。仓库主开发分支为 `dev`，发布分支为 `main`。

## 当前关键能力

- 串口连接、配置和原始收发显示。
- 实时绘图、历史窗口回看、CSV/BIN 导入导出。
- FireWater、固定帧头、Zobow、JustFloat 四类解析协议。
- 多通道颜色、名称、显示、偏置、缩放、线宽和点半径配置。
- X-X、Y-Y、统计范围、观察线、跟随光标和通道偏置交互。
- 大数据绘图 LOD 索引，支持 1M~40M 可见窗口上限。
- 大文件导入异步执行，并通过进度弹窗提示读取、解析和索引进度。
- 测试工具可模拟 Zobow/JustFloat 设备，也可生成可直接导入的 BIN 数据文件。

## Core/Utils

### 当前状态

- 日志系统使用 `logger` 和自定义 `FileLogOutput`。
- 日志文件输出到可执行文件同级 `logs/`，按时间戳归档，最多保留 10 份。
- 批量 flush 策略减少磁盘 IO。
- CRC 工具支持 CRC-8/16/32 和常见多项式。

### 约束

- `AppLogger` 未初始化时静默丢弃日志，避免单元测试报错。
- 新增底层模块时优先使用 `AppLogger`，不要直接 `print()`。

## Services/SerialService

### 当前状态

- `SerialService` 使用单例 `ChangeNotifier` 管理串口生命周期。
- Windows 读取使用原生 C++ DLL，通过 `Dart_PostCObject_DL` 回调 Dart。
- `flutter_libserialport` 当前主要用于串口枚举。
- 原始数据使用分块字节缓存，显示端保留有限文本行，导出端保留完整字节缓存。
- 原始收发页支持文本/HEX 显示、发送数据显示、自动追加行尾、发送后保留输入。
- HEX 显示可启用时间窗口聚合，文本显示按 `\r`/`\n` 换行。

### 约束

- 关闭窗口前必须先断开串口，避免原生 DLL 读线程触发异常。
- com0com 等虚拟串口在 Windows 上枚举可能不稳定。
- 文本显示行数有限，完整导出以字节缓存为准。

## Services/AppSettings

### 当前状态

- 设置持久化到 `<exe_dir>/settings/settings.json`。
- 已持久化串口配置、绘图配置、解析器配置、随机源配置、Zobow 配置文件选择等。
- 绘图窗口上限 `maxVisiblePoints`：范围 `1000000~40000000`，默认 `1000000`。
- 绘图刷新率 `refreshFps`：范围 `30~60`，默认 `60`，高级设置中使用输入框。
- 吸附点高亮：`snapHighlightEnabled` 默认开启；`snapHighlightDiameter` 范围 `6~12 px`，默认 `8 px`。
- JustFloat 手动通道数 `justFloatChannelCount`：`0` 表示自动识别。

### 约束

- 设置文件不加密。
- 新增字段使用默认值兼容旧设置，不做单独迁移脚本。

## Data/Models

### 当前状态

- `ParserConfig` 支持 FireWater、FixedFrame、Zobow、JustFloat。
- `ChannelConfig` 默认 16 通道，每通道独立配置颜色、名称、可见性、偏置、缩放、线宽和点半径。
- `PlotDataPoint` 使用 `Float32List` 保存通道值。
- `ChunkedByteBuffer` / `FixedPacketByteBuffer` 支持运行期内按包序号随机读取原始固定帧。
- `PlotLodIndex` 是内存级绘图 LOD 索引，最多 16 通道，按 2 的幂维护桶数据，每桶保存 first/last/min/max 及对应原始 index。

### 约束

- `PlotLodIndex` 只保存在内存中，不落盘。
- Zobow 当前支持 4/8 通道固定帧，不支持任意变长。

## Data/Parsers

### 当前状态

- `IDataParser` 统一使用 `feed()` 和 `outputStream`。
- FireWater：CSV 风格文本协议，自动识别或固定通道数。
- FixedFrame：可配置帧头、数据类型、通道数、校验和帧尾。
- Zobow：无帧头滑动窗口，CRC16/MODBUS 校验；4 通道 10 字节，8 通道 18 字节。
- JustFloat：VOFA 小端 `float32` 数组 + `00 00 80 7F` 帧尾；通道数为 0 时按帧长度自动识别，最多 16 通道。

### 约束

- FireWater 只面向 ASCII 数字文本。
- FixedFrame 校验当前主要覆盖 SUM8/SUM16。
- Zobow 对错帧/丢包有滑动恢复，但协议本身无帧头，恢复能力有限。

## Data/Sources

### 当前状态

- `IDataSource` 抽象 `byteStream`、`start()`、`stop()`。
- `RandomDataSource` 在 isolate 中生成 FireWater 正弦波测试数据。
- `DataSourceManager` 管理串口源和随机源切换。

### 约束

- 随机源只输出 FireWater 格式。切换到其它解析器时保留开关状态，但不接入当前解析链。
- 随机源频率受 isolate 调度和机器负载影响。

## ViewModels/PlotViewModel

### 当前状态

- 全局 Provider 注册，页面切换不丢绘图状态。
- `_dataPoints` 只保存当前精确窗口；窗口上限可配置为 `1M~40M`。
- 所有解析到的新点都会增量进入 `PlotLodIndex`。
- 拖动视口时不重建精确窗口，Painter 使用 LOD 预览；拖动结束后再加载当前视口精确窗口。
- UI 通知按 `refreshFps` 节流，范围 `30~60`，默认 `60`。
- 统计范围通过二分定位数据范围，大窗口统计会采样并标注 `约`，避免范围测量导致卡顿。
- 统计 `Range` 显示实际包含的数据点 index 范围，不显示浮点视口边界。
- X-X、Y-Y、统计范围和观察线吸附当前显示窗口内的数据点。
- 吸附高亮固定在吸附时捕获的数据点；缩放时不会重新计算，若点不在当前窗口内则不显示。
- JustFloat 自动识别通道数减少时，偏置轴、自适应和交互只处理当前活动通道。
- 导入 CSV/BIN 时异步加载，并通过进度回调更新弹窗。

### 约束

- 非 Zobow/FixedFrame 的超长历史回看仍主要依赖当前运行期内解析缓存和窗口数据。
- Y 轴自适应在数据剧烈变化时仍可能出现视觉跳动。
- 吸附高亮只表达“当前捕获的吸附点”，不是动态最近点追踪。

## Views/PlotPage

### 当前状态

- 绘图页使用两行工具栏：数据/解析/文件/设置，以及光标/测量/缩放。
- 通道面板可折叠和拖拽调整宽度。
- 通道编辑弹窗支持颜色、名称、线宽、点半径、偏置和显示配置。
- Zobow 配置文件支持选择、新建、编辑、删除、预设导入和列表/平铺视图记忆。
- 观察线使用顶部刻度栏手柄，右键删除。
- X-X/Y-Y 测量手柄位于刻度栏，不侵入绘图区。
- 高级设置包含网格、刷新率输入、字体大小、吸附点高亮和绘图窗口上限。
- 抗锯齿固定开启，不再提供高级设置开关。

### 约束

- 通道列表使用可回收列表，列表滚动时临时编辑状态可能丢失。
- 随机源入口保留在绘图页，但只适配 FireWater。

## Views/Plot/PlotPainter

### 当前状态

- 使用 `CustomPainter` 自绘暗色波形。
- 大窗口优先查询 `PlotLodIndex`，每像素附近输出有序 first/min/max/last，保留尖峰和阶跃。
- 小窗口或高倍率放大时继续使用精确点绘制。
- 点绘制使用 `drawRawPoints` 批量绘制。
- `dataRevision` 参与 `shouldRepaint`，避免窗口长度不变但内容滚动时不重绘。
- 抗锯齿固定开启。
- 吸附高亮由 ViewModel 提供固定数据坐标，Painter 只负责当前 viewport 下的显示/隐藏和坐标转换。

### 约束

- LOD 不改变原始数据和导出结果。
- 网格和大量文本绘制仍可能成为极端场景的剩余开销。

## Views/Plot/PlotGestureHandler

### 当前状态

- 使用 `Listener` 处理原始指针事件。
- 支持滚轮缩放、Shift+滚轮 Y 轴缩放、拖拽平移、框选放大、测量线拖动和通道偏置拖动。
- X 吸附通过当前显示窗口内二分查找完成。
- Y 吸附按当前显示窗口采样查找最近屏幕 Y 点，避免百万点全量扫描。
- 手势通知按 `refreshFps` 节流。

### 约束

- 触摸板双指缩放未单独适配，主要依赖滚轮事件。
- 框选和测量手柄命中依赖标签区域判断，后续 UI 变更需同步命中逻辑。

## Views/RawDataPage

### 当前状态

- 页面命名为“数据收发”，同时显示接收和发送数据。
- 支持文本/HEX 显示、时间戳、HEX 自动格式化、发送后保留、行尾追加。
- 接收显示使用虚拟滚动，最大显示 500 行。
- 统计信息位于接收区右下角。

### 约束

- Flutter Windows 的 `ListView + Tooltip` 组合存在已知 accessibility 日志噪声，不影响功能。

## Windows/NativeSerialReader

### 当前状态

- 使用 Windows API + Overlapped IO 读取串口。
- Dart API DL 初始化后，通过 `Dart_PostCObject_DL` 回调 Dart。
- 读线程 10ms 超时，关闭时先取消读再 join 线程。
- CMake 构建，输出 DLL 到 Windows runner 目录。

### 约束

- 仅支持 Windows。
- Dart API DL 必须在启动读取前初始化。

## TestTools

### 当前状态

- `zobow_device.py` 模拟 Zobow 设备，支持 4/8 通道配置帧和周期发送。
- `justfloat_device.py` 模拟 VOFA JustFloat 设备，接收 `r [地址...]` 后按地址数量输出对应通道数。
- 两个模拟脚本支持单键控制：`p` 暂停/恢复发送，`r` 复位到等待命令状态，`c` 关闭脚本；Windows 下无需回车。
- `generate_plot_bin.py` 可生成绘图页可直接导入的 BIN 测试文件，支持包数、通道数和数据模式。

### 约束

- 依赖 `pyserial`。
- busy-wait 定时会消耗较高 CPU。
- 默认面向 Windows COM 端口。

## CI/GitHub Actions

### 当前状态

- `.github/workflows/windows-release.yml` 负责 PR 检查、手动构建和 tag 发布。
- PR 到 `main` 会运行 `flutter analyze`、`flutter test` 和 Windows Release 构建。
- `v*` tag 会测试、构建、压缩发布包并创建 GitHub Release。
- `main` 直接 push 不触发 release workflow，避免合并后和 tag 发布重复执行。

### 约束

- Release 依赖仓库 Actions 权限允许 `contents: write`。
- 发布包来自 `build/windows/x64/runner/Release`。
- 日常开发先确认分支，避免直接把开发改动提交到 `main`。

## 提交前建议检查

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
