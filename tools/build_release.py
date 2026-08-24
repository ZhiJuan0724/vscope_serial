#!/usr/bin/env python3
"""
VScope Serial Windows Release 打包工具

自动执行以下流程：
1. 清理旧发布目录
2. flutter analyze - 静态分析
3. flutter test - 运行单元测试
4. 清理旧 Windows 构建目录并执行全新 Release 构建
5. 内置固定版本的轻量 OpenOCD 运行时
6. 打包便携版：exe + 依赖 DLL + VC++ 运行时 DLL（开箱即用）

C++ DLL 说明：
- native_serial_reader.dll 由 CMake 自动编译，输出到 build/windows/x64/runner/Release/
- 该 DLL 依赖 VC++ 运行时（MSVCP140.dll、VCRUNTIME140.dll 等）
- 便携版已包含这些运行时 DLL，无需用户额外安装

使用方法：
    python tools/build_release.py

输出目录：
    build/releases/
    └── vscope_serial-x.x.x-portable/     # 便携版目录
    └── vscope_serial-x.x.x-portable.zip  # 便携版压缩包
    └── vscope_serial-x.x.x-symbols.zip   # 独立调试符号，不进入便携版

依赖：
    - Flutter SDK
    - Python 3.7+
    - 7-Zip（可选，用于压缩zip包）
"""

import argparse
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from generate_update_assets import generate as generate_update_assets
from prepare_windows_release_bundle import prepare_windows_release_bundle

# ========== 配置 ==========

PROJECT_ROOT = Path(__file__).parent.parent.resolve()
BUILD_DIR = PROJECT_ROOT / "build"
RELEASE_DIR = BUILD_DIR / "releases"
FLUTTER_BUILD_DIR = BUILD_DIR / "windows" / "x64" / "runner" / "Release"
WINDOWS_BUILD_DIR = BUILD_DIR / "windows"

# ========== 颜色输出 ==========

class Colors:
    GREEN = "\033[92m"
    YELLOW = "\033[93m"
    RED = "\033[91m"
    BLUE = "\033[94m"
    CYAN = "\033[96m"
    BOLD = "\033[1m"
    END = "\033[0m"


def info(msg: str):
    print(f"{Colors.BLUE}[INFO]{Colors.END} {msg}")


def success(msg: str):
    print(f"{Colors.GREEN}[OK]{Colors.END} {msg}")


def warn(msg: str):
    print(f"{Colors.YELLOW}[WARN]{Colors.END} {msg}")


def error(msg: str):
    print(f"{Colors.RED}[ERROR]{Colors.END} {msg}")


def step(msg: str):
    print(f"\n{Colors.BOLD}{Colors.CYAN}>>> {msg}{Colors.END}")


# ========== 工具函数 ==========

def run_cmd(cmd: list[str], cwd: Path = None, check: bool = True) -> subprocess.CompletedProcess:
    """运行命令并返回结果"""
    cmd_str = " ".join(cmd)
    info(f"执行: {cmd_str}")
    
    result = subprocess.run(
        cmd,
        cwd=cwd or PROJECT_ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="")
    
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode, cmd, output=result.stdout, stderr=result.stderr
        )
    
    return result


def get_version() -> str:
    """从 pubspec.yaml 读取版本号"""
    pubspec = PROJECT_ROOT / "pubspec.yaml"
    if not pubspec.exists():
        return "0.0.0"
    
    with open(pubspec, "r", encoding="utf-8") as f:
        for line in f:
            if line.startswith("version:"):
                return line.split(":")[1].strip().split("+")[0]
    return "0.0.0"


def get_build_time() -> str:
    """生成 UTC 构建时间，用于注入应用信息界面。"""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def clean_release_dir():
    """清理旧的发布目录"""
    if RELEASE_DIR.exists():
        shutil.rmtree(RELEASE_DIR)
        info("已清理旧的发布目录")
    RELEASE_DIR.mkdir(parents=True, exist_ok=True)


def clean_windows_build_dir():
    """清理 Windows 构建目录，防止其他分支的旧产物混入发布包"""
    if WINDOWS_BUILD_DIR.exists():
        shutil.rmtree(WINDOWS_BUILD_DIR)
        info("已清理旧的 Windows 构建目录")


def package_debug_symbols(version: str) -> Path:
    """单独归档 PDB，供分析对应版本的 Windows minidump。"""
    pdb_files = sorted(FLUTTER_BUILD_DIR.rglob("*.pdb"))
    if not pdb_files:
        raise FileNotFoundError("Release 构建未生成 PDB，无法归档崩溃分析符号")

    staging_dir = BUILD_DIR / "windows-symbols"
    if staging_dir.exists():
        shutil.rmtree(staging_dir)
    staging_dir.mkdir(parents=True)
    for source in pdb_files:
        relative = source.relative_to(FLUTTER_BUILD_DIR)
        destination = staging_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)

    archive_path = RELEASE_DIR / f"vscope_serial-{version}-symbols.zip"
    shutil.make_archive(
        str(archive_path.with_suffix("")),
        "zip",
        root_dir=staging_dir,
    )
    shutil.rmtree(staging_dir)
    return archive_path


def create_zip(source_dir: Path, zip_path: Path):
    """创建 zip 压缩包"""
    seven_zip = shutil.which("7z")
    if seven_zip:
        run_cmd([
            seven_zip, "a", "-tzip", "-mx=9", str(zip_path), f"{source_dir}/*"
        ], check=False)
    else:
        shutil.make_archive(
            str(zip_path.with_suffix("")),
            "zip",
            root_dir=source_dir,
        )


# ========== 主流程 ==========

def main():
    parser = argparse.ArgumentParser(
        description="VScope Serial Windows Release 打包工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python tools/build_release.py              # 完整流程
  python tools/build_release.py --skip-test  # 跳过测试
  python tools/build_release.py --no-zip     # 不生成 zip 包
        """
    )
    parser.add_argument("--skip-analyze", action="store_true", help="跳过 flutter analyze")
    parser.add_argument("--skip-test", action="store_true", help="跳过 flutter test")
    parser.add_argument("--no-zip", action="store_true", help="不生成 zip 压缩包")
    parser.add_argument("--version", "-v", help="指定版本号（默认从 pubspec.yaml 读取）")
    
    args = parser.parse_args()
    
    version = args.version or get_version()
    build_time = get_build_time()
    info(f"项目版本: {version}")
    info(f"构建时间: {build_time}")
    info(f"项目目录: {PROJECT_ROOT}")

    # 一旦开始新的打包流程，就先移除上一次发布输出，避免构建或测试失败后
    # 仍误把旧压缩包当作本次产物。
    clean_release_dir()
    
    # 检查 Flutter
    flutter_cmd = shutil.which("flutter")
    if not flutter_cmd:
        error("未找到 Flutter SDK，请确保 flutter 命令在 PATH 中")
        sys.exit(1)
    info(f"Flutter 路径: {flutter_cmd}")
    # ========== 步骤 1: 静态分析 ==========
    if not args.skip_analyze:
        step("步骤 1/3: 静态分析 (flutter analyze)")
        try:
            run_cmd([flutter_cmd, "analyze"])
            success("静态分析通过")
        except subprocess.CalledProcessError:
            error("静态分析失败，请修复上述问题")
            sys.exit(1)
    else:
        warn("跳过静态分析")
    
    # ========== 步骤 2: 单元测试 ==========
    if not args.skip_test:
        step("步骤 2/3: 单元测试 (flutter test)")
        try:
            run_cmd([flutter_cmd, "test"])
            success("单元测试通过")
        except subprocess.CalledProcessError:
            error("单元测试失败，请修复上述问题")
            sys.exit(1)
    else:
        warn("跳过单元测试")
    
    # ========== 步骤 3: Flutter Release 构建 ==========
    step("步骤 3/3: 全新 Release 构建 (flutter build windows --release)")
    try:
        # Flutter/CMake 默认执行增量构建。必须先删除整个 Windows 构建树，
        # 否则切换分支后遗留的 exe、DLL 或辅助工具可能继续留在 Release
        # bundle 中，并被后续步骤原样打包。
        clean_windows_build_dir()
        run_cmd([
            flutter_cmd,
            "build",
            "windows",
            "--release",
            f"--dart-define=BUILD_TIME={build_time}",
        ])
        success("Release 构建完成")
    except subprocess.CalledProcessError:
        error("Release 构建失败")
        sys.exit(1)

    symbols_zip = package_debug_symbols(version)
    success(f"调试符号归档完成: {symbols_zip}")
    
    # ========== 步骤 4: 打包 ==========
    step("打包便携版")

    # 本地与 CI 共用同一个发布目录组装器，避免附加运行时和校验规则漂移。
    portable_name = f"vscope_serial-{version}-portable"
    portable_dir = RELEASE_DIR / portable_name
    info(f"打包便携版: {portable_name}")
    copied_runtime = prepare_windows_release_bundle(
        FLUTTER_BUILD_DIR,
        portable_dir,
    )
    for runtime_dll in copied_runtime:
        info(f"复制 VC++ DLL: {runtime_dll.name}")
    success(f"便携版打包完成: {portable_dir}")
    
    # 生成自动更新兼容的 ZIP 和更新清单
    portable_zip = None
    if not args.no_zip:
        info("生成自动更新 ZIP 和清单...")
        portable_zip, update_manifest = generate_update_assets(
            portable_dir,
            f"v{version}",
            RELEASE_DIR,
        )
        success(f"便携版 zip: {portable_zip}")
        success(f"更新清单: {update_manifest}")
    
    # ========== 输出汇总 ==========
    print(f"\n{Colors.BOLD}{Colors.GREEN}{'='*60}{Colors.END}")
    print(f"{Colors.BOLD}{Colors.GREEN}  打包完成！{Colors.END}")
    print(f"{Colors.BOLD}{Colors.GREEN}{'='*60}{Colors.END}")
    print(f"\n版本: {version}")
    print(f"输出目录: {RELEASE_DIR}\n")
    
    print(f"{Colors.BOLD}便携版{Colors.END}（开箱即用，包含 VC++ 运行时）:")
    print(f"  目录: {portable_dir}")
    if portable_zip:
        print(f"  Zip:  {portable_zip}")
    print(f"  符号: {symbols_zip}")
    
    # 显示文件大小
    print(f"\n文件大小:")
    if portable_zip and portable_zip.exists():
        portable_size = portable_zip.stat().st_size / (1024 * 1024)
        print(f"  便携版 zip: {portable_size:.1f} MB")
    symbols_size = symbols_zip.stat().st_size / (1024 * 1024)
    print(f"  调试符号 zip: {symbols_size:.1f} MB")
    
    # 列出包含的 DLL
    print(f"\n包含的 DLL:")
    dll_files = sorted(portable_dir.glob("*.dll"))
    for dll in dll_files:
        size = dll.stat().st_size / 1024
        print(f"  {dll.name:40s} {size:8.1f} KB")
    
    print()


if __name__ == "__main__":
    main()
