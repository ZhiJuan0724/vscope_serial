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

### 众邦电控协议 (`jack_four_channel_device.py`)

模拟 众邦电控设备：
- 接收 10 字节配置帧（4 通道号 + CRC16）
- 周期性发送 10 字节数据帧（4 通道数据 + CRC16）

```bash
# 基本用法
python jack_four_channel_device.py --port COM14

# 指定波特率和数据模式
python jack_four_channel_device.py --port COM14 --baud 115200 --mode sine --interval 50

# 随机数据模式
python jack_four_channel_device.py --port COM14 --mode random --interval 100

# 查看帮助
python jack_four_channel_device.py --help
```

**数据模式说明：**
- `sine`（默认）: 正弦波，4通道不同相位
- `random`: 随机数据
- `ramp`: 锯齿波
- `fixed`: 固定递增

### 测试流程

1. 创建虚拟串口对（如 COM13 <-> COM14）
2. 启动测试脚本：`python jack_four_channel_device.py --port COM14`
3. 在 vscope_serial 中：
   - 选择解析器："众邦电控"
   - 配置通道号（默认 0x0001~0x0004）
   - 连接串口 COM13
   - 点击"开始"
4. 观察数据是否正常解析和显示

## 预留接口

后续可添加其他协议的测试脚本：
- `firewater_device.py` - FireWater 文本协议
- `fixed_frame_device.py` - 固定帧头协议
