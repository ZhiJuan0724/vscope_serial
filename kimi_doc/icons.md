# VScope Serial 图标绘制规范

## 绘制分辨率

| 使用场景 | 推荐尺寸 | 说明 |
|---------|---------|------|
| 工具栏图标 | **24×24 px** | 实际渲染 `size: 18`，但 Material Design 标准图标画布为 24×24，建议按 24×24 绘制后缩放 |
| Tab 栏图标 | **24×24 px** | 同上 |
| 空状态/大图标 | **48×48 px** | 如暂无数据的提示图标 |
| 菜单项图标 | **24×24 px** | 下拉菜单中的图标 |

> **建议**：所有图标统一按 **24×24 px** 画布绘制，内容区域保持在 18×18 px 左右，留出 2-3px 边距。Flutter 的 `Icon(Icons.xxx, size: 18)` 会将 24×24 的矢量图标缩放到 18 逻辑像素显示。

## 图标清单

### 一、主框架 Tab 栏（lib/main.dart）

| 图标名称 | 用途 | 当前 Material 图标 | 建议绘制风格 |
|---------|------|-------------------|------------|
| 连接 | 串口连接页面 | `Icons.cable` | 串口/插头符号 |
| 原始数据 | 原始数据查看 | `Icons.terminal` | 终端/命令行符号 |
| 绘图 | 波形绘图页面 | `Icons.show_chart` | 折线图/示波器符号 |
| 协议 | 协议配置页面 | `Icons.settings_ethernet` | 网络协议/数据包符号 |

### 二、连接页面（lib/views/pages/connect_page.dart）

| 图标名称 | 用途 | 当前 Material 图标 | 建议绘制风格 |
|---------|------|-------------------|------------|
| 刷新 | 刷新串口列表 | `Icons.refresh` | 圆形箭头刷新 |
| 开始/连接 | 连接串口 | `Icons.play_arrow` | 三角形播放 |
| 停止/断开 | 断开串口 | `Icons.stop` | 正方形停止 |

### 三、绘图页面工具栏（lib/views/pages/plot_page.dart）

#### 左侧固定组

| 图标名称 | 用途 | 当前 Material 图标 | 建议绘制风格 |
|---------|------|-------------------|------------|
| 开始绘图 | 启动数据绘图 | `Icons.play_arrow` | 三角形播放（绿色） |
| 停止绘图 | 停止数据绘图 | `Icons.stop` | 正方形停止（红色） |
| 随机源设置 | 随机数据源频率 | `Icons.settings` | 齿轮 |
| 解析器配置 | 数据解析器设置 | `Icons.settings` | 齿轮（可复用） |

#### 光标与测量组（从左到右）

| 图标名称 | 用途 | 当前 Material 图标 | 建议绘制风格 |
|---------|------|-------------------|------------|
| 垂直光标 | 鼠标悬停垂直线 | `Icons.vertical_align_center` | 垂直虚线 + 十字 |
| X-X 测量 | X轴差值测量 | `Icons.vertical_align_center` | 两条垂直虚线 |
| Y-Y 测量 | Y轴差值测量 | `Icons.horizontal_rule` | 两条水平虚线 |
| 统计测量 | Max/Min/Avg | `Icons.analytics` | 柱状图/统计图表 |
| 统计范围 | 限定统计区间 | `Icons.straighten` | 双向箭头标尺 |
| 最新点跟随 | 波形跟随 | `Icons.trending_flat` | 向右箭头 |

#### 缩放与框选组

| 图标名称 | 用途 | 当前 Material 图标 | 建议绘制风格 |
|---------|------|-------------------|------------|
| 撤回缩放 | 撤销上一步缩放 | `Icons.undo` | 向左弯曲箭头 |
| 框选放大 | 矩形框选放大 | `Icons.crop_free` | 虚线矩形框 |
| X轴缩小 | X轴范围扩大 | `Icons.zoom_out` | 减号放大镜 |
| X轴放大 | X轴范围缩小 | `Icons.zoom_in` | 加号放大镜 |
| Y轴缩小 | Y轴范围扩大 | `Icons.vertical_align_bottom` | 上下双向箭头外扩 |
| Y轴放大 | Y轴范围缩小 | `Icons.vertical_align_top` | 上下双向箭头内收 |

#### 文件组

| 图标名称 | 用途 | 当前 Material 图标 | 建议绘制风格 |
|---------|------|-------------------|------------|
| 导入 CSV | 从文件导入数据 | `Icons.file_upload` | 向上箭头 + 文档 |
| 导出 CSV | 保存数据到文件 | `Icons.save` | 软盘/向下箭头 + 文档 |

#### 自适应组

| 图标名称 | 用途 | 当前 Material 图标 | 建议绘制风格 |
|---------|------|-------------------|------------|
| Y轴自适应 | 自动调整Y轴范围 | `Icons.vertical_align_center` | 垂直双向箭头 + 波浪线 |
| X轴自适应 | 自动调整X轴范围 | `Icons.horizontal_rule` | 水平双向箭头 + 波浪线 |
| 全自适应 | 自动调整X和Y | `Icons.fit_screen` | 四角向内箭头 |

#### 操作组

| 图标名称 | 用途 | 当前 Material 图标 | 建议绘制风格 |
|---------|------|-------------------|------------|
| 清空数据 | 清除所有绘图数据 | `Icons.clear` | 叉号/垃圾桶 |
| 高级设置 | 网格/帧率/抗锯齿 | `Icons.tune` | 滑块调节器 |

#### 折叠菜单按钮

| 图标名称 | 用途 | 当前 Material 图标 | 建议绘制风格 |
|---------|------|-------------------|------------|
| 更多工具 | 展开折叠菜单 | `Icons.more_vert` | 三个竖点 |

### 四、原始数据页面（lib/views/pages/raw_data_page.dart）

| 图标名称 | 用途 | 当前 Material 图标 | 建议绘制风格 |
|---------|------|-------------------|------------|
| 清空 | 清空接收数据 | `Icons.clear` | 叉号（可复用） |
| 保存 | 保存原始数据 | `Icons.save` | 软盘（可复用） |
| 发送 | 发送数据 | `Icons.send` | 纸飞机/箭头 |
| 文本模式 | 切换文本显示 | `Icons.text_snippet` | 文本文件 |
| HEX模式 | 切换HEX显示 | `Icons.memory` | 芯片/十六进制 |

### 五、通用组件（lib/views/widgets/）

| 图标名称 | 用途 | 当前 Material 图标 | 建议绘制风格 |
|---------|------|-------------------|------------|
| 下拉箭头 | 下拉框展开 | `Icons.arrow_drop_down` | 向下三角 |
| 编辑 | 状态栏编辑按钮 | `Icons.edit` | 铅笔 |

## 绘制建议

### 风格统一
- 统一使用 **线性描边风格**（Outline），不要填充
- 描边宽度：**1.5-2px**
- 端点/拐角：**圆角**
- 颜色：单色（Flutter 中通过 `Color` 动态着色，图标本身用纯黑 `#000000`）

### 文件格式
- 导出为 **SVG** 格式，Flutter 可通过 `flutter_svg` 插件加载
- 或导出为 **PNG** 多倍图：`1x`(24px)、`2x`(48px)、`3x`(72px)

### 命名规范
```
assets/icons/
  ic_play.svg          # 开始
  ic_stop.svg          # 停止
  ic_vcursor.svg       # 垂直光标
  ic_xx_measure.svg    # X-X测量
  ic_undo_zoom.svg     # 撤回缩放
  ic_box_zoom.svg      # 框选放大
  ...
```

## 当前图标使用汇总

| 图标 | 使用位置 | 当前 size |
|-----|---------|----------|
| `Icons.play_arrow` | 绘图页开始、连接页连接 | 16, 18 |
| `Icons.stop` | 绘图页停止、连接页断开 | 16, 18 |
| `Icons.settings` | 随机源设置、解析器配置 | 16, 18 |
| `Icons.vertical_align_center` | 垂直光标、Y轴自适应 | 16, 18 |
| `Icons.horizontal_rule` | Y-Y测量、X轴自适应 | 16, 18 |
| `Icons.analytics` | 统计测量 | 16 |
| `Icons.straighten` | 统计范围 | 16 |
| `Icons.trending_flat` | 最新点跟随 | 16 |
| `Icons.undo` | 撤回缩放 | 18 |
| `Icons.crop_free` | 框选放大 | 18 |
| `Icons.zoom_out` | X轴缩小 | 18 |
| `Icons.zoom_in` | X轴放大 | 18 |
| `Icons.vertical_align_bottom` | Y轴缩小 | 18 |
| `Icons.vertical_align_top` | Y轴放大 | 18 |
| `Icons.file_upload` | 导入CSV | 18 |
| `Icons.save` | 导出CSV、原始数据保存 | 18 |
| `Icons.fit_screen` | 全自适应 | 18 |
| `Icons.clear` | 清空数据、清空原始数据 | 18 |
| `Icons.tune` | 高级设置 | 18 |
| `Icons.more_vert` | 折叠菜单 | 20 |
| `Icons.cable` | Tab-连接 | 16 |
| `Icons.terminal` | Tab-原始数据 | 16 |
| `Icons.show_chart` | Tab-绘图、空状态 | 16, 48 |
| `Icons.settings_ethernet` | Tab-协议 | 16 |
| `Icons.refresh` | 刷新串口列表 | 18 |
| `Icons.send` | 发送数据 | 默认 |
| `Icons.text_snippet` | 文本模式 | 默认 |
| `Icons.memory` | HEX模式 | 默认 |
| `Icons.arrow_drop_down` | 下拉箭头 | 默认 |
| `Icons.edit` | 状态栏编辑 | 默认 |
