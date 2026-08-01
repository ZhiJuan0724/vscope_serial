# SerialTools

SerialTools 是面向 Windows 的串口收发与波形分析工具，支持实时绘图、Shell/YMODEM、RTT Viewer 和运行态探针绘图。

![Platform](https://img.shields.io/badge/platform-Windows-42A5F5)
![Flutter](https://img.shields.io/badge/Flutter-3.x-blue)
![License](https://img.shields.io/badge/license-MIT-43A047)

![SerialTools 主界面](docs/images/main-window.png)

## 功能概览

- 串口枚举、连接和状态检测；文本/HEX 收发、时间戳、自动换行、多种编码及多条发送。
- FireWater、固定帧、Zobow、JustFloat 接收协议，以及独立的发送协议和地址配置。
- 最多 16 个普通通道和 4 个数学通道；支持缩放、平移、跟随、光标、观察、Delta X/Y、区间统计、图例和实时值。
- CSV、BIN、旧版 DAT 数据导入及流式导出；大数据使用 LOD 绘制。
- 可选 Shell 页面，支持串口/TCP普通终端、SSH、ANSI、命令行/逐键输入、命令历史和串口YMODEM。
- 可选 RTT Viewer 与探针绘图，支持 J-Link、CMSIS-DAP、RTT Up/Down、HSS 和 ELF 符号选择。
- 稳定版/Beta 更新通道、更新包校验和本地版本回退。

## 下载与启动

1. 从 [GitHub Releases](https://github.com/ZhiJuan0724/vscope_serial/releases) 或 [Gitee Releases](https://gitee.com/ZhiJuan0724/vscope_serial/releases) 下载 Windows ZIP。
2. 完整解压到可写目录，不要直接在压缩包中运行。
3. 启动 `vscope_serial.exe`。

支持 Windows 10/11 x64。设置、配置、日志、导出和更新文件保存在程序目录，因此不建议放在无写入权限的位置。

## 快速开始

### 串口收发

1. 点击窗口左下角串口状态区域。
2. 选择端口和串口参数后连接。
3. 在“数据收发”页选择文本或 HEX、编码、时间戳、自动换行和行尾。
4. 输入内容发送；停止接收后可导出文本或 BIN。

端口列表默认只读取 COM 号。需要设备名称时，在连接窗口开启“显示详细信息”并手动刷新。

显示行数只限制界面缓存，不影响容量内的完整原始数据。完整字节记录上限为 `512 MiB`：80% 时预警，达到上限后停止原始接收并保留已有数据，清空后可继续。

### 串口绘图

1. 打开“绘图”页，选择接收协议。
2. 按需选择发送协议、地址配置和通道参数。
3. 点击“开始绘图”。
4. 使用鼠标、触控板或工具栏缩放、平移、测量、观察和导出。

绘图期间会锁定协议、地址和导入导出。启用“保持绘图”后，仅相同协议且通道数一致的新数据流可续接历史。

| 操作 | 效果 |
| --- | --- |
| 滚轮/触控板捏合 | 缩放 X 轴 |
| `Shift + 滚轮` | 缩放 Y 轴 |
| 鼠标或触控板拖动 | 平移视口 |
| `Shift + 左键拖动` | 按起始方向缩放 X 或 Y |
| 通道右键 | 通道设置、偏置和数学通道操作 |
| 工具栏 | 跟随、光标、观察、测量、图例和实时值 |

串口绘图最大可见范围为 `1M~10M` 点，历史内存预算为 `1~8 GiB`；达到预算会停止采集并保留已有历史和导出能力。

![SerialTools 实时绘图](docs/images/plot-window.png)

## 协议

| 协议 | 格式/用途 |
| --- | --- |
| FireWater | 逗号分隔的 ASCII 数值 |
| 固定帧 | 自定义帧头、帧尾和通道类型；数据字段固定小端，校验和字节序可配置，并支持 CRC |
| Zobow | 4/8 通道固定帧，CRC16/MODBUS |
| JustFloat | 小端 `float32` 数组及固定帧尾 |
| r 协议 | 向设备发送通道地址的文本命令 |

固定帧、Zobow 和 r 协议可在相应设置中配置；地址配置支持 JSON/CSV 导入导出，Zobow 还支持从 C 代码识别。

## Shell 与 YMODEM

Shell 默认隐藏，可通过主标签末尾的“+”添加。它提供“普通/SSH”两种模式，并使用独立的编码、行尾、本地回显、字体和滚动历史：

- ANSI 终端、命令行和逐键输入。
- UTF-8、GBK、BIG5、Shift_JIS、EUC-KR 等流式文本解码。
- `Ctrl+C` 发送 ETX；`Ctrl+Shift+C` 或右键复制。
- 普通模式支持串口或TCP客户端；YMODEM文件发送/接收仅用于串口。
- SSH模式支持密码或PEM私钥认证、主机指纹确认和PTY终端，密码及私钥口令不会保存。
- 命令历史和终端文本导出。

接收文件默认保存到 `<程序目录>/exports/ymodem/`。

## RTT Viewer 与探针绘图

RTT Viewer 默认隐藏，可在高级设置的“页面”中开启；启用后同时显示“探针绘图”页。

- RTT Viewer：虚拟终端 0～15、All Terminals、RTT Down 0、暂停、时间戳、文本/HEX、导出。
- 探针绘图：RTT Up 通道、运行态 HSS、J-Scope 格式识别及 ELF/AXF/OUT 数据符号选择。
- 后端：外部 J-Link、外置 OpenOCD、随发布包提供的内置 OpenOCD，以及用户 Python 环境中的 pyOCD `0.45.x`。
- CMSIS-DAP 自动顺序：外置 OpenOCD → 内置 OpenOCD → 外置 pyOCD；连接失败不会静默切换后端。
- RTT 控制块支持 Auto、指定地址或指定范围；OpenOCD 使用指定地址或范围。

探针监控严格非侵入：RTT Viewer、RTT 绘图和 HSS 不执行停核、复位、恢复、烧录、擦除或核心调试操作。高频 RTT 数据不写普通日志。

## 数据目录与诊断

| 目录 | 内容 |
| --- | --- |
| `settings/` | 应用设置 |
| `config/` | 协议、通道和多条发送配置 |
| `logs/` | 运行日志 |
| `crash_dumps/` | Windows 原生崩溃转储和元数据 |
| `exports/` | 数据及 YMODEM 文件 |
| `updates/` | 更新缓存和回退版本 |

“恢复默认设置”不会删除 `config/` 中的用户配置。崩溃转储默认开启，可能包含少量运行时内存，请确认后再提供。

本地分析转储时，将 `tools/analyze_crash_dump.ps1`、`.dmp`、同名 `.json`、日志和对应 PDB 放在同一目录，运行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\analyze_crash_dump.ps1
```

脚本会检查文件和符号匹配情况，并生成中文 Markdown 报告。需要安装 Windows SDK 的 Debugging Tools for Windows；离线分析可增加 `-Offline`。

## 更新、开发与许可

应用信息页用于选择稳定版/Beta 通道、更新来源、检查更新；高级设置提供功能入口、内存设置、诊断和本地回退。更新包会校验大小和 SHA-256。

开发环境、测试、构建和发布见 [DEVELOPMENT.md](DEVELOPMENT.md)，长期架构约束见 [docs/CONTEXT.md](docs/CONTEXT.md)。

本项目使用 [MIT License](LICENSE)。
