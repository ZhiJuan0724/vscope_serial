# 工程工具

`tools/` 保存构建、发布、更新资产和崩溃分析工具。测试与模拟程序统一放在 [`test_tools/`](../test_tools/README.md)。

## 工具清单

| 工具 | 用途 |
| --- | --- |
| `build_debug.py` | 准备 Debug 附加运行时并构建、运行 Windows 应用 |
| `build_release.py` | 执行完整 Windows Release 检查、构建和打包 |
| `generate_update_assets.py` | 生成便携 ZIP、应用文件清单和更新清单 |
| `prepare_openocd_runtime.py` | 准备固定版本的最小 OpenOCD 运行时 |
| `analyze_crash_dump.ps1` | 检查并分析 Windows 原生崩溃转储 |

## `build_debug.py`

本地 Debug 推荐入口。脚本会先准备 `flutter run` 不会自动生成的内置 OpenOCD 压缩运行时，再执行 Windows Debug 构建并启动应用。原生 DLL、崩溃转储支持和 updater 仍由 Flutter/CMake 构建链生成。

```powershell
python tools/build_debug.py
```

常用选项：

- `--openocd-source`：使用本地已解压的 xPack OpenOCD，避免下载锁定版本。
- `--openocd-cache`：指定 OpenOCD 下载缓存目录。
- `--build-only`：只构建 Debug，不启动应用。
- `-- <参数>`：把其后的参数继续传给 `flutter run`。

## `build_release.py`

推荐的本地发布入口。脚本会：

1. 清理旧发布输出和 Windows 构建树。
2. 执行 `flutter analyze` 和 `flutter test`。
3. 注入构建时间并执行全新 Windows Release 构建。
4. 准备内置 OpenOCD、原生 DLL、VC++ 运行时和第三方许可证。
5. 生成更新资产、便携 ZIP 和独立符号包。

```powershell
python tools/build_release.py
python tools/build_release.py --help
```

常用选项：

- `--skip-analyze`：跳过静态检查。
- `--skip-test`：跳过 Flutter 测试。
- `--no-zip`：只保留便携目录，不生成便携 ZIP。
- `--version` / `-v`：覆盖从 `pubspec.yaml` 读取的版本号。

脚本不提供 `--skip-build`，不得复用旧构建目录打包。输出位于 `build/releases/`。

## `generate_update_assets.py`

从已构建的 Windows Release bundle 生成：

- 便携 ZIP。
- bundle 内的 `app-files.json`。
- 包含版本、文件大小和 SHA-256 的更新清单。

```powershell
python tools/generate_update_assets.py `
  --bundle build/windows/x64/runner/Release `
  --tag v1.0.7-beta.5 `
  --output build/releases
```

参数：

- `--bundle`：Windows Release bundle 目录。
- `--tag`：完整发布 tag，必须以 `v` 开头。
- `--output`：输出目录。

工具排除 `settings/`、`config/`、`logs/`、`exports/` 及 `.lib`、`.exp`、`.pdb`，避免把用户数据和中间文件纳入更新管理。

## `prepare_openocd_runtime.py`

为 bundle 准备固定版本的 xPack OpenOCD。默认下载项目锁定版本并校验 SHA-256，将所需程序、DLL、scripts 和许可证压缩为单个 `openocd-runtime.zip`，同时生成包含版本、大小和 SHA-256 的 `openocd-runtime.json`。

```powershell
python tools/prepare_openocd_runtime.py `
  --bundle build/windows/x64/runner/Release
```

可选参数：

- `--source`：使用已解压的本地 xPack OpenOCD 根目录，不执行下载。
- `--cache`：指定下载缓存目录。

应用首次使用内置 OpenOCD 时，会校验清单并解压到发布目录的 `runtime/openocd/extracted/<OpenOCD版本-归档哈希>/`。解压使用临时目录和原子切换，不依赖外部 7-Zip。

更新 OpenOCD 版本时必须同时更新版本号、下载地址、SHA-256、运行文件清单和第三方许可说明，并验证本地与 CI 打包。

## `analyze_crash_dump.ps1`

兼容 Windows PowerShell 5.1 和 PowerShell 7。将脚本复制到包含 `.dmp`、同名 `.json`、日志和对应版本 PDB 的目录后运行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\analyze_crash_dump.ps1
```

脚本会查找 Windows SDK 中的 `cdb.exe`，检查 PDB 与转储模块是否匹配，并生成中文 Markdown 报告和完整调试器输出。

常用参数：

- `-InputDirectory`：输入目录，默认是脚本所在目录。
- `-DumpPath`：指定转储；默认选择目录中最新的 `.dmp`。
- `-OutputPath`：指定 Markdown 报告路径。
- `-DebuggerPath`：手动指定 `cdb.exe`。
- `-Offline`：不连接 Microsoft 公共符号服务器。

详细参数和示例可运行：

```powershell
Get-Help .\analyze_crash_dump.ps1 -Detailed
```
