# VScope Serial 图标风格指南

> 目标：记录当前应用内图标使用现状，并为后续统一重绘 SVG 图标提供规范、命名和验收标准。
> 当前项目几乎没有独立图片资源，现有图标主要来自 Flutter Material `Icons.*` 字体图标。本文中的“现有预览”使用 Material Symbols 在线 SVG 作为参考，不代表项目内已有 SVG 文件。

## 重绘目标

- 使用本地 SVG 作为应用统一图标源，避免依赖 Material 字体图标表达专业绘图/串口/终端语义不足的问题。
- 保留常见通用动作图标的熟悉感，如保存、设置、更多、播放、停止、搜索。
- 对绘图专用动作重绘专属图标，尤其是 X-X、Y-Y、X 轴缩放、Y 轴缩放、X/Y 自适应、统计范围等。
- 图标在 16、18、20、24 px 下都必须清晰，不出现糊边、笔画粘连或语义不可辨认。
- 图标默认不依赖文字也能表达主要含义；但复杂专业动作允许和短标签共同使用。

## SVG 技术规范

- 文件格式：纯 SVG，优先使用 `path`、`line`、`polyline`、`rect`、`circle`，不嵌入位图。
- 画布：统一 `viewBox="0 0 24 24"`。
- 默认尺寸：
  - 紧凑工具栏：18 px。
  - 普通工具栏：20 px。
  - 弹窗标题、空状态：24 px 或 48 px。
- 笔画：
  - 线性图标默认 `stroke-width="1.6"`，优先保证 16、18、20 px 工具栏尺寸下不粘连。
  - 16 px 使用场景可以允许 `stroke-width="1.4~1.6"`，但导出文件仍保持 24 viewBox。
  - 使用 `stroke-linecap="round"` 和 `stroke-linejoin="round"`。
- 颜色：
  - SVG 默认使用 `currentColor`。
  - 不在 SVG 内写死主题色；选中、禁用、警告等状态由 Flutter 侧传色。
  - 多色图标只用于通道颜色、状态类图标，且必须有单色降级方案。
- 对齐：
  - 主体应落在 3~21 的安全区域内。
  - 重要直线尽量落在整数或 `.5` 坐标，避免小尺寸渲染发虚。
  - 图标视觉中心要居中，不以数学包围盒为唯一依据。
- 可访问性：
  - SVG 文件本身不写业务文案；按钮 tooltip 继续由 Flutter 侧提供。
  - 同一语义只能有一个标准图标，避免同功能多套形状。

## 文件命名建议

后续建议放在：

```text
assets/icons/
```

命名规则：

```text
ic_<domain>_<action>.svg
```

示例：

```text
ic_raw_shell.svg
ic_raw_receive_start.svg
ic_plot_measure_xx.svg
ic_plot_measure_yy.svg
ic_plot_zoom_x_in.svg
ic_plot_zoom_y_out.svg
ic_plot_fit_all.svg
ic_update_rollback.svg
```

领域前缀建议：

- `ic_nav_*`：主导航。
- `ic_raw_*`：数据收发和 Shell。
- `ic_plot_*`：绘图。
- `ic_channel_*`：通道列表和通道配置。
- `ic_profile_*`：配置文件、地址表、导入导出。
- `ic_update_*`：版本更新、回退。
- `ic_common_*`：通用动作。

## 当前图标来源概览

| 类型 | 当前来源 | 现状 | 迁移建议 |
| --- | --- | --- | --- |
| 主导航 | `Icons.terminal`、`Icons.show_chart`、`Icons.settings_ethernet` | Material 图标语义基本可用，但和应用专业感不强 | 重绘为串口终端、波形图、协议连接三枚同风格 SVG |
| 数据收发 | `Icons.play_arrow`、`Icons.stop`、`Icons.clear`、`Icons.save`、`Icons.settings`、`Icons.more_vert` | 通用图标较清晰 | 可保留语义，重绘为统一线性 SVG |
| Shell | `Icons.keyboard_return`、`Icons.keyboard`、`Icons.folder_open`、`Icons.upload_file`、`Icons.download` | 大多可理解，文件传输还需要支持未来协议扩展 | 文件传输入口改为“更多功能/传输”专用图标 |
| 绘图测量 | `Icons.vertical_align_center`、`Icons.horizontal_rule`、`Icons.analytics`、`Icons.straighten` | X-X、Y-Y、X/Y 自适应语义弱，是优先重绘对象 | 设计带坐标轴、双游标、双向箭头的专用 SVG |
| 绘图缩放 | `Icons.zoom_in`、`Icons.zoom_out`、`Icons.vertical_align_top/bottom`、`Icons.crop_free` | X/Y 轴缩放语义混乱，Y 缩放尤其不直观 | 设计 X/Y 轴方向明确的缩放图标 |
| 文件导入导出 | `Icons.file_open`、`Icons.save`、`Icons.file_upload_outlined` | 导入图标容易像导出，保存和导出也可能混淆 | 导入使用“文件 + 向内箭头”，导出使用“文件 + 向外箭头” |
| 通道配置 | `Icons.settings`、`Icons.palette_outlined`、`Icons.check` | 可用但密度高，小尺寸需要更清晰 | 重绘轻量设置、颜色、勾选图标 |
| 更新界面 | `Icons.update`、`Icons.download`、`Icons.restore`、`Icons.open_in_new` | 语义基本准确 | 可作为低优先级统一重绘 |

## 本轮 SVG 绘制对照

> 本表用于重绘期间实时对比。当前只绘制 P0，左侧为当前 Flutter Material `Icons.*` 参考，中间为 `assets/cc_icons` 参考，右侧为本轮新增的本地 SVG。

### P0 已绘制

| 功能 | 当前图标 | 现有预览 | cc_icons 参考 | 新 SVG | 新预览 |
| --- | --- | --- | --- | --- | --- |
| X-X 测量 | `Icons.vertical_align_center` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/vertical_align_center/default/24px.svg" width="20" alt="vertical_align_center"> | <img src="../assets/cc_icons/ic_plot_measure_xx.svg" width="20" alt="cc ic_plot_measure_xx"> | `ic_plot_measure_xx.svg` | <img src="../assets/icons/ic_plot_measure_xx.svg" width="20" alt="ic_plot_measure_xx"> |
| Y-Y 测量 | `Icons.horizontal_rule` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/horizontal_rule/default/24px.svg" width="20" alt="horizontal_rule"> | <img src="../assets/cc_icons/ic_plot_measure_yy.svg" width="20" alt="cc ic_plot_measure_yy"> | `ic_plot_measure_yy.svg` | <img src="../assets/icons/ic_plot_measure_yy.svg" width="20" alt="ic_plot_measure_yy"> |
| X 轴放大 | `Icons.zoom_in` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/zoom_in/default/24px.svg" width="20" alt="zoom_in"> | <img src="../assets/cc_icons/ic_plot_zoom_x_in.svg" width="20" alt="cc ic_plot_zoom_x_in"> | `ic_plot_zoom_x_in.svg` | <img src="../assets/icons/ic_plot_zoom_x_in.svg" width="20" alt="ic_plot_zoom_x_in"> |
| X 轴缩小 | `Icons.zoom_out` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/zoom_out/default/24px.svg" width="20" alt="zoom_out"> | <img src="../assets/cc_icons/ic_plot_zoom_x_out.svg" width="20" alt="cc ic_plot_zoom_x_out"> | `ic_plot_zoom_x_out.svg` | <img src="../assets/icons/ic_plot_zoom_x_out.svg" width="20" alt="ic_plot_zoom_x_out"> |
| Y 轴放大 | `Icons.vertical_align_top` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/vertical_align_top/default/24px.svg" width="20" alt="vertical_align_top"> | <img src="../assets/cc_icons/ic_plot_zoom_y_in.svg" width="20" alt="cc ic_plot_zoom_y_in"> | `ic_plot_zoom_y_in.svg` | <img src="../assets/icons/ic_plot_zoom_y_in.svg" width="20" alt="ic_plot_zoom_y_in"> |
| Y 轴缩小 | `Icons.vertical_align_bottom` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/vertical_align_bottom/default/24px.svg" width="20" alt="vertical_align_bottom"> | <img src="../assets/cc_icons/ic_plot_zoom_y_out.svg" width="20" alt="cc ic_plot_zoom_y_out"> | `ic_plot_zoom_y_out.svg` | <img src="../assets/icons/ic_plot_zoom_y_out.svg" width="20" alt="ic_plot_zoom_y_out"> |
| X 轴自适应 | `Icons.horizontal_rule` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/horizontal_rule/default/24px.svg" width="20" alt="horizontal_rule"> | <img src="../assets/cc_icons/ic_plot_fit_x.svg" width="20" alt="cc ic_plot_fit_x"> | `ic_plot_fit_x.svg` | <img src="../assets/icons/ic_plot_fit_x.svg" width="20" alt="ic_plot_fit_x"> |
| Y 轴自适应 | `Icons.vertical_align_center` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/vertical_align_center/default/24px.svg" width="20" alt="vertical_align_center"> | <img src="../assets/cc_icons/ic_plot_fit_y.svg" width="20" alt="cc ic_plot_fit_y"> | `ic_plot_fit_y.svg` | <img src="../assets/icons/ic_plot_fit_y.svg" width="20" alt="ic_plot_fit_y"> |
| 全自适应 | `Icons.fit_screen` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/fit_screen/default/24px.svg" width="20" alt="fit_screen"> | - | `ic_plot_fit_all.svg` | <img src="../assets/icons/ic_plot_fit_all.svg" width="20" alt="ic_plot_fit_all"> |
| 导入绘图数据 | `Icons.file_open` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/file_open/default/24px.svg" width="20" alt="file_open"> | <img src="../assets/cc_icons/ic_plot_import.svg" width="20" alt="cc ic_plot_import"> | `ic_plot_import.svg` | <img src="../assets/icons/ic_plot_import.svg" width="20" alt="ic_plot_import"> |

## 优先级

### P0：必须重绘

这些图标当前语义和功能明显不匹配，或用户已经反馈不直观。

| 功能 | 当前图标 | 现有预览 | 问题 | SVG 设计目标 |
| --- | --- | --- | --- | --- |
| X-X 测量 | `Icons.vertical_align_center` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/vertical_align_center/default/24px.svg" width="20" alt="vertical_align_center"> | 像垂直居中，不像两个 X 游标测量距离 | 两条垂直游标线，中间水平双向箭头，底部可加小 `x` 轴 |
| Y-Y 测量 | `Icons.horizontal_rule` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/horizontal_rule/default/24px.svg" width="20" alt="horizontal_rule"> | 只是一条横线，不表达两个 Y 游标 | 两条水平游标线，中间垂直双向箭头，左侧可加小 `y` 轴 |
| X 轴放大 | `Icons.zoom_in` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/zoom_in/default/24px.svg" width="20" alt="zoom_in"> | 表达通用放大，无法区分 X/Y | 水平轴 + 中心放大标记 + 左右向内箭头或区间缩短 |
| X 轴缩小 | `Icons.zoom_out` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/zoom_out/default/24px.svg" width="20" alt="zoom_out"> | 表达通用缩小，无法区分 X/Y | 水平轴 + 缩小标记 + 左右向外箭头或区间拉长 |
| Y 轴放大 | `Icons.vertical_align_top` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/vertical_align_top/default/24px.svg" width="20" alt="vertical_align_top"> | 像顶部对齐，完全不像 Y 放大 | 垂直轴 + 中心放大标记 + 上下向内箭头 |
| Y 轴缩小 | `Icons.vertical_align_bottom` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/vertical_align_bottom/default/24px.svg" width="20" alt="vertical_align_bottom"> | 像底部对齐，完全不像 Y 缩小 | 垂直轴 + 缩小标记 + 上下向外箭头 |
| X 轴自适应 | `Icons.horizontal_rule` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/horizontal_rule/default/24px.svg" width="20" alt="horizontal_rule"> | 和 Y-Y 测量复用，冲突明显 | 水平轴 + 左右边界括号 + 向外适配箭头 |
| Y 轴自适应 | `Icons.vertical_align_center` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/vertical_align_center/default/24px.svg" width="20" alt="vertical_align_center"> | 和垂直光标/X-X 复用，冲突明显 | 垂直轴 + 上下边界括号 + 向外适配箭头 |
| 导入绘图数据 | `Icons.file_open` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/file_open/default/24px.svg" width="20" alt="file_open"> | 容易看成打开文件，不强调导入到图表 | 文件轮廓 + 向内箭头 + 小波形线 |

### P1：建议重绘

这些图标可理解，但和专业工具整体风格不够统一。

| 功能 | 当前图标 | 现有预览 | SVG 设计目标 |
| --- | --- | --- | --- |
| 垂直光标 | `Icons.vertical_align_center` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/vertical_align_center/default/24px.svg" width="20" alt="vertical_align_center"> | 单条垂直游标线 + 顶部/底部小抓手 |
| 添加观察 | `Icons.add_location_alt` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/add_location_alt/default/24px.svg" width="20" alt="add_location_alt"> | 波形上的观察标记 + `+` |
| 统计测量 | `Icons.analytics` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/analytics/default/24px.svg" width="20" alt="analytics"> | 小柱状/折线 + `Σ` 或 max/min 暗示 |
| 统计范围 | `Icons.straighten` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/straighten/default/24px.svg" width="20" alt="straighten"> | 两个范围边界 `S1/S2` + 选区底色 |
| 最新点跟随 | `Icons.trending_flat` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/trending_flat/default/24px.svg" width="20" alt="trending_flat"> | 波形末端点 + 跟随箭头，表示视窗追踪最新数据 |
| 图例 | `Icons.list_alt` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/list_alt/default/24px.svg" width="20" alt="list_alt"> | 多条彩色通道线 + 标签列 |
| 框选放大 | `Icons.crop_free` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/crop_free/default/24px.svg" width="20" alt="crop_free"> | 矩形框选 + 放大镜或向内聚焦角标 |
| Shell 模式 | `Icons.terminal` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/terminal/default/24px.svg" width="20" alt="terminal"> | 终端窗口 + 串口连接点 |
| 文件发送/接收 | `Icons.folder_open` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/folder_open/default/24px.svg" width="20" alt="folder_open"> | 文件 + 双向传输箭头，可扩展到 YMODEM/XMODEM |

### P2：可保留或低优先级统一

这些图标是通用动作，当前语义清楚，主要问题是风格统一。

| 功能 | 当前图标 | 现有预览 | 说明 |
| --- | --- | --- | --- |
| 开始 | `Icons.play_arrow` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/play_arrow/default/24px.svg" width="20" alt="play_arrow"> | 通用开始动作，可保留三角形语义 |
| 停止 | `Icons.stop` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/stop/default/24px.svg" width="20" alt="stop"> | 通用停止动作，可保留方块语义 |
| 清空 | `Icons.clear` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/clear/default/24px.svg" width="20" alt="clear"> | 当前用于清屏、清空数据、清除搜索，后续可按场景拆分 |
| 保存 | `Icons.save` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/save/default/24px.svg" width="20" alt="save"> | 通用保存动作 |
| 设置 | `Icons.settings` / `Icons.tune` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/settings/default/24px.svg" width="20" alt="settings"> | `settings` 偏配置，`tune` 偏高级参数；后续需要固定区分 |
| 更多 | `Icons.more_vert` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/more_vert/default/24px.svg" width="20" alt="more_vert"> | 通用更多菜单 |
| 撤回缩放 | `Icons.undo` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/undo/default/24px.svg" width="20" alt="undo"> | 语义清楚 |
| 搜索 | `Icons.search` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/search/default/24px.svg" width="20" alt="search"> | 语义清楚 |
| 信息 | `Icons.info_outline` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/info/default/24px.svg" width="20" alt="info"> | 语义清楚 |
| 警告 | `Icons.warning_amber_rounded` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/warning/default/24px.svg" width="20" alt="warning"> | 语义清楚 |

## 页面级图标清单

### 主导航

| 页面 | 当前图标 | 现有预览 | 建议 SVG |
| --- | --- | --- | --- |
| 数据收发 | `Icons.terminal` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/terminal/default/24px.svg" width="20" alt="terminal"> | `ic_nav_terminal.svg`：终端窗口 + 串口线缆点 |
| 绘图 | `Icons.show_chart` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/show_chart/default/24px.svg" width="20" alt="show_chart"> | `ic_nav_plot.svg`：坐标轴 + 实时波形 |
| 协议 | `Icons.settings_ethernet` | <img src="https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/settings_ethernet/default/24px.svg" width="20" alt="settings_ethernet"> | `ic_nav_protocol.svg`：帧结构/连接线 + 齿轮小角标 |

### 数据收发页

| 区域 | 功能 | 当前图标 | 建议 SVG | 备注 |
| --- | --- | --- | --- | --- |
| 普通工具栏 | 切换 Shell/普通 | `Icons.terminal`、`Icons.swap_horiz` | `ic_raw_shell.svg`、`ic_raw_switch.svg` | Shell 入口默认隐藏，但图标要可辨认 |
| 普通工具栏 | 开始/停止接收 | `Icons.play_arrow` / `Icons.stop` | `ic_raw_receive_start.svg` / `ic_raw_receive_stop.svg` | 可沿用播放/停止形状，加接收箭头暗示 |
| 普通工具栏 | 清空 | `Icons.clear` | `ic_common_clear.svg` 或 `ic_raw_clear_log.svg` | Shell 清屏和普通清空可以共用或细分 |
| 普通工具栏 | 保存 | `Icons.save` | `ic_common_save.svg` | 当前语义可用 |
| 普通工具栏 | 高级设置 | `Icons.settings` | `ic_common_settings.svg` | 和绘图设置统一 |
| 发送区 | 发送 | `Icons.send` | `ic_raw_send.svg` | 箭头可指向串口线 |
| 导出弹窗 | 文本/原始字节 | `Icons.text_snippet`、`Icons.memory` | `ic_raw_export_text.svg`、`ic_raw_export_bytes.svg` | 保持文本和二进制差异 |

### Shell 模式

| 功能 | 当前图标 | 建议 SVG | 设计说明 |
| --- | --- | --- | --- |
| 命令行模式 | `Icons.keyboard_return` | `ic_shell_line_input.svg` | 回车符 + 输入行 |
| 逐键模式 | `Icons.keyboard` | `ic_shell_key_input.svg` | 键盘 + 单字符点 |
| 更多功能 | `Icons.more_vert` | `ic_common_more.svg` | 保持通用 |
| 文件发送/接收 | `Icons.folder_open` | `ic_shell_transfer.svg` | 文件 + 双向箭头，不绑定 YMODEM |
| 选择文件 | `Icons.attach_file` | `ic_common_attach_file.svg` | 当前语义可用 |
| 发送文件 | `Icons.upload_file` | `ic_shell_file_send.svg` | 文件 + 向外箭头 |
| 接收文件 | `Icons.download` | `ic_shell_file_receive.svg` | 文件 + 向内箭头 |

### 绘图页工具栏

| 组 | 功能 | 当前图标 | 建议 SVG | 优先级 |
| --- | --- | --- | --- | --- |
| 采集 | 开始/停止绘图 | `Icons.play_arrow` / `Icons.stop` | `ic_plot_start.svg` / `ic_plot_stop.svg` | P2 |
| 协议 | 解析器配置 | `Icons.settings` | `ic_common_settings.svg` | P2 |
| 配置文件 | 新建/编辑 | `Icons.add` / `Icons.edit` | `ic_profile_add.svg` / `ic_profile_edit.svg` | P2 |
| 游标 | 垂直光标 | `Icons.vertical_align_center` | `ic_plot_cursor_vertical.svg` | P1 |
| 游标 | 添加观察 | `Icons.add_location_alt` | `ic_plot_observation_add.svg` | P1 |
| 测量 | X-X | `Icons.vertical_align_center` | `ic_plot_measure_xx.svg` | P0 |
| 测量 | Y-Y | `Icons.horizontal_rule` | `ic_plot_measure_yy.svg` | P0 |
| 测量 | 统计 | `Icons.analytics` | `ic_plot_stats.svg` | P1 |
| 测量 | 统计范围 | `Icons.straighten` | `ic_plot_stats_range.svg` | P1 |
| 视图 | 跟随 | `Icons.trending_flat` | `ic_plot_follow_latest.svg` | P1 |
| 视图 | 图例 | `Icons.list_alt` | `ic_plot_legend.svg` | P1 |
| 缩放 | 撤回缩放 | `Icons.undo` | `ic_plot_zoom_undo.svg` | P2 |
| 缩放 | 框选放大 | `Icons.crop_free` | `ic_plot_box_zoom.svg` | P1 |
| 缩放 | X 放大 | `Icons.zoom_in` | `ic_plot_zoom_x_in.svg` | P0 |
| 缩放 | X 缩小 | `Icons.zoom_out` | `ic_plot_zoom_x_out.svg` | P0 |
| 缩放 | Y 放大 | `Icons.vertical_align_top` | `ic_plot_zoom_y_in.svg` | P0 |
| 缩放 | Y 缩小 | `Icons.vertical_align_bottom` | `ic_plot_zoom_y_out.svg` | P0 |
| 文件 | 导入数据 | `Icons.file_open` | `ic_plot_import.svg` | P0 |
| 文件 | 导出数据 | `Icons.save` | `ic_plot_export.svg` | P1 |
| 自适应 | Y 自适应 | `Icons.vertical_align_center` | `ic_plot_fit_y.svg` | P0 |
| 自适应 | X 自适应 | `Icons.horizontal_rule` | `ic_plot_fit_x.svg` | P0 |
| 自适应 | 全自适应 | `Icons.fit_screen` | `ic_plot_fit_all.svg` | P0 |
| 数据 | 清空数据 | `Icons.clear` | `ic_plot_clear_data.svg` | P2 |
| 设置 | 高级设置 | `Icons.tune` | `ic_common_tune.svg` | P2 |

### 通道和地址配置

| 功能 | 当前图标 | 建议 SVG | 备注 |
| --- | --- | --- | --- |
| 编辑通道 | `Icons.settings` | `ic_channel_settings.svg` | 小尺寸 14 px，需要线条更简洁 |
| 选择地址 | `Icons.chevron_right` | `ic_channel_apply_preset.svg` | 当前箭头太像展开，可改为地址标签 + 箭头 |
| 当前颜色选中 | `Icons.check` | `ic_common_check.svg` | 需在彩色背景上清晰 |
| 自定义颜色 | `Icons.palette_outlined` | `ic_channel_palette.svg` | 可保留调色板语义 |
| 配置拖拽排序 | `Icons.drag_handle` | `ic_common_drag_handle.svg` | 可保留 |
| 删除配置 | `Icons.delete` / `Icons.delete_outline` | `ic_common_delete.svg` | 统一一种删除图标 |
| 导入配置 | `Icons.file_upload_outlined` | `ic_profile_import.svg` | 使用“文件 + 向内箭头”，避免像导出 |
| CSV 表格 | `Icons.table_chart` | `ic_profile_table.svg` | 可保留表格语义 |
| C 代码 | `Icons.code` | `ic_profile_code.svg` | 可保留代码括号语义 |
| 粘贴 | `Icons.content_paste` | `ic_common_paste.svg` | 可保留 |

### 应用信息与更新

| 功能 | 当前图标 | 建议 SVG | 备注 |
| --- | --- | --- | --- |
| 应用信息 | `Icons.info_outline` | `ic_common_info.svg` | P2 |
| 检查更新 | `Icons.update` | `ic_update_check.svg` | 箭头循环 + 版本点 |
| 下载更新 | `Icons.download` | `ic_update_download.svg` | P2 |
| 高级设置 | `Icons.tune` | `ic_common_tune.svg` | P2 |
| 打开外部链接 | `Icons.open_in_new` | `ic_common_open_external.svg` | P2 |
| 回退版本 | `Icons.restore` | `ic_update_rollback.svg` | 历史箭头 + 版本块 |
| 强提示 | `Icons.warning_amber_rounded` | `ic_common_warning.svg` | P2 |

## 绘图专用图标设计细则

### 坐标轴语言

- X 轴使用水平基线，Y 轴使用垂直基线。
- 轴向动作必须让方向明确：
  - X 相关图标必须有水平箭头或水平边界。
  - Y 相关图标必须有垂直箭头或垂直边界。
- 不要再使用“垂直居中/水平线/顶部对齐/底部对齐”这类布局语义图标表达绘图操作。

### 测量类

- X-X：仅使用清晰的 `Δx` 符号，不叠加游标、坐标轴或双向箭头。
- Y-Y：仅使用清晰的 `Δy` 符号，不叠加游标、坐标轴或双向箭头。
- 统计：波形或柱图 + 小型 `Σ`，如果小尺寸下 `Σ` 糊掉，改用三条不同高度的柱形。
- 统计范围：两个竖向范围边界 + 中间浅色选区，边界上可加 `S1/S2` 的抽象短线，不直接写文字。

### 缩放类

- X/Y 放大/缩小统一使用放大镜主体，保持通用缩放语义。
- 放大镜内部使用 `+` / `-` 区分放大和缩小。
- 左下角使用字体 `X` / `Y` 标识轴向，避免遮挡放大镜手柄；字母需要大于放大镜内的 `+` / `-`。
- X/Y 轴向不得只靠 tooltip 区分，图标本体必须包含字体化的 `X` / `Y` 标识。

### 自适应类

- X 自适应：仅使用清晰的 `Auto X` 符号，`Aut` 用紧凑文字，`o` 设计成小放大镜，底部 `X` 使用字体并放大突出轴向。
- Y 自适应：仅使用清晰的 `Auto Y` 符号，`Aut` 用紧凑文字，`o` 设计成小放大镜，底部 `Y` 使用字体并放大突出轴向。
- 全自适应：沿用 `Auto` + 小放大镜结构，底部使用字体 `Full` 表示完整自适应。

## Flutter 接入建议

当前 P0 图标已通过统一接口替换到绘图页工具栏：

- 统一组件：`lib/views/widgets/app_icon.dart`
- 图标常量：`AppIcons`
- 资产目录：`assets/icons/`
- 已替换页面：绘图页 P0 工具栏图标（X-X、Y-Y、X/Y 放大缩小、X/Y/全自适应、导入绘图数据）
- SVG 图标按 24x24 viewBox 绘制并在文件内处理 padding，调用侧默认使用 `AppIcon` 的 24px 尺寸，不对单个图标额外缩放。

本地 SVG 资源需要在 `pubspec.yaml` 注册：

```yaml
flutter:
  assets:
    - assets/icons/
```

后续 P1/P2 替换继续通过 `AppIcons` 增加常量，并使用 `AppIcon`，避免每个按钮直接写 `SvgPicture.asset`：

```dart
class AppIcon extends StatelessWidget {
  final String name;
  final double size;
  final Color? color;

  const AppIcon(this.name, {super.key, this.size = 20, this.color});

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? IconTheme.of(context).color;
    return SvgPicture.asset(
      'assets/icons/$name.svg',
      width: size,
      height: size,
      colorFilter:
          iconColor == null
              ? null
              : ColorFilter.mode(iconColor, BlendMode.srcIn),
    );
  }
}
```

迁移原则：

- 先迁移 P0 绘图工具栏图标，验证 SVG 清晰度和用户理解。
- 再迁移 Shell/数据收发和通道面板。
- 最后迁移应用信息、状态栏和通用弹窗图标。
- 同一功能迁移后删除对应 `Icons.*` 使用，避免混用导致风格不统一。

## 验收清单

- 16 px、18 px、20 px 三种尺寸下边缘清晰。
- 浅色主题、深色 Shell 主题、禁用态、选中态都可辨认。
- 只看图标和 tooltip，能区分 X 放大、X 缩小、Y 放大、Y 缩小。
- X-X 和 Y-Y 不再复用布局类图标。
- 导入和导出方向明确，不再让导入看起来像导出。
- 图标中心视觉平衡，放在现有 32x32 工具栏按钮中不偏移。
- SVG 不写死颜色，使用 `currentColor` 或 Flutter 侧 `ColorFilter`。
- 文件名符合 `ic_<domain>_<action>.svg` 规则。
