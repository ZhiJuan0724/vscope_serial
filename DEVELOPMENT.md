# SerialTools 开发指南

本文面向项目开发者，集中说明环境依赖、运行构建、测试工具、CI 发布和工程约束。用户使用说明见 [README.md](README.md)。

`docs/CONTEXT.md` 是长期项目事实和架构约束的权威记录；`AGENTS.md` 是自动化开发工具必须遵守的短规则。如本文与这两个文件不一致，以后两者为准。

## 开发环境

### 必需依赖

| 依赖 | 要求 | 用途 |
| --- | --- | --- |
| Windows | Windows 10/11 x64 | 当前唯一维护的平台 |
| Flutter | Stable，需提供 Dart `>=3.7.2` | 应用开发与构建 |
| Visual Studio 2022 | 安装“使用 C++ 的桌面开发”工作负载 | Flutter Windows、CMake 和 MSVC 构建 |
| PowerShell | PowerShell 7，命令为 `pwsh` | 代码、文档和构建脚本操作 |
| Python | 3.7 或更高版本 | 发布打包和串口测试工具 |
| Git | 当前稳定版 | 版本控制 |

可选依赖：

- `pyserial`：运行串口模拟工具。
- 7-Zip：发布脚本优先使用；未安装时回退到 Python ZIP。
- com0com 或 Virtual Serial Port Driver：创建虚拟串口对。

```powershell
python -m pip install pyserial
flutter config --enable-windows-desktop
flutter doctor
```

### Flutter 依赖

核心运行依赖包括：

- `provider`：状态管理。
- `ffi`：调用 Windows 原生串口 DLL。
- `file_picker`、`path_provider`：文件和路径访问。
- `xterm`：Shell 终端渲染。
- `charset`：多编码文本收发。
- `archive`、`crypto`：更新包处理与校验。
- `window_manager`：Windows 窗口生命周期。
- `flutter_svg`：SVG 图标。

测试与静态检查使用 Flutter SDK 自带的 `flutter_test`、`integration_test` 和 `flutter_lints`。

## 初始化与运行

所有仓库读写命令使用 PowerShell 7：

```powershell
pwsh
flutter pub get
flutter run -d windows
```

直接构建未打包的 Windows Release：

```powershell
$buildTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
flutter build windows --release "--dart-define=BUILD_TIME=$buildTime"
```

构建输出位于：

```text
build/windows/x64/runner/Release/
```

## 项目结构

```text
lib/
├── core/                 # 日志、CRC、本地化文本和通用工具
├── data/
│   ├── models/           # 协议、通道、绘图和配置模型
│   ├── parser/           # 接收协议解析器
│   └── source/           # 实时与导入数据源
├── services/             # 串口、设置、更新、文件和系统服务
├── viewmodels/           # 页面状态与业务流程
├── views/
│   ├── dialogs/          # 配置和操作弹窗
│   ├── pages/            # 数据收发、Shell 与绘图页面
│   ├── plot/             # 绘图 Painter、视口和手势
│   └── widgets/          # 通用组件
└── main.dart

windows/                  # Windows Runner、更新器和原生串口 DLL
test/                     # 单元测试与 Widget 测试
integration_test/         # Windows Profile 性能测试
test_tools/               # 模拟设备、数据生成和性能基准
tools/                    # 构建、更新资产和更新器测试脚本
docs/                     # 长期上下文、历史和设计文档
```

## 架构边界

- `lib/core/` 只承载通用底层能力。日志统一使用 `AppLogger`，不要直接 `print()`。
- 固定 UI 文本优先放入 `lib/core/localization/app_strings.dart`。
- 协议解析器兼容 `IDataParser.feed()` 和 `outputStream`；绘图高频接收链优先使用 `feedBatch()`，避免逐包 Stream 调度。
- `lib/services/` 管理串口、文件、设置、更新和系统资源，不承载页面布局。
- `lib/viewmodels/` 管理业务状态；`PlotViewModel` 是全局 Provider，页面切换不得丢失绘图状态；`ShellViewModel` 独立管理终端会话和文件传输。
- `lib/views/` 只处理页面、弹窗、Painter 和交互。
- `SerialService` 通过 `SerialActivityOwner` 原子管理数据收发、Shell 和绘图的接收活动；页面只能在所有者为 `none` 时切换。
- 所有串口写入入口共用有序后台写队列，页面和 ViewModel 不得绕过队列直接并发调用同步 FFI 写入。
- 绘图页使用 `Selector` 隔离工具栏、通道面板、绘图区和状态栏重建。
- 绘图区分为背景网格、数据、坐标轴和交互覆盖四层 Painter。
- 三个主页面使用统一工具栏组件；设置弹窗使用左侧分类导航和右侧连续内容，不为纯颜色、固定像素或图标外观编写脆弱测试。

## 代码检查与测试

提交前至少运行：

```powershell
dart format lib test integration_test
flutter analyze
flutter test
```

绘图重建隔离测试需要显式启用开发计数器：

```powershell
flutter test test/views/plot_page_rebuild_test.dart --dart-define=PLOT_PERF_METRICS=true
```

常用定向测试：

```powershell
flutter test test/data/models/plot_lod_index_test.dart
flutter test test/services/serial_activity_owner_test.dart
flutter test test/services/serial_service_raw_data_test.dart
flutter test test/services/shell_stream_decoder_test.dart
flutter test test/viewmodels/plot_viewmodel_test.dart
flutter test test/viewmodels/plot_viewmodel_window_test.dart
flutter test test/viewmodels/plot_viewmodel_stats_test.dart
flutter test test/views/shell_page_test.dart
flutter test test/views/raw_data_page_test.dart
flutter test test/parser/just_float_parser_test.dart
```

当前测试基线以行为、状态流转、数据格式和关键交互为主，不保留只断言颜色、字体、固定像素或单个图标的测试。最近一次完整验证结果为 `392 passed, 2 skipped`，并通过 `flutter analyze` 与 `git diff --check`；该数字只用于核对当前仓库状态，新增或删除测试后应同步更新。

更新器独立测试：

```powershell
python tools/test_updater.py
```

## 测试工具

完整参数和虚拟串口测试流程见 [test_tools/README.md](test_tools/README.md)。每个工具支持的命令行参数都应在该文档中同步维护。

| 工具 | 用途 |
| --- | --- |
| `zobow_device.py` | 模拟 Zobow 配置和 4/8 通道数据帧 |
| `justfloat_device.py` | 模拟 r 命令与 JustFloat 数据 |
| `shell_device.py` | 模拟 Shell、ANSI 和 YMODEM 对端 |
| `text_sender.py` | 验证多编码文本发送、换行和回显 |
| `generate_plot_bin.py` | 生成大规模绘图 BIN 数据 |
| `zobow_c_profile_import.dart` | 独立验证 C 配置导入 |
| `run_plot_benchmark.ps1` | 运行 Windows Profile 绘图性能基准 |

典型虚拟串口流程：

1. 创建 `COM13 <-> COM14` 虚拟串口对。
2. SerialTools 连接 `COM13`。
3. 测试脚本连接 `COM14`。
4. 启动绘图或收发，验证暂停、复位、断开和异常恢复。

```powershell
python test_tools/zobow_device.py --port COM14 --mode sine --preset 4k --baud 2000000
python test_tools/justfloat_device.py --port COM14 --mode sine --interval 1
python test_tools/shell_device.py --port COM14 --mode terminal
python test_tools/text_sender.py --port COM14 --encoding GBK --mode mixed
```

绘图性能基准只用于同一台机器的前后对比，不作为 CI 耗时门禁：

```powershell
pwsh -File test_tools/run_plot_benchmark.ps1 -Preset quick -Label baseline
pwsh -File test_tools/run_plot_benchmark.ps1 -Preset soak -Label soak
```

报告输出到未跟踪的 `build/performance/`。

## 构建与打包

推荐使用项目脚本完成分析、测试、Release 构建和便携包生成：

```powershell
python tools/build_release.py
```

常用参数：

```powershell
python tools/build_release.py --skip-analyze
python tools/build_release.py --skip-test
python tools/build_release.py --skip-build
python tools/build_release.py --no-zip
python tools/build_release.py --version 1.0.7-beta.4
```

便携包输出到 `build/releases/`。脚本会复制原生 DLL 和可用的 VC++ 运行时，并调用 `tools/generate_update_assets.py` 生成更新资产。

手动生成更新资产：

```powershell
python tools/generate_update_assets.py `
  --bundle build/windows/x64/runner/Release `
  --tag v1.0.7-beta.4 `
  --output dist
```

Release 必须同时包含：

- `vscope_serial-windows-vX.Y.Z.zip`
- `update-manifest-vX.Y.Z.json`

## CI 与发布

`.github/workflows/windows-release.yml` 负责：

- PR 到 `main`：静态分析、完整测试和 Windows Release 构建。
- 手动触发：执行同一套测试与构建流程。
- 推送 `v*` tag：创建 GitHub Release，并将同一批附件同步到 Gitee。

版本规则：

- 稳定版：`pubspec.yaml` 使用 `X.Y.Z`，tag 使用 `vX.Y.Z`。
- Beta：`pubspec.yaml` 使用 `X.Y.Z-beta.N`，tag 使用 `vX.Y.Z-beta.N`。
- tag 去掉 `v` 后必须与 `pubspec.yaml` 完全一致。
- `CHANGELOG.md` 必须存在与完整 tag 同名的版本段落。
- Beta Release 必须标记为 prerelease。

发布示例：

```powershell
git tag v1.0.7-beta.4
git push origin dev
git push origin v1.0.7-beta.4
```

`main` 的普通 push 不触发发布，避免分支合并和 tag 重复构建。

## 工程约束

### 文件、设置与日志

- 设置保存到 `<exe_dir>/settings/settings.json`；新增字段必须提供兼容旧配置的默认值，不创建单独迁移脚本。
- 设置文件不加密，不得保存敏感数据。
- 恢复默认设置不得删除 `config/` 中用户保存的协议配置。
- 更新、日志和导出均写入程序目录，因此 Release 运行目录必须可写。
- 原始数据界面缓存和完整原始字节分离；显示行数限制不得影响完整导出。

### Windows 串口

- 串口打开、健康检查和枚举由 `native_serial_reader.dll` 执行，所有可能阻塞驱动的操作必须位于 UI isolate 外。
- 默认枚举只读取 COM 号；仅在用户主动开启详细信息并手动刷新时读取友好名称。
- 自动刷新、设备插拔和自动连接不得读取设备名称、打开串口或遍历 USB Hub。
- 已连接端口和历史端口连接不得依赖枚举成功。
- 枚举失败或超时必须保留缓存列表、用户端口和串口参数。
- 关闭窗口前必须断开串口，避免原生读取线程异常。

### 协议与原始收发

- Zobow 固定支持 4/8 通道；地址按十六进制数值处理。
- r 协议地址必须保留十进制或带 `0x` 前缀的十六进制文本格式。
- FixedFrame 通道数为 `1~16`，帧头和帧尾不能同时全部为 `0`。
- FireWater 只处理 ASCII 数值文本；随机源只输出 FireWater。
- 数据收发页的多条发送配置保存在 `<exe_dir>/config/multi_send/`；运行期间禁止切换配置、编辑、排序、导入导出和单条发送。
- Shell 是独立页面，不提供 HEX 输入或输出；Shell 编码、命令行行尾、本地回显、滚动历史和外观均使用独立设置。
- Shell 接收字节由会话控制器流式解码后写入终端，不经过普通文本行格式化；多字节字符跨数据块时不得产生替换字符或丢失。
- Shell 接收队列每帧最多消费 `64 KiB`，只安排一次滚动和重绘；达到上限后继续在后续帧处理。
- YMODEM 传输必须使用统一串口写入口；传输期间禁止普通发送和逐键发送。
- Shell 中 `Ctrl+C` 发送 ETX；复制使用 `Ctrl+Shift+C` 或右键。

### 绘图与性能

- `PlotLodIndex` 只存在于内存，不改变原始数据和导出结果。
- 当前精确窗口上限由用户设置决定，不得使用固定常量绕过配置。
- 大范围绘图质量分为性能优先、均衡和质量优先：性能优先使用正常选取的 LOD，均衡使用更细一级，质量优先使用更细两级；档位只改变绘制采样，不改变历史数据和导出结果。
- 高频模式只降低运行时刷新和绘制压力，不得丢弃完整历史数据。
- 定位条只映射完整 X 数据边界和当前视口，不绘制全量曲线，也不得因主图 Y 轴、通道偏置或缩放而触发额外数据处理。
- 绘图重绘通过 `dataRevision`、`channelConfigRevision`、`viewportRevision` 和 `overlayRevision` 分类；新增状态必须归入正确 revision。
- 不得在 Flutter build 阶段直接修改 ViewModel；动态布局使用临时渲染状态或事件阶段更新。
- 数据批量更新不应重建工具栏和通道面板；光标移动只应重绘覆盖层。
- 大数据或高频改动必须验证 LOD、数学通道、拖动缩放和停止后的响应。

### UI 与状态

- 数据收发、Shell 或绘图开始实际接收后必须取得对应 `SerialActivityOwner`；活动期间锁定页面切换，停止、断线或启动失败时必须释放所有者。
- 绘图运行时锁定协议、配置、地址、数据导入导出和随机源开关；随机源频率仍允许调整。
- 通道名称可在绘图期间修改，通道地址只能在停止后修改。
- 通道列表使用可回收列表，不要把必须持久存在的编辑状态仅放在 item state 中。
- 应用窗口最小宽度统一为 `800px`；多条发送扩展的打开/关闭需要先同步原生窗口几何，再切换 Flutter 内容，避免窄面板闪现和累计扩宽。
- 工具栏、开始按钮、下拉选择和设置底部操作统一使用公共组件；相关测试验证行为和可用状态，不锁定颜色、固定间距或具体图标。
- Windows 根节点当前使用 `ExcludeSemantics` 规避 Flutter `Tooltip`/下拉控件的 semantics 日志洪泛；升级 Flutter 时应重新验证上游问题。

### 更新

- 发布构建必须注入 `BUILD_TIME`。
- 更新器只覆盖 `app-files.json` 管理的文件，保留 `settings/`、`config/`、`logs/`、`exports/` 和未知用户文件。
- 更新缓存和稳定版/Beta 回退槽保存在 `<exe_dir>/updates/`。
- 更新包安装前必须校验清单、文件大小和 SHA-256。

### Git 与文档

- 开发分支为 `dev`，发布分支为 `main`。
- 提交信息使用中文，并保持 Conventional Commits 风格。
- 不回滚或覆盖他人已有修改，除非得到明确要求。
- 提交前检查 `git status`，只暂存当前任务文件。
- `CHANGELOG.md` 只记录用户可感知变化；发布前必须核对对应版本段落和日期。
- force push 前必须明确确认目标分支或 tag。
- 代码和文档读写统一使用 `pwsh`，不得根据 Windows PowerShell 5.1 的乱码输出来判断文件内容。
