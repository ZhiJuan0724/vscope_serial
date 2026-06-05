# VScope Serial

VScope Serial 是一个基于 Flutter 的 Windows 串口波形工具，用于串口数据接收、协议解析、实时绘图、测量统计和大文件回看。

![Platform](https://img.shields.io/badge/platform-Windows-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)

## 功能概览

### 串口通信

- Windows 串口枚举、连接和配置。
- 底部状态栏快速打开串口连接弹窗。
- 操作结果和错误通过浮动 SnackBar 临时提示，避免遗漏重要反馈；可在应用信息页的高级设置中全局关闭临时提示。
- 原始数据收发页支持文本/HEX 显示、发送内容回显、时间戳和自动行尾。
- Windows 读取路径使用原生 DLL，降低 Dart 层串口读取不稳定的影响。

### 协议解析

- FireWater：CSV 风格文本数据，支持自动识别或固定通道数。
- 固定帧协议：自定义可选帧头、帧尾和固定通道数；通道类型可统一配置或逐通道设置，支持 CRC-8/16/32 多项式、CRC 位于帧尾前后以及大小端字节序。
- Zobow：4/8 通道固定帧，CRC16/MODBUS 校验；地址和 `uint16/int16` 类型在通道面板中配置。
- JustFloat：VOFA 小端 `float32` 数组 + `00 00 80 7F` 帧尾，支持自动通道数识别。
- 绘图页分别选择接收协议和发送协议。发送协议默认是“无”；Zobow 接收协议固定使用内置二进制初始化帧。
- `r协议` 发送 UTF-8 文本命令 `r 地址1 地址2 ...\n`，地址支持十进制和 `0x` 前缀十六进制，并保留输入格式。
- FireWater 和 JustFloat 使用自动通道识别时，开始绘图前显示全部 16 个通道槽位，便于预先填写多通道 r 地址。
- Zobow/r 地址配置支持 JSON 和 CSV 导入；CSV 两列分别是通道名称和通道地址，并会按地址格式智能识别表头。

### 绘图

- 最多 16 通道显示，每通道可设置颜色、名称、显示、偏置、缩放、线宽和点半径。
- 当前精确窗口默认上限 `1,000,000` 点，可在高级设置中调整到 `40,000,000` 点。
- 内存级 `PlotLodIndex` 用于大窗口绘制，拖动/缩放时优先绘制 LOD 预览，小窗口使用精确点。
- 抗锯齿固定开启。
- 网格支持稀疏、普通、密集三档。
- 多通道偏置模式下，右侧独立 Y 轴刻度列会按文本宽度动态调整，避免长数值挤占相邻通道。

### 交互与测量

- 鼠标滚轮缩放，Shift+滚轮进行 Y 轴缩放。
- 拖拽平移、框选放大、撤回视口。
- X-X、Y-Y、统计范围和观察线都吸附当前显示窗口内的数据点。
- 吸附点可高亮显示，高级设置中可开关，直径范围 `6~12 px`，默认 `8 px`。
- 吸附高亮固定在吸附时的数据点；缩放后若该点不在当前窗口内则自动隐藏。
- 统计显示 Max/Min/Avg、样本数和实际数据点 index 范围；大范围统计会采样并标注近似。

### 文件与测试数据

- CSV/BIN 导入导出，支持导入旧版虚拟示波器 `.dat` 文件。
- 大文件导入异步执行，并显示进度弹窗。
- Zobow/FixedFrame 导出可基于运行期内保留的原始固定帧数据。
- `test_tools/generate_plot_bin.py` 可生成大规模 BIN 测试文件，便于直接导入绘图页测试。

## 快速开始

### 环境要求
- Flutter 3.x
- Windows 10/11
- Visual Studio 2022（Windows 桌面开发）

### 运行

```bash
flutter pub get
flutter run -d windows
```

### 构建 Release

```bash
python tools/build_release.py
```

## 基本使用

1. 在底部状态栏连接串口，或在绘图页启用随机数据源。
2. 在绘图页选择接收协议，并按需选择发送协议：无、`r协议`，或 Zobow 自动使用的内置发送帧。
3. 点击“开始”进入绘图。
4. 使用滚轮、拖拽、框选、测量和观察线查看波形细节。
5. 需要大文件回看时，使用文件导入，等待进度弹窗完成。

## 高级设置

绘图页工具栏的设置按钮打开绘图高级设置：

- 网格显示和网格密度。
- 绘图刷新率：`30~60 fps`，默认 `60 fps`，使用输入框设置。
- 绘图字体大小偏移。
- 吸附点高亮：开关和直径 `6~12 px`。
- 绘图窗口上限：`1,000,000~40,000,000` 点，默认 `1,000,000` 点。

应用信息页提供应用级高级设置：

- 显示应用名称、版本、构建时间和当前/上一版本说明。
- 支持手动检查更新，并可开启启动时自动检查更新。
- 可全局关闭应用内临时提示信息。

## 测试工具

测试工具位于 `test_tools/`：

```bash
pip install pyserial
```

Zobow 设备模拟：

```bash
python test_tools/zobow_device.py --port COM14 --mode sine --interval 1
```

JustFloat 设备模拟：

```bash
python test_tools/justfloat_device.py --port COM14 --mode sine --interval 1
```

模拟脚本运行时支持单键控制：`p` 暂停/恢复发送，`r` 复位到等待命令状态，`c` 关闭脚本。

生成可导入绘图页的 BIN 文件：

```bash
python test_tools/generate_plot_bin.py --output E:\temp\vscope_180w_8ch.bin --packets 1800000 --channels 8
python test_tools/generate_plot_bin.py -o E:\temp\step_100w_4ch.bin -n 1000000 -c 4 --mode step
```

## 项目结构

```text
lib/                    # Flutter 应用源码
├── core/               # 通用工具、日志、CRC 等基础能力
├── data/
│   ├── models/         # 绘图、协议、通道、设置等数据模型
│   ├── parser/         # JustFloat、Zobow、固定帧等协议解析
│   └── source/         # 绘图数据源和导入数据源
├── services/           # 串口、设置、更新检查、配置导入、原生读取等服务
├── viewmodels/         # 绘图、协议、原始数据等 MVVM 状态
├── views/
│   ├── dialogs/        # 配置、通道、应用信息等弹窗
│   ├── pages/          # 绘图、数据收发、协议页面
│   ├── plot/           # PlotPainter、PlotViewport、手势和坐标轴组件
│   └── widgets/        # 通用 UI 组件
└── main.dart           # 应用入口

test/                   # 单元测试和组件测试
├── data/               # 模型、解析器、数据源测试
├── parser/             # 协议解析兼容测试
├── services/           # 服务层测试
├── viewmodels/         # ViewModel 行为测试
└── views/              # 绘图视图组件测试

test_tools/             # 串口模拟器、绘图 BIN 生成器和测试数据
tools/                  # 发布构建脚本
docs/                   # 项目上下文、历史记录和 TODO
resources/              # 字体等资源文件
windows/                # Windows 桌面端原生工程和串口读取 DLL
```

## 开发检查

```bash
dart format lib test
flutter test
flutter analyze
```

常用定向测试：

```bash
flutter test test/data/models/plot_lod_index_test.dart
flutter test test/viewmodels/plot_viewmodel_test.dart
flutter test test/viewmodels/plot_viewmodel_window_test.dart
flutter test test/viewmodels/plot_viewmodel_stats_test.dart
flutter test test/parser/just_float_parser_test.dart
```

## CI 与发布

- PR 到 `main` 会运行静态分析、测试和 Windows Release 构建。
- 手动构建可通过 GitHub Actions `workflow_dispatch` 触发。
- 推送 `v*` tag 会构建发布包并创建 GitHub Release。

```bash
git tag v1.0.5
git push origin v1.0.5
```

## 主要依赖

- `flutter_libserialport`：串口枚举
- `provider`：状态管理
- `path_provider`：路径获取
- `file_picker`：文件选择
- `logger`：日志
- `ffi`：原生 DLL 接入
- `window_manager`：窗口生命周期管理

## License

MIT
