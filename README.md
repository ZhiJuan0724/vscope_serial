# VScope Serial

VScope Serial 是一个基于 Flutter 的 Windows 串口波形工具，用于串口数据接收、协议解析、实时绘图、测量统计和大文件回看。

![Platform](https://img.shields.io/badge/platform-Windows-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)

## 功能概览

### 串口通信

- Windows 串口枚举、连接和配置。
- 底部状态栏快速打开串口连接弹窗。
- 操作结果和错误通过浮动 SnackBar 临时提示，避免遗漏重要反馈。
- 原始数据收发页支持文本/HEX 显示、发送内容回显、时间戳和自动行尾。
- Windows 读取路径使用原生 DLL，降低 Dart 层串口读取不稳定的影响。

### 协议解析

- FireWater：CSV 风格文本数据，支持自动识别或固定通道数。
- 固定帧头：自定义帧头、数据类型、通道数、校验和帧尾。
- Zobow：4/8 通道固定帧，CRC16/MODBUS 校验；地址和 `uint16/int16` 类型在通道面板中配置。
- JustFloat：VOFA 小端 `float32` 数组 + `00 00 80 7F` 帧尾，支持自动通道数识别。
- 绘图页分别选择接收协议和发送协议。发送协议默认是“无”；Zobow 接收协议固定使用内置二进制初始化帧。
- `r协议` 发送 UTF-8 文本命令 `r 地址1 地址2 ...\n`，地址支持十进制和 `0x` 前缀十六进制，并保留输入格式。
- FireWater 和 JustFloat 使用自动通道识别时，开始绘图前显示全部 16 个通道槽位，便于预先填写多通道 r 地址。

### 绘图

- 最多 16 通道显示，每通道可设置颜色、名称、显示、偏置、缩放、线宽和点半径。
- 当前精确窗口默认上限 `1,000,000` 点，可在高级设置中调整到 `40,000,000` 点。
- 内存级 `PlotLodIndex` 用于大窗口绘制，拖动/缩放时优先绘制 LOD 预览，小窗口使用精确点。
- 抗锯齿固定开启。
- 网格支持稀疏、普通、密集三档。

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
flutter build windows --release
```

## 基本使用

1. 在底部状态栏连接串口，或在绘图页启用随机数据源。
2. 在绘图页选择接收协议，并按需选择发送协议：无、`r协议`，或 Zobow 自动使用的内置发送帧。
3. 点击“开始”进入绘图。
4. 使用滚轮、拖拽、框选、测量和观察线查看波形细节。
5. 需要大文件回看时，使用文件导入，等待进度弹窗完成。

## 高级设置

绘图页工具栏的设置按钮打开高级设置：

- 网格显示和网格密度。
- 绘图刷新率：`30~60 fps`，默认 `60 fps`，使用输入框设置。
- 绘图字体大小偏移。
- 吸附点高亮：开关和直径 `6~12 px`。
- 绘图窗口上限：`1,000,000~40,000,000` 点，默认 `1,000,000` 点。

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
lib/
├── core/           # 工具类、日志、CRC
├── data/           # 数据模型、解析器、数据源
├── services/       # 串口服务、设置持久化、原生读取
├── viewmodels/     # MVVM 视图模型
├── views/          # 页面、弹窗和绘图组件
│   ├── plot/       # PlotPainter、PlotViewport、手势处理
│   └── pages/      # 绘图、数据收发、协议页面
└── main.dart
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
git tag v1.0.3
git push origin v1.0.3
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
