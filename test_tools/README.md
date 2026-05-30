# 测试工具

用于模拟下位机设备，配合 vscope_serial 进行协议测试。

## 环境要求

```bash
pip install pyserial
```

## 虚拟串口

Windows 下可使用以下工具创建虚拟串口对：
- **com0com**（开源免费）: https://sourceforge.net/projects/com0com/
- **Virtual Serial Port Driver**（商业软件）

创建一对虚拟串口（如 COM13 <-> COM14），vscope_serial 连接 COM13，测试脚本连接 COM14。

## 测试脚本

脚本运行时支持控制台按键命令（Windows 下直接按键生效，无需回车）：
- `p`：暂停/恢复发送
- `r`：复位到等待接收配置/读取命令状态
- `c`：关闭脚本

### 众邦电控协议 (`zobow_device.py`)

模拟 众邦电控设备：
- 接收 18 字节配置帧（4 个 uint32 通道号，低位先发 + CRC16）
- 周期性发送 10 字节数据帧（4 通道数据 + CRC16）

```bash
# 基本用法
python zobow_device.py --port COM14

# 指定波特率和数据模式
python zobow_device.py --port COM14 --baud 115200 --mode sine --interval 50

# 随机数据模式
python zobow_device.py --port COM14 --mode random --interval 100

# 查看帮助
python zobow_device.py --help
```

**数据模式说明：**
- `sine`（默认）: 正弦波，4通道不同相位
- `random`: 随机数据
- `ramp`: 锯齿波
- `fixed`: 固定递增

### 测试流程

1. 创建虚拟串口对（如 COM13 <-> COM14）
2. 启动测试脚本：`python zobow_device.py --port COM14`
3. 在 vscope_serial 中：
   - 选择解析器："众邦电控"
   - 配置通道号（默认 0x00000001~0x00000004）
   - 连接串口 COM13
   - 点击"开始"
4. 观察数据是否正常解析和显示

## 预留接口

后续可添加其他协议的测试脚本：
- `firewater_device.py` - FireWater 文本协议
- `fixed_frame_device.py` - 固定帧头协议

### JustFloat 协议 (`justfloat_device.py`)

模拟 VOFA JustFloat 设备：
- 接收文本命令：`r [通道1地址] [通道2地址] ...\n`
- 按命令中的地址数量自动识别通道数，最大 16 通道
- 周期性发送小端 float32 数组 + 帧尾 `00 00 80 7F`

```bash
python justfloat_device.py --port COM14
python justfloat_device.py --port COM14 --mode sine --interval 1
```

### 绘图 BIN 生成 (`generate_plot_bin.py`)

生成可直接在绘图界面导入的 `.bin` 测试文件：

```bash
python generate_plot_bin.py --output E:\temp\vscope_180w_8ch.bin --packets 1800000 --channels 8
python generate_plot_bin.py -o E:\temp\step_100w_4ch.bin -n 1000000 -c 4 --mode step
```

参数：
- `--packets/-n`：生成包数
- `--channels/-c`：通道数，1~16
- `--mode/-m`：`sine`、`step`、`ramp`、`constant`
