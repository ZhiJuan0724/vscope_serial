# SerialTools 项目上下文

> 本文件只记录长期有效的项目事实和开发约束，避免把每次小改动都堆进来。
> `README.md` 面向用户，`DEVELOPMENT.md` 面向开发者，本文件是项目长期事实和架构约束的权威记录。
> 提交信息使用中文，说明本次修改的具体任务；涉及 force push 必须先让用户确认。
> `CHANGELOG.md` 是 Release Notes 和应用内版本说明来源；涉及发布内容的提交，提交前必须让用户核对对应版本段落，且只记录用户可感知变化。

## 项目定位

SerialTools（仓库和可执行文件仍使用 `vscope_serial`）是一个 Flutter Windows 串口数据收发与可视化工具，核心目标是稳定收发串口数据、按多种协议解析，并在百万级数据量下保持波形绘制和交互流畅。

当前只维护 Windows 桌面目标。仓库主开发分支为 `dev`，发布分支为 `main`。

## 当前能力

- 串口连接、配置、状态检测、原始收发显示和导出；连接窗口默认只枚举 COM 号，用户可按需开启设备详细信息。
- 原始数据接收区支持跨行选择复制、自动滚动和可配置显示行数，默认保留 100000 行；非 HEX 模式下可选择 UTF-8、GBK、BIG5、Shift_JIS、EUC-KR 等文本编码，普通文本发送和原始接收解码共用数据收发页的编码设置。
- 原始数据的界面显示缓存与完整字节记录分离；完整字节记录固定上限为 `512 MiB`，80% 首次预警、100% 停止原始接收并保留已有数据，清空后重新允许接收；文本导出会按当前编码重新解析容量范围内的完整数据，文本和 BIN 均由用户选择目录并显示进度。
- 文本模式单行超过 4096 字符时自动强制换行，避免长时间等不到换行符导致界面卡死。
- 数据收发页支持可收起的多条发送扩展面板；配置按 JSON 独立保存到 `<exe_dir>/config/multi_send/`，条目支持文本/HEX、独立行尾、发送后间隔、排序、单条发送、执行一轮、持续循环和配置导入导出。
- Shell 已从数据收发页拆分为独立页面；入口默认隐藏，由应用高级设置控制。Shell 使用 `xterm` 终端组件，保留命令行和逐键两种输入模式，不提供 HEX 输入或 HEX 输出。
- Shell 使用独立的编码、命令行行尾、本地回显、滚动历史和外观设置；支持 ANSI 终端、命令历史、终端文本导出和 YMODEM 文件发送/接收，接收文件默认保存到 `<exe_dir>/exports/ymodem/`。
- UTF-8、GBK、BIG5、Shift_JIS、EUC-KR 等 Shell 文本编码使用有状态流式解码器，必须正确处理多字节字符跨串口数据块的情况。
- 数据收发、Shell 和绘图通过 `SerialActivityOwner` 互斥占用串口接收活动；任一页面开始实际接收后锁定当前页面，停止、启动失败或串口断开后释放页面切换。
- 普通发送、Shell 命令、逐键输入、粘贴和 YMODEM 共用单一有序串口写入队列；同步 FFI 写入在后台 isolate 中执行，不允许不同入口并发打乱字节顺序。
- 实时绘图、历史窗口回看、CSV/BIN 导入导出，以及旧版虚拟示波器 DAT 导入；绘图运行期间禁止导入和导出。
- 接收协议支持 FireWater、固定帧、Zobow、JustFloat。
- 发送协议与接收协议分离；内置发送协议为“无”和 `r协议`，Zobow 接收协议固定使用内置二进制初始化帧。
- 地址配置文件使用共同 JSON 结构和编辑界面，但协议地址规则独立：Zobow 固定按十六进制数值处理；r 协议保留十进制或带 `0x` 前缀的十六进制文本格式。配置支持 JSON/CSV 导入导出，Zobow 还支持 C 代码识别。
- 绘图运行时锁定接收协议、发送协议、协议设置、地址预设、通道地址、随机源开关和数据导入导出；停止后才允许修改，通道名称和随机源频率不受限制。
- “保持绘图”只允许相同接收协议且通道数一致的数据流续接历史；接收协议改变、自动识别通道数在新流首包发生变化或历史来自文件导入时，必须在追加前清空旧历史，即使数据使用相同存储结构也不能复用。
- 绘图启动是共享 `_startFuture` 的 single-flight，会话使用 generation 隔离；启动中停止、重启或销毁必须取消启动意图，等待已开始步骤收敛，并释放 parser、数据源、订阅和串口活动所有权。每个 session 的协议初始化和解析订阅只能创建一次。
- 最多支持 16 个普通通道和 4 个数学通道；数学表达式支持四则运算、`abs()` 和 `CHn[偏移]`，无效结果沿用空心点逻辑。
- 通道支持名称、显示、亮色/暗色预设颜色、偏置、缩放、线宽和点半径；偏置通道可建立多组绑定，共用 Y 轴、偏置位置和缩放倍率。
- 绘图支持亮色/暗色背景、实时值、图例、X-X、Y-Y、统计范围、观察线、点击定位观察、跟随光标和吸附高亮。
- 大数据绘图使用内存级 LOD 索引；持久化键 `maxVisiblePoints` 的语义是“最大可见范围”，用户范围为 `1M~10M`、默认 `1M`，旧值超过 10M 时迁移并写回 10M。精确对象窗口固定上限为 `250k`，更大视口由 Painter 直接使用普通或数学通道 LOD，缩放到局部后恢复精确值。大范围绘图质量分为性能优先、均衡和质量优先三档，后两档分别选择更细一级和两级的 LOD；接收速率超过 10000 包/s 时会进入高频模式，运行时刷新强制 30fps，并按实测速率降低 LOD 更新频率。
- 局部视口按中心预取最多 `250k` 精确点，进入缓存边缘 20% 时提前换窗。定位条连续拖动时使用有界粗略 LOD 预览，停顿 `120ms` 或松手后再加载精确块。
- 绘图历史使用保守投影内存预算：单份历史上限可配置为 `1~8 GiB`、默认 `2 GiB`，80% 首次预警，预计下一完整点超过预算时拒绝该点并异步停止绘图；应用进程 RSS 紧急保护线统计 Flutter 引擎和全部功能的进程占用，不低于 `4 GiB` 并随历史上限提高，仅在绘图追加数据时定期检查。容量停止后保留历史和导出能力，串口保持连接；提高上限后可在新预算内继续，否则需先清空历史。CSV/BIN/DAT 导入也必须经过相同预算检查。
- 绘图底部状态栏显示实际渲染 FPS；可选“定位条”只映射完整 X 数据范围和当前视口，用于快速跳转，不绘制全量通道曲线。
- 窗口右下角的应用信息和应用高级设置是两个独立入口；应用信息页显示版本、构建时间、版本说明、更新通道/来源和更新操作，应用高级设置负责页面入口、提示、内存占用与上限总览、默认设置和稳定版/Beta 本地回退等全局选项。内存总览中的绘图历史预算可修改，其余固定保护限制只读；未使用的缓存或队列显示为 `0 B`。
- 三个页面的工具栏、开始按钮、设置导航和底部操作按钮使用统一组件与视觉规则；设置弹窗采用左侧紧凑分类导航、右侧连续内容布局。
- 测试工具可模拟 Zobow、JustFloat、Shell/YMODEM 和多编码文本设备，也可生成绘图 BIN 数据并运行 Windows Profile 性能基准。

## 模块边界

- `lib/core/`：日志、CRC 等底层工具。底层模块优先使用 `AppLogger`，不要直接 `print()`。
- `lib/core/localization/app_strings.dart`：主要固定 UI 文本统一管理入口，包括按钮、工具提示、设置项名称/说明和弹窗文案；新增固定文本优先放入对应分组，避免散落在页面或弹窗实现中。
- `lib/data/`：数据模型、接收解析器、发送协议、数据源和 LOD 索引。接收解析器统一实现 `IDataParser`，兼容 `feed()`/`outputStream`；绘图高频接收链优先使用 `feedBatch()` 批量返回结果，避免逐包 Stream 调度。
- `lib/services/`：串口服务、设置持久化、应用信息、更新检查、通知和原生读取封装。`SerialService` 是 UI 门面，连接生命周期由 `SerialConnectionCoordinator` 独占，原始接收缓存由 `RawReceiveSession` 独占；`SettingsRepository` 独占设置 JSON、备份恢复和串行原子写入。
- `lib/viewmodels/`：页面状态和业务流程。`PlotViewModel` 是全局 Provider，页面切换不丢绘图状态；绘图历史、精确窗口和数据源会话分别由 `PlotHistoryStore`、`PlotWindowProvider`、`PlotSessionController` 独占，通道、显示、视口和交互控制拆分在 `plot_viewmodel/` 的独立 `part` 模块中，数学/触发/统计/观察值计算保持无 UI 依赖；`ShellViewModel` 独立管理 Shell 会话、输入、接收调度和文件传输。
- 发送协议统一实现 `SendProtocol<TConfig>`，并且每个具体协议使用独立文件；`ZobowDeviceProtocolCodec` 和 `RProtocolCodec` 分别编码 ZobowDevice 初始化帧和 r 命令。`PlotProtocolInitializer` 负责绘图启动前的协议发送和错误归一化；`PlotViewModel` 只提供配置快照并处理启动结果，`SerialService` 不得依赖具体发送协议。接收侧始终由 `IDataParser` 实现负责，不能与发送协议合并。
- `lib/views/`：页面、弹窗、绘图 Painter 和手势处理。绘图页使用 Selector 隔离工具栏、通道面板、绘图区和状态栏的重建；页面只构造一个 `PlotRenderSnapshot`，`PlotLayerStack` 按背景网格、数据、坐标轴、交互覆盖四层 Painter 绘制。
- `integration_test/`：Windows Profile 模式的绘图性能场景，不作为 CI 耗时门禁。
- `test_tools/`：本地模拟设备和测试数据生成脚本。
- `windows/`：Flutter Windows runner、原生串口读取 DLL 和外置更新器。

## 关键约束

- 设置持久化到 `<exe_dir>/settings/settings.json`。新增字段必须有默认值兼容旧配置，不做单独迁移脚本。
- 设置文件不加密，不要存放敏感数据。
- 应用信息高级设置的“恢复默认设置”只重置 `<exe_dir>/settings/settings.json` 中的应用设置，不删除 Zobow/r 协议等绘图配置功能保存的 JSON 配置文件。
- 串口打开、健康检查、清理、重连、断开和应用退出必须经过同一异步操作队列；每次连接使用独立 generation，断开或退出立即使正在打开的 generation 失效，旧打开结果和旧数据回调不得成为当前连接或向新会话投递数据。
- `SerialService.shutdown()` 是应用退出专用入口；无论当前处于 connected 还是 connecting，都必须等待连接生命周期安全收敛后再关闭窗口。原生 DLL 可继续使用进程级句柄，但任何两个 open/close 生命周期不得交叉。
- 应用窗口最小宽度为 `800px`；扩展多条发送面板时仍需保持主收发区和扩展区的最低可用宽度，禁止通过布局溢出来代替窗口尺寸约束。
- Windows 原生串口打开在后台 isolate 执行，避免 `CreateFile` 阻塞 UI。
- Windows 串口打开、连接健康检查和端口枚举均由 `native_serial_reader.dll` 负责并在 UI isolate 外执行。默认端口枚举只读取 COM 号；仅当用户在连接窗口主动开启“显示详细信息”并手动刷新时，才允许通过 SetupAPI 在后台读取友好名称。自动刷新、设备插拔和自动连接不得读取名称，也不得为获取 USB 元数据而打开串口、遍历 USB Hub 或阻塞 Flutter UI。
- 串口列表使用内存缓存并监听 Windows 设备到达/移除通知；健康连接和历史端口自动连接不依赖枚举，枚举失败或超时不得清除用户保存的端口及串口参数。
- 原始数据显示行数默认 `100000`，可配置范围为 `100~100000`；降低上限会按 FIFO 移除最早显示内容，容量范围内的完整原始字节导出不受影响。原始字节达到 `512 MiB` 后停止原始接收但不滚动丢弃、不自动断开串口；YMODEM 文件仍需完整接收，只停止向原始追踪追加。原始数据为空时禁止导出；文本和 BIN 导出均由用户选择目标文件夹。
- 接收区自动滚动开启时必须保持在最新行，关闭后不得改变用户滚动位置。
- Shell 接收字节由独立会话控制器写入终端缓冲，不经过普通收发文本行格式化；每帧最多消费 `64 KiB`，滚动和重绘每帧最多安排一次，未消费数据必须留在队列中而不是丢弃。YMODEM 传输期间不把二进制传输内容写入终端显示。
- Shell 终端字体独立于应用 UI 字体，默认 `Consolas`；用户只能从 Shell 设置提供的常见系统等宽字体列表中选择。
- Shell 逐键模式下 `Ctrl+C` 发送 ETX (`0x03`) 给串口设备；复制使用 `Ctrl+Shift+C` 或选中文本后右键复制，避免和终端控制字符冲突。
- Shell 文件传输入口位于“更多功能”二级菜单；文件发送/接收弹窗内选择方向、协议和发送长度，并显示传输进度与取消按钮，便于后续扩展其它 Modem 协议。
- YMODEM 传输走统一串口写入口，传输期间禁止普通手动发送和逐键发送；取消传输需要发送 CAN 并释放 UI 状态。
- `PlotLodSource` 是 Painter 查询普通与数学通道 LOD 的统一边界；`PlotLodIndex` 只保存在内存中，不落盘，不改变原始数据和导出结果。数学表达式必须暴露引用通道和前后偏移，以便从完整历史精确读取并构建派生 LOD。
- 绘图历史按实际通道数分块存储，LOD 只为实际采样到的桶分配内存；CSV/BIN 导出必须分块写盘并报告进度，禁止构造完整文件副本。
- 精确窗口重建必须使用 generation 可取消的分块任务，最多每 4096 点让出一次 UI；任务完成前继续显示 LOD，完成后一次性交换缓存。光标从完整历史索引读取精确值，大范围统计最多均匀抽样 100k 点并明确标为近似值，Y 轴适配和数学曲线在大范围使用 LOD 摘要。
- 普通通道和数学通道的 offset、缩放倍率属于运行时视图状态，不持久化到设置或配置文件。
- Zobow 当前只支持 4/8 通道固定帧，不支持任意变长。
- FixedFrame 通道数固定为 `1~16`，不支持自动识别；帧头和帧尾不能同时全部为 `0`。
- FireWater 只面向 ASCII 数字文本。
- 随机源只输出 FireWater 格式。切换到其它解析器时保留开关状态，但不接入当前解析链，也不在底部状态栏显示随机源状态。
- 绘图区动态布局不能在 Flutter build 阶段直接修改 ViewModel 状态；需要使用临时渲染状态或在事件阶段更新。
- 绘图重绘依赖 `dataRevision`、`channelConfigRevision`、`viewportRevision` 和 `overlayRevision`；新增绘图状态时必须归入正确 revision，避免扩大重建范围或遗漏重绘。
- 数据刷新不得重建工具栏和通道面板，光标移动应只更新交互覆盖层。
- 原始收发页面的接收区和发送区使用独立 Selector；高频接收刷新不得重建发送输入区。
- 本地绘图性能基准使用 `pwsh -File test_tools/run_plot_benchmark.ps1 -Preset quick -Label <名称>`，报告输出到未跟踪的 `build/performance/`；耗时数据只用于同机对比，不作为 CI 硬门禁。
- 通道列表使用可回收列表，列表滚动时临时编辑状态可能丢失；编辑类状态要谨慎放在 item state 中。
- Flutter Windows 当前使用根级 `ExcludeSemantics` 规避 `Tooltip`/下拉控件触发的 semantics 日志洪泛；升级 Flutter 后需先验证上游问题是否修复，再决定是否恢复 Windows accessibility 语义树。

## 发布与更新

- 版本号来自 `pubspec.yaml`，应用内显示带 `v` 前缀。
- 发布构建必须通过 GitHub Actions 或 `tools/build_release.py` 注入 `BUILD_TIME`；应用信息界面的构建时间优先读取该编译期值，不能依赖 exe 文件修改时间。
- 更新检查与下载优先访问 GitHub Release，失败后按同一更新通道尝试 Gitee Release；自动检查只提示，用户确认后才下载和安装。
- Windows 自动更新由 `vscope_updater.exe` 在主程序安全退出后执行，按 `app-files.json` 覆盖受管理文件，保留 `settings/`、`config/`、`logs/`、`exports/` 和未知用户文件，失败时自动回滚。
- 自动更新下载缓存、解压 payload 和回退槽保存在 `<exe_dir>/updates/`，不写入用户目录；因此应用所在目录必须可写。
- Release 必须同时提供 `vscope_serial-windows-vX.Y.Z.zip` 和 `update-manifest-vX.Y.Z.json`，客户端使用清单中的大小和 SHA-256 校验更新包。
- 自动更新支持稳定版与 Beta 通道：稳定版 tag 使用 `vX.Y.Z`，Beta tag 使用 `vX.Y.Z-beta.N` 且 GitHub Release 必须标记为 prerelease；`pubspec.yaml` 中版本不带 `v` 且必须与 tag 去掉 `v` 后一致；Gitee Release 由 CI 同步创建，客户端按 tag 名识别稳定版或 Beta。
- 自动更新安装前按当前运行版本所属通道保存本地回退槽，与目标版本通道无关；当前为稳定版时覆盖稳定版槽，当前为 Beta 时覆盖 Beta 槽，两类各保留 1 个可手动回退版本。
- `.github/workflows/windows-release.yml` 负责 PR 检查、手动构建和 tag 发布。
- PR 到 `main` 会运行 `flutter analyze`、`flutter test` 和 Windows Release 构建。
- `v*` tag 会测试、构建、压缩发布包并创建 GitHub Release，随后同步创建 Gitee Release 并上传同一批附件。
- `main` 直接 push 不触发 release workflow，避免合并后和 tag 发布重复执行。

## 开发入口

- 开发环境、依赖、目录结构、构建、测试、发布流程和完整工程约束统一维护在 `DEVELOPMENT.md`。
- 测试工具的用途、全部参数和虚拟串口流程统一维护在 `test_tools/README.md`。
- 常规提交前至少执行格式化、`flutter analyze` 和 `flutter test`；发布前还需验证 Windows Release 构建。
- 静态检查额外启用 `unawaited_futures`、`close_sinks` 和 `cancel_subscriptions`；明确的后台 Future 必须使用 `unawaited()`，资源所有者必须在 stop/dispose 中关闭订阅和 sink。

## Windows Shell 与编码

- 本机已安装 PowerShell 7 (`pwsh`)，默认 UTF-8 读取中文正常。涉及代码或文档读写时使用 `pwsh -NoLogo -NoProfile -Command "..."`。
- Windows PowerShell 5.1 直接读写代码或文档可能因控制台编码导致中文输出乱码或写入风险，不要仅凭其输出判断源码或文档内容。
- 如果必须使用 Windows PowerShell 5.1，先显式设置 UTF-8 编码；否则优先切换到 `pwsh`。

## Git 规则

- 不要回滚用户已有改动，除非用户明确要求。
- 提交前确认 `git status`，只暂存本次任务相关文件。
- 涉及发布内容时，提交前让用户核对 `CHANGELOG.md` 对应版本段落。
- 涉及 force push 时，必须先让用户确认具体目标分支或 tag。
