# 测试工具

`test_tools/` 保存设备模拟、测试数据生成、后端/更新器验证、稳定性压测和绘图性能基准工具。

## 目录

- [环境要求](#sec-env)
- [控制按键](#sec-keys)
- [Zobow 协议模拟](#sec-zobow)
- [JustFloat 协议模拟](#sec-justfloat)
- [Modbus 从站模拟](#sec-modbus)
- [Shell/YMODEM 模拟](#sec-shell)
- [多编码文本发送](#sec-text)
- [绘图 BIN 生成](#sec-bin)
- [Zobow C 配置导入](#sec-zobow-c)
- [Windows 更新器测试](#sec-updater)
- [建议测试流程](#sec-flow)
- [绘图性能基准](#sec-benchmark)
- [P1 稳定性压测](#sec-p1)

## 工具总览

| 工具 | 类别 | 用途 | 介质/模式 | 章节 |
| --- | --- | --- | --- | --- |
| `zobow_device.py` | 协议模拟 | Zobow 4/8 通道数据帧模拟，CRC16/MODBUS | 串口 | [Zobow 协议模拟](#sec-zobow) |
| `justfloat_device.py` | 协议模拟 | VOFA JustFloat `float32` 帧模拟，`r` 命令配置 | 串口 | [JustFloat 协议模拟](#sec-justfloat) |
| `modbus_device.py` | 协议模拟 | Modbus 从站，按标准实现，支持 RTU/ASCII/TCP | 串口 / TCP | [Modbus 从站模拟](#sec-modbus) |
| `shell_device.py` | 协议模拟 | Shell ANSI 终端回显 + YMODEM 收发对端 | 串口 | [Shell/YMODEM 模拟](#sec-shell) |
| `text_sender.py` | 协议模拟 | 按指定编码/行尾持续发送文本，验证解码与换行 | 串口 | [多编码文本发送](#sec-text) |
| `generate_plot_bin.py` | 数据生成 | 生成绘图页可导入的大数据 `.bin` 文件 | 文件 | [绘图 BIN 生成](#sec-bin) |
| `zobow_c_profile_import.dart` | 数据生成 | 解析 C 文件中的 Zobow 通道地址预设为 JSON | 文件 | [Zobow C 配置导入](#sec-zobow-c) |
| `test_updater.py` | 更新器验证 | `vscope_updater.exe` 端到端冒烟（回退/保留/拒绝替换） | 本地 exe | [Windows 更新器测试](#sec-updater) |
| `run_plot_benchmark.ps1` | 性能基准 | Windows Profile 绘图性能基准（帧/内存/重绘） | 应用 | [绘图性能基准](#sec-benchmark) |
| `run_p1_stability_soak.ps1` | 稳定性 | 1 GiB+ 噪声/BIN 导入门禁，24h 真实串口 soak | 应用/串口 | [P1 稳定性压测](#sec-p1) |

**快速选择**：验证上位机串口协议 → [Zobow](#sec-zobow) / [JustFloat](#sec-justfloat) / [Modbus](#sec-modbus) / [Shell](#sec-shell) / [文本](#sec-text)；验证绘图大数据 → [BIN 生成](#sec-bin)；验证发布链路 → [更新器](#sec-updater)；开发期性能对比 → [绘图基准](#sec-benchmark) / [P1 压测](#sec-p1)。

<a id="sec-env"></a>

## 环境要求

```bash
pip install pyserial
```

Windows 下可以使用 com0com 或 Virtual Serial Port Driver 创建虚拟串口对。例如创建 `COM13 <-> COM14`，VScope Serial 连接 `COM13`，测试脚本连接 `COM14`。

<a id="sec-keys"></a>

## 控制按键

`zobow_device.py` 和 `justfloat_device.py` 运行时支持单键控制，Windows 下直接按键即可，无需回车：

- `p`：暂停/恢复发送。
- `r`：复位到等待接收配置/读取命令状态。
- `c`：关闭脚本。

<a id="sec-zobow"></a>

## Zobow 协议模拟

`zobow_device.py` 模拟 Zobow 设备：

- 接收配置帧。
- 按配置输出 4 或 8 通道数据帧。
- 数据帧使用 CRC16/MODBUS。

```bash
python zobow_device.py --port COM14
python zobow_device.py --port COM14 --baud 115200 --mode sine --interval 1
python zobow_device.py --port COM14 --mode random --interval 10
python zobow_device.py --port COM14 --mode sine --preset 4k --baud 2000000
python zobow_device.py --port COM14 --mode sine --preset 8k --baud 3000000
python zobow_device.py --port COM14 --mode ramp --rate 8000 --baud 3000000
python zobow_device.py --help
```

高频测试：

- 4/8 通道高频时需要足够高的串口波特率。脚本会在收到配置帧后按实际通道数估算最低波特率，低于估算值会打印警告。

参数：

- `--port/-p`：脚本连接的串口号，必填，例如 `COM14`。
- `--baud/-b`：串口波特率，默认 `115200`。
- `--mode/-m`：数据模式，支持 `sine`（正弦波，默认）、`random`（随机数据）、`ramp`（递增斜坡）和 `fixed`（固定递增）。
- `--interval/-i`：单帧发送间隔，单位毫秒，默认 `1`，即约 1000 帧/s。
- `--rate/-r`：自定义目标发送频率，单位 Hz；设置后覆盖 `--interval`。
- `--preset`：常用频率预设，支持 `1k`、`4k`、`8k`；优先级高于 `--rate` 和 `--interval`。
- `--batch-ms`：批量写入窗口，单位毫秒，默认 `1`。4kHz 默认每批约 4 帧，8kHz 默认每批约 8 帧，用于降低 Python 和串口写入调用开销。
- `--flush-every-batch`：每批写入后调用 `serial.flush()`；默认不启用。它更接近阻塞式串口写入，但可能显著降低高频发送速度。
- `--amplitude/-a`：生成数据的幅度，默认 `10000`。
- `--help/-h`：显示脚本参数帮助。

频率参数优先级为 `--preset`、`--rate`、`--interval`。三者同时提供时，只使用优先级最高的一项。

<a id="sec-justfloat"></a>

## JustFloat 协议模拟

`justfloat_device.py` 模拟 VOFA JustFloat 设备：

- 接收文本命令：`r [通道1地址] [通道2地址] ...\n`。
- 按命令中的地址数量自动确定输出通道数，最多 16 通道。
- 周期发送小端 `float32` 数组 + 帧尾 `00 00 80 7F`。

```bash
python justfloat_device.py --port COM14
python justfloat_device.py --port COM14 --mode sine --interval 1
python justfloat_device.py --port COM14 --mode ramp --interval 1
python justfloat_device.py --help
```

参数：

- `--port/-p`：脚本连接的串口号，必填，例如 `COM14`。
- `--baud/-b`：串口波特率，默认 `115200`。
- `--mode/-m`：数据模式，支持 `sine`（正弦波，默认）、`random`（随机数据）、`ramp`（递增斜坡）和 `fixed`（固定值）。
- `--interval/-i`：每帧发送间隔，单位毫秒，默认 `1`，即约 1000 帧/s。
- `--amplitude/-a`：生成数据的幅度，默认 `100`。
- `--help/-h`：显示脚本参数帮助。

<a id="sec-modbus"></a>

## Modbus 从站模拟

`modbus_device.py` 按 **Modbus 应用协议规范（V1.1b3）** 实现一个独立从站（服务器），用于验证上位机 Modbus 主站代码的协议正确性。它**不参照本项目任何编解码实现**，以便独立检验主站的帧格式、CRC/LRC、异常码与边界处理。

支持三种传输：

- `rtu`：RTU 模式。1 地址 + PDU + CRC16（低字节在前）；帧间 3.5 字符静默定界，帧内字符间隔 ≤1.5 字符。
- `ascii`：ASCII 模式。`:` 起始、`\r\n` 结束，每字节 2 个十六进制字符 + LRC（二进制补码）。
- `tcp`：TCP 模式。MBAP 头（事务ID + 协议ID=0 + 长度 + 单元ID）+ PDU，事务 ID 回显。**监听地址会打印在控制台。**

支持功能码：读线圈(0x01)、读离散输入(0x02)、读保持寄存器(0x03)、读输入寄存器(0x04)、写单线圈(0x05)、写单寄存器(0x06)、写多线圈(0x0F)、写多寄存器(0x10)。严格实现标准异常码（0x01 非法功能 / 0x02 非法数据地址 / 0x03 非法数据值 / 0x04 从站设备故障），并具备以下可用于暴露主站缺陷的校验：

- 读数量为 0 或超上限（线圈 2000 / 寄存器 125）→ 异常 0x03。
- 读地址+数量超出数据区 → 异常 0x02。
- 写单线圈值必须为 `0xFF00`/`0x0000`，否则异常 0x03。
- 写多线圈/寄存器的字节计数字段与数量不符 → 异常 0x03。
- 未知功能码 → 异常 0x01。
- RTU CRC 校验失败 / ASCII LRC 校验失败 / TCP 协议 ID 非 0 → 丢弃帧不响应。
- 广播地址（单元号 0）只写不响应。

```bash
# RTU：连接串口（默认波特率 115200，可用 --baud 覆盖）
python modbus_device.py --mode rtu --port COM14
python modbus_device.py --mode rtu --port COM14 --baud 9600 --unit 1 --verbose

# ASCII
python modbus_device.py --mode ascii --port COM14

# TCP：吐出监听地址（默认 127.0.0.1:502，--host/--port 可改）
python modbus_device.py --mode tcp --port 502
python modbus_device.py --mode tcp --host 0.0.0.0 --port 502 --verbose

# 对全部请求注入指定异常码（1/2/3/4），用于测试主站异常处理
python modbus_device.py --mode rtu --port COM14 --inject-exception 3

# 动态设备：前 64 个保持/输入寄存器每秒自增
python modbus_device.py --mode tcp --port 502 --auto-increment
```

参数：

- `--mode`：传输模式，必填，`rtu` / `ascii` / `tcp`。
- `--port/-p`：RTU/ASCII 为串口号（必填，如 `COM14`）；TCP 为监听端口（默认 `502`）。
- `--baud/-b`：RTU/ASCII 串口波特率，默认 `115200`。
- `--host`：TCP 监听地址，默认 `127.0.0.1`；`0.0.0.0` 时打印所有网卡地址。
- `--unit/-u`：从站单元号，默认 `1`。
- `--verbose/-v`：打印收到的请求与发送的响应/异常帧。
- `--inject-exception`：对全部请求注入异常码 `1`/`2`/`3`/`4`。
- `--init-value`：数据区初始值，默认 `0`。
- `--auto-increment`：前 64 个寄存器每秒自增，模拟动态设备。
- `--coils`/`--discrete-inputs`/`--holding-registers`/`--input-registers`：各数据区数量，默认 `65536`。
- `--help/-h`：显示参数帮助。

上位机连接提示：

- RTU/ASCII：上位机连接虚拟串口对的一侧（如 `COM13`），本脚本连接另一侧（`COM14`）。
- TCP：上位机以 TCP 客户端连接本脚本打印的监听地址。

<a id="sec-shell"></a>

## Shell/YMODEM 模拟

`shell_device.py` 模拟 Shell 终端设备和 YMODEM 对端。适合配合虚拟串口对验证数据收发页 Shell 模式。

虚拟串口示例：VScope Serial 连接 `COM13`，脚本连接 `COM14`。

终端 ANSI 回显测试：

```bash
python shell_device.py --port COM14 --mode terminal
```

终端模式中也可以直接输入 YMODEM 测试命令：

- `ysend`：脚本通过 YMODEM 发送文件给应用。启动脚本时传入 `--file E:\temp\tx.bin` 会发送该文件；未传 `--file` 时发送内置示例文本。输入命令后，在 VScope Serial 的 Shell 更多功能中点击“接收”。
- `yrecv`：脚本通过 YMODEM 接收应用发送的文件，保存到 `--output` 指定目录。输入命令后，在 VScope Serial 的 Shell 更多功能中点击“发送”。

在 VScope Serial 的 Shell 中输入普通文本会收到彩色 `echo` 响应。常用测试命令：

- `help`：显示命令列表。
- `ping`：返回 `pong`。
- `status`：返回模拟设备状态。
- `time`：返回脚本主机时间。
- `color`：测试 ANSI 前景色和反色。
- `ansi`：测试粗体、下划线、反色和组合颜色。
- `long`：输出多行内容，测试滚动。
- `clear`：测试 ANSI 清屏。
- `exit`：结束脚本。

测试“应用接收 YMODEM 文件”：先运行脚本，再在 VScope Serial 中点击 Shell 的“接收文件”。

```bash
python shell_device.py --port COM14 --mode ymodem-send --file E:\temp\tx.bin
```

测试“应用发送 YMODEM 文件”：先运行脚本，再在 VScope Serial 中点击 Shell 的“发送文件”并选择文件。

```bash
python shell_device.py --port COM14 --mode ymodem-receive --output E:\temp\ymodem_rx
```

参数：

- `--port`：脚本连接的串口号，必填，例如 `COM14`。
- `--baud`：串口波特率，默认 `115200`。
- `--timeout`：串口读写超时，单位秒，默认 `0.1`。
- `--mode`：运行模式，支持 `terminal`（Shell 交互，默认）、`ymodem-send`（脚本向应用发送文件）和 `ymodem-receive`（脚本接收应用文件）。
- `--file`：待发送文件路径。使用 `--mode ymodem-send` 时必填；在 `terminal` 模式中执行 `ysend` 时可选，未指定则发送脚本内置示例文本。
- `--output`：接收文件目录，默认是当前工作目录下的 `ymodem_rx`。用于 `ymodem-receive` 模式以及 `terminal` 模式中的 `yrecv` 命令。
- `--help/-h`：显示脚本参数帮助。

<a id="sec-text"></a>

## 多编码文本发送

`text_sender.py` 按指定编码和行尾持续发送文本，用于验证数据收发页的解码、换行、混合文本和串口回显。

```bash
python text_sender.py --port COM14
python text_sender.py --port COM14 --encoding GBK --mode mixed --interval 100
python text_sender.py --port COM14 --encoding Shift_JIS --mode line --line-ending lf
python text_sender.py --port COM14 --mode echo
```

参数：

- `--port/-p`：脚本连接的串口号，必填，例如 `COM14`。
- `--baud/-b`：串口波特率，默认 `115200`。
- `--encoding/-e`：文本编码，支持 `UTF-8`（默认）、`GBK`、`BIG5`、`Shift_JIS`、`EUC-KR`、`Latin-1` 和 `ASCII`。
- `--mode/-m`：发送模式，支持 `plain`（固定文本）、`line`（带行号文本）、`mixed`（多语言混排，默认）和 `echo`（回显应用发来的数据）。
- `--interval/-i`：发送间隔，单位毫秒，默认 `100`。
- `--no-line-ending`：不在发送文本后自动添加行尾；默认会添加行尾。
- `--line-ending`：自动添加的行尾类型，支持 `crlf`（默认）、`lf` 和 `cr`；启用 `--no-line-ending` 后此参数不生效。
- `--help/-h`：显示脚本参数帮助。

<a id="sec-bin"></a>

## 绘图 BIN 生成

`generate_plot_bin.py` 生成可直接在绘图页面导入的 `.bin` 文件，用于测试大数据导入、LOD 绘图和测量交互。

```bash
python generate_plot_bin.py --output E:\temp\vscope_180w_8ch.bin --packets 1800000 --channels 8
python generate_plot_bin.py -o E:\temp\step_100w_4ch.bin -n 1000000 -c 4 --mode step
python generate_plot_bin.py -o E:\temp\impulse_100w.bin -n 1000000 -c 1 --mode impulse -a 10000
python generate_plot_bin.py -o E:\temp\burst_100w.bin -n 1000000 -c 1 --mode burst -a 10000
python generate_plot_bin.py -o E:\temp\burst_shoulders_100w.bin -n 1000000 -c 1 --mode burst-shoulders -a 10000
```

参数：

- `--output/-o`：输出文件路径。
- `--packets/-n`：生成包数。
- `--channels/-c`：通道数，范围 1~16。
- `--mode/-m`：数据模式，支持 `sine`、`step`、`ramp`、`constant`、`impulse`、`burst`、`burst-shoulders`，默认 `sine`。`impulse` 仅在数据中点生成一个指定幅度的突变点；`burst` 均匀生成 5 段、每段连续 8 个指定幅度的点；`burst-shoulders` 在每段突变两侧额外生成 `100`、`500` 的过渡点；其余点均为 `0`。
- `--amplitude/-a`：生成数据的幅度，默认 `1000`。
- `--progress`：每生成多少包打印一次进度，默认 `100000`；设置为 `0` 时不打印进度。
- `--help/-h`：显示脚本参数帮助。

<a id="sec-zobow-c"></a>

## Zobow C 配置导入

`zobow_c_profile_import.dart` 调用应用内的 C 配置解析器，将 C 文件中识别到的通道地址预设输出为 JSON，适合独立验证配置导入规则。

```bash
dart run test_tools/zobow_c_profile_import.dart E:\temp\device.c
dart run test_tools/zobow_c_profile_import.dart --ignore-comments E:\temp\device.c
```

参数：

- `--ignore-comments`：忽略注释中的通道名称，输出预设时不使用注释提供的名称。
- `<file.c>`：待解析的 C 文件路径，必填且只能提供一个。

<a id="sec-updater"></a>

## Windows 更新器测试

`test_updater.py` 对已构建的原生 `vscope_updater.exe` 执行端到端冒烟测试，覆盖：

- 正常更新、旧文件清理和回退快照生成。
- `settings/` 等用户文件保留。
- payload 缺失或校验失败后的自动回滚。
- 主程序仍在运行时拒绝替换文件。

脚本使用 `build/windows/x64/runner/Debug/vscope_updater.exe`，运行前先完成 Windows Debug 构建：

```bash
flutter build windows --debug
python test_tools/test_updater.py
```

测试只在临时目录中复制和操作更新器，不修改当前开发目录中的应用文件。

<a id="sec-flow"></a>

## 建议测试流程

1. 创建虚拟串口对，例如 `COM13 <-> COM14`。
2. 启动模拟脚本，例如 `python zobow_device.py --port COM14 --interval 1`。
3. 在 VScope Serial 中选择对应解析器并连接 `COM13`。
4. 点击“开始”绘图。
5. 使用 `p`、`r`、`c` 验证暂停、复位和关闭流程。

大文件绘图测试可直接生成 BIN 后导入：

```bash
python generate_plot_bin.py -o E:\temp\big_8ch.bin -n 1800000 -c 8
```

<a id="sec-benchmark"></a>

## 绘图性能基准

`run_plot_benchmark.ps1` 用于在 Windows Profile 模式下运行绘图性能基准，采集帧耗时、内存、接收速率、有效 FPS、页面重建次数和 Painter 绘制次数。它是开发者对比工具，只适合同一台机器前后对比，不作为 CI 的耗时硬门禁。

运行快速基准：

```bash
pwsh -File test_tools/run_plot_benchmark.ps1 -Preset quick -Label baseline
pwsh -File test_tools/run_plot_benchmark.ps1 -Preset quick -Label optimized
```

运行长时间压测：

```bash
pwsh -File test_tools/run_plot_benchmark.ps1 -Preset soak -Label soak
```

`soak` 包含以下容量场景：

- `1M-16CH`：实际采集达到 1M 点后验收，精确对象不得超过 250k。
- `10M-4CH`：实际采集达到 10M 点后执行拖动/缩放，精确对象不得超过 250k，p95 帧时间不得超过 33 ms。
- `100K-16CH-SOAK`：16 通道和数学通道持续 5 分钟，验证 2 GiB 历史预算停止和 4 GiB RSS 紧急保护线。

前两个场景若在限定时间内未达到目标点数会直接失败，不再用配置范围代替实际历史量。所有容量场景同时断言峰值 RSS 低于 4 GiB，报告记录历史预算占用和视口任务是否收敛。

输出文件保存在 `build/performance/`，该目录不提交到仓库：

- `<Label>.json`：原始指标，便于脚本或后续工具分析。
- `<Label>.md`：场景汇总和对比报告。

脚本会自动传入 `PLOT_PERF_METRICS=true`，应用正式构建不会启用这些计数器。

参数：

- `-Preset`：测试场景集合，支持 `quick`（默认，快速覆盖典型负载）和 `soak`（长时间高负载测试）。
- `-Label`：报告文件名标签，默认 `optimized`；只允许字母、数字、点、下划线和连字符。

<a id="sec-p1"></a>

## P1 稳定性压测

`run_p1_stability_soak.ps1` 独立执行不进入 CI 的大输入门禁：默认分别向
FireWater/JustFloat 投入 `1 GiB` 无分隔噪声，并生成、导入约 `1 GiB` 的
16 通道 BIN。临时导入文件默认在完成后删除。

```bash
pwsh -File test_tools/run_p1_stability_soak.ps1
pwsh -File test_tools/run_p1_stability_soak.ps1 -NoiseGiB 2 -ImportGiB 2 -KeepImportFile
```

24 小时真实串口 soak 仍需虚拟串口或实体设备：使用本目录的
`zobow_device.py`/`justfloat_device.py` 持续发送，期间执行断开、重连和拔插，
结束后核对应用接收字节、原生连接周期汇总日志及系统内存曲线。
