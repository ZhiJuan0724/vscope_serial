# 测试工具

`test_tools/` 用于模拟下位机设备和生成绘图测试文件，配合 VScope Serial 验证协议解析、串口收发和大数据绘图性能。

## 环境要求

```bash
pip install pyserial
```

Windows 下可以使用 com0com 或 Virtual Serial Port Driver 创建虚拟串口对。例如创建 `COM13 <-> COM14`，VScope Serial 连接 `COM13`，测试脚本连接 `COM14`。

## 控制按键

`zobow_device.py` 和 `justfloat_device.py` 运行时支持单键控制，Windows 下直接按键即可，无需回车：

- `p`：暂停/恢复发送。
- `r`：复位到等待接收配置/读取命令状态。
- `c`：关闭脚本。

## Zobow 协议模拟

`zobow_device.py` 模拟 Zobow 设备：

- 接收配置帧。
- 按配置输出 4 或 8 通道数据帧。
- 数据帧使用 CRC16/MODBUS。

```bash
python zobow_device.py --port COM14
python zobow_device.py --port COM14 --baud 115200 --mode sine --interval 1
python zobow_device.py --port COM14 --mode random --interval 10
python zobow_device.py --help
```

数据模式：

- `sine`：正弦波，默认模式。
- `random`：随机数据。
- `ramp`：递增斜坡。
- `fixed`：固定递增。

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

## 绘图 BIN 生成

`generate_plot_bin.py` 生成可直接在绘图页面导入的 `.bin` 文件，用于测试大数据导入、LOD 绘图和测量交互。

```bash
python generate_plot_bin.py --output E:\temp\vscope_180w_8ch.bin --packets 1800000 --channels 8
python generate_plot_bin.py -o E:\temp\step_100w_4ch.bin -n 1000000 -c 4 --mode step
```

常用参数：

- `--output/-o`：输出文件路径。
- `--packets/-n`：生成包数。
- `--channels/-c`：通道数，范围 1~16。
- `--mode/-m`：数据模式，支持 `sine`、`step`、`ramp`、`constant`。

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
