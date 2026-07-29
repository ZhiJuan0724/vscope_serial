# SerialTools 项目上下文

> 仅记录跨版本、跨对话仍有效的项目事实和约束。
> 用户功能见 `README.md`，开发流程见 `DEVELOPMENT.md`，专项调查见 `docs/reports/`。

## 1. 项目与治理

- SerialTools 是 Flutter Windows 串口收发与数据可视化工具；仓库和可执行文件名仍为 `vscope_serial`，当前只维护 Windows。
- 主开发分支为 `dev`，发布分支为 `main`。
- 提交信息使用中文并准确描述修改；不得擅自提交、push、回滚或 force push。
- `CHANGELOG.md` 是 Release Notes 和应用内版本说明来源，只记录用户可感知的最终变化，不记录同一版本内的调试过程；涉及发布内容的提交，提交前须让用户核对对应版本段落。

## 2. 核心架构

### 2.1 分层

- `lib/core/`：日志、CRC 等底层工具；使用 `AppLogger`，不直接 `print()`。
- `lib/data/`：模型、收发协议、解析器和 LOD。接收解析器实现 `IDataParser`；高频链路优先使用 `feedBatch()`。
- `lib/services/`：串口、探针、设置、更新、通知和原生接口。连接生命周期、缓存和设置写入均由单一所有者管理。
- `lib/viewmodels/`：页面状态和业务流程；业务计算保持无 UI 依赖。
- `lib/views/`：页面、弹窗、Painter 和手势；高频状态使用 Selector 和分层 Painter 隔离重建。
- `windows/`：Windows Runner、原生串口 DLL 和更新器。
- `integration_test/`：本地 Windows Profile 性能场景，不作为 CI 耗时门禁。
- `test_tools/`：模拟设备、测试数据和性能脚本。

### 2.2 活动与连接所有权

- 数据收发、Shell 和串口绘图通过 `SerialActivityOwner` 互斥占用串口接收活动。
- 串口和探针由 `ConnectionOwnerService` 互斥管理。
- RTT Viewer 与探针绘图可共享空闲探针连接，但任一数据活动开始后必须锁定当前探针页面。
- 普通发送、Shell、粘贴和 YMODEM 共用单一有序串口写队列，禁止并发打乱字节。

### 2.3 协议边界

- 接收协议与发送协议分离。接收侧统一由 `IDataParser` 负责；发送侧实现 `SendProtocol<TConfig>`，不得把具体协议耦合进 `SerialService`。
- Zobow 地址只接受十六进制；r 协议保留十进制或 `0x` 十六进制原文。Zobow 当前只支持 4/8 通道固定帧。
- FixedFrame 通道数为 `1~16`，帧头和帧尾不能同时全为 `0`；FireWater 只处理 ASCII 数字；随机源只输出 FireWater。

## 3. 探针与 RTT 安全边界

### 3.1 最高安全约束

- RTT Viewer、RTT 绘图和 HSS 必须严格非侵入：枚举、连接、读取、写入、停止和断开均不得 halt、reset、resume、step 或改变目标执行状态；“操作后恢复运行”也不允许。
- 监控会话不得执行烧录、擦除、核心寄存器访问、断点、观察点或 Vector Catch。
- 无法证明满足约束的路径必须在接触目标前拒绝。未来编程或调试功能必须使用独立会话、独立命令和明确安全提示，并与监控活动互斥。

### 3.2 后端选择

- 后端包括自动、外部 J-Link、外置 OpenOCD、内置 OpenOCD、外置 pyOCD；下拉项不因探针类型隐藏。
- 显式选择 J-Link 时切换为 J-Link 探针；选择 OpenOCD/pyOCD 时切换为 CMSIS-DAP；自动模式才允许自由选择探针类型。
- CMSIS-DAP 自动顺序：外置 OpenOCD → 内置 OpenOCD → 外置 pyOCD。只在工具不可用或 OpenOCD 配置不完整时尝试下一项；目标连接失败、探针占用或目标错误不得静默切换。
- J-Link 停止 RTT 时终止后端并自动重建空闲连接，期间显示“停止中”和“探针重连中”；OpenOCD 停止活动后保留空闲连接。

### 3.3 pyOCD 受限 Worker

- 外置 pyOCD 使用用户指定、可 `import pyocd` 的 Python，当前仅接受 pyOCD `0.45.x`；应用不内置 Python/pyOCD。
- Worker 位于 `assets/runtime/pyocd_worker.py`，使用版本化帧协议和固定 `nonIntrusiveMonitor` 配置。
- Worker 只允许打开 CMSIS-DAP、连接 DP、建立 AP0 MEM-AP，并访问 RTT 控制块、Up、Down 0 和用户配置的 HSS 地址。
- 禁止调用完整 `Session.open/close`、`Board.init`、`Target.init/disconnect` 或 Cortex-M Core 初始化。协议可预留高权限配置名，但当前不得实现或复用。
- CMSIS-DAP 支持自动、仅 v1、仅 v2；显式模式必须直接调用对应 USB 后端。用户刷新设备时可轻量读取 USB 名称和 VID/PID，再定向连接。

### 3.4 RTT/HSS 数据活动

- 探针连接与数据活动分离。RTT 控制块定位在 RTT Viewer 或探针绘图各自的数据配置中设置，未连接时也可编辑。
- 定位支持 Auto、指定地址和指定范围；OpenOCD 不提供 Auto。扫描失败必须明确提示，不得忽略参数。
- RTT Viewer 与探针绘图分别保存 `1~1000 ms` 轮询间隔，默认 `10 ms`；从哪一侧启动就只使用该侧配置。
- 外部工具进程状态与活动数据 Socket 独立；主动关闭 Socket 不得被判定为探针断开。
- 实时 RTT 数据不写普通日志。待处理队列上限 `64 MiB`，每帧最多消费 `64 KiB`；过载丢弃最旧完整块并重置流式解码状态。
- HSS 通过 OpenOCD Tcl RPC 或受限 pyOCD MEM-AP 运行态读取，不是 SEGGER HSS SDK。
- RTT 从控制块枚举 Up 通道；`JScope_<FORMAT>` 自动解析格式，普通名称允许手动设置。ELF/AXF/OUT 由主应用解析，不依赖后端。

## 4. 串口生命周期与原生安全

- 串口打开、检查、重连、断开和退出共用同一异步操作队列；每次连接有独立 generation，失效会话不得更新当前状态或投递数据。
- `SerialService.shutdown()` 是唯一应用退出入口，必须等待连接生命周期收敛。任何两个原生 open/close 生命周期不得交叉。
- Windows 串口打开在后台 isolate 中执行；串口打开、健康检查和枚举由 `native_serial_reader.dll` 完成。
- 默认枚举只读取 COM 号。只有用户显式开启详细信息并手动刷新时，才在后台读取设备名称；自动刷新、插拔和自动连接不得扫描 USB 元数据或阻塞 UI。
- 串口列表使用缓存和设备到达/移除通知；枚举失败不得清除已保存端口和参数。
- 部分电脑曾在串口连接原生边界直接退出。应用须在 `WidgetsFlutterBinding.ensureInitialized()` 后、日志和串口发现前调用只读 `nsr_is_open` 预热；该调用不得枚举、打开或修改串口。根因仍是时序竞态假设，不得在缺少同机二分或转储时归因到单一提交。证据见 `docs/reports/SERIAL_CONNECTION_CRASH_INVESTIGATION.md`。

## 5. 数据、绘图与资源约束

### 5.1 原始数据与 Shell

- 原始显示缓存与完整字节记录分离。完整记录上限 `512 MiB`，80% 预警，满后停止原始接收并保留数据；清空后可继续。
- 显示行数范围 `100~100000`，默认 `100000`；减少上限只按 FIFO 清理显示，不影响容量内导出。
- 文本导出按当前编码重新解析完整记录；多字节编码必须使用有状态流式解码。
- Shell 使用独立终端缓冲和流式解码，不经过普通收发行格式化；YMODEM 数据不得写入终端显示。
- Shell 每帧最多消费 `64 KiB`；YMODEM 期间禁止普通发送，取消时发送 CAN 并释放状态。

### 5.2 绘图会话与历史

- 绘图启动使用共享 Future 的 single-flight 和 generation 隔离；停止、重启或销毁必须取消启动意图并释放 parser、数据源、订阅和活动所有权。
- “保持绘图”只允许相同协议且通道数一致的实时数据续接；协议变化、自动识别通道数变化或文件导入历史必须先清空。
- 绘图历史按实际通道数分块；CSV/BIN 导入导出必须流式处理并显示进度，禁止构造完整文件副本。
- 串口绘图历史预算为 `1~8 GiB`，默认 `2 GiB`；80% 预警，预计下一完整点超限时拒绝并停止采集，保留历史和导出能力。
- 探针绘图使用独立 ViewModel、数据链路和预算设置；预计下一点超限时停止采集并保留图像。

### 5.3 LOD 与渲染

- `PlotLodSource` 是普通/数学通道 LOD 的 Painter 查询边界；LOD 只存内存，不改变原始数据和导出结果。
- 串口绘图最大可见范围 `1M~10M`、默认 `1M`；精确窗口最多 `250k` 点，进入缓存边缘 20% 时预取。
- 精确窗口重建使用 generation 可取消的分块任务，每 4096 点内让出 UI；完成前继续显示 LOD。
- 大范围质量分为性能、均衡和质量优先；质量优先使用趋势线和桶内 min/max 包络，避免孤立突变形成跨桶三角形。
- 数据刷新不得重建工具栏、发送区或通道面板；光标只更新交互层。新增绘图状态必须归入正确 revision。
- offset 和 scale 是运行时视图状态，不写入设置或通道配置。

## 6. 设置、界面与诊断

### 6.1 设置持久化

- 主设置位于 `<exe_dir>/settings/settings.json`，使用带 `schemaVersion` 的嵌套 JSON：根节点按全局和功能分组，功能内按连接、性能、外观、交互等分组。
- 运行时字段通过集中路径表映射；新增字段必须有默认值和路径。旧单层格式读取成功后自动重写，不单独维护迁移脚本。
- 设置文件不加密，不得保存敏感数据。“恢复默认设置”只重置主设置，不删除协议配置文件。

### 6.2 UI 规则

- 固定 UI 文本优先放入 `lib/core/localization/app_strings.dart`。
- 应用窗口最小宽度 `800px`；不得用布局溢出代替尺寸约束。
- 工具栏、设置导航和底部按钮使用统一组件。紧凑按钮必须显式约束尺寸、点击区和悬停效果，禁止使用产生大范围圆形阴影的默认样式。
- Flutter build 阶段不得直接修改 ViewModel；使用临时渲染状态或在事件阶段更新。
- Windows 当前以根级 `ExcludeSemantics` 规避 Flutter semantics 日志洪泛；升级 Flutter 后重新验证。

### 6.3 日志与崩溃转储

- 调试模式默认关闭；开启后记录 TRACE/DEBUG 并同步刷盘。高频数据只允许限频统计，不逐条写日志。
- Windows Runner 在 Flutter 初始化前安装异常回调，默认将原生崩溃的小型 minidump 和 JSON 元数据写入 `<exe_dir>/crash_dumps/`，最多保留 10 份。
- Debug 构建可提供二次确认的真实崩溃测试；Release 必须隐藏入口且 DLL 不导出测试函数。
- 发布包排除 PDB，但每个版本必须单独归档匹配符号。`tools/analyze_crash_dump.ps1` 兼容 Windows PowerShell 5.1 和 PowerShell 7。

## 7. 发布与更新

- 版本来自 `pubspec.yaml`；稳定 tag 为 `vX.Y.Z`，Beta 为 `vX.Y.Z-beta.N`，必须与版本号一致。
- GitHub Actions 或 `tools/build_release.py` 必须注入 `BUILD_TIME`。
- Release 同时提供 Windows ZIP 和更新清单；客户端校验大小与 SHA-256。
- 更新优先 GitHub，失败后按同一通道尝试 Gitee；自动检查只提示，用户确认后才安装。
- `vscope_updater.exe` 在主程序安全退出后更新，保留 `settings/`、`config/`、`logs/`、`exports/` 和未知用户文件，失败自动回滚。
- 稳定版和 Beta 各保留一个本地回退槽；按当前运行版本的通道写入，不按目标版本通道写入。
- 本地和 CI 打包前必须清空旧发布目录与 Windows 构建树；禁止复用增量产物。发布包排除 `.lib`、`.exp`、`.pdb` 等中间文件，并包含所需许可证。
- `.github/workflows/windows-release.yml` 负责 PR 检查、手动构建和 tag 发布。PR 到 `main` 运行 analyze、test 和 Windows Release 构建；直接 push `main` 不发布。

## 8. 开发规则

- 代码和文档读写使用 PowerShell 7：`pwsh -NoLogo -NoProfile`；不要依据 Windows PowerShell 5.1 的中文输出判断文件内容。
- 常规提交前至少执行格式化、`flutter analyze` 和 `flutter test`；发布前验证 Windows Release 构建。
- 明确的后台 Future 使用 `unawaited()`；资源所有者在 stop/dispose 中关闭订阅和 sink。
- 提交前检查 `git status`，只暂存任务相关文件，不覆盖用户已有改动。
- 性能基准使用 `pwsh -File test_tools/run_plot_benchmark.ps1 -Preset quick -Label <名称>`；结果只用于同机对比。
