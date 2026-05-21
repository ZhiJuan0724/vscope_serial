#!/usr/bin/env python3
"""
VScope Serial Windows Release 打包工具

自动执行以下流程：
1. flutter analyze - 静态分析
2. flutter test - 运行单元测试
3. flutter build windows --release - Release 构建
4. 打包便携版：exe + 依赖 DLL + VC++ 运行时 DLL（开箱即用）

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

依赖：
    - Flutter SDK
    - Python 3.7+
    - 7-Zip（可选，用于压缩zip包）
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


# ========== 配置 ==========

PROJECT_ROOT = Path(__file__).parent.parent.resolve()
BUILD_DIR = PROJECT_ROOT / "build"
RELEASE_DIR = BUILD_DIR / "releases"
FLUTTER_BUILD_DIR = BUILD_DIR / "windows" / "x64" / "runner" / "Release"

# VC++ 运行时 DLL（x64）
# native_serial_reader.dll 是 MSVC 编译的 C++ DLL，需要这些运行时
VC_RUNTIME_DLLS = [
    "MSVCP140.dll",
    "VCRUNTIME140.dll",
    "VCRUNTIME140_1.dll",
]

# 需要排除的文件（不打包）
EXCLUDE_FILES = {
    "logs",           # 日志目录
    ".flutter-plugins",
    ".flutter-plugins-dependencies",
    "native_assets.json",
}


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


def clean_release_dir():
    """清理旧的发布目录"""
    if RELEASE_DIR.exists():
        shutil.rmtree(RELEASE_DIR)
        info("已清理旧的发布目录")
    RELEASE_DIR.mkdir(parents=True, exist_ok=True)


def find_vc_runtime_dlls() -> list[Path]:
    """查找系统中的 VC++ 运行时 DLL"""
    found = []
    system32 = Path("C:/Windows/System32")
    
    for dll_name in VC_RUNTIME_DLLS:
        dll_path = system32 / dll_name
        if dll_path.exists():
            found.append(dll_path)
        else:
            warn(f"未找到 VC++ 运行时 DLL: {dll_name}")
    
    return found


def copy_build_output(dst_dir: Path):
    """复制构建输出到目标目录（便携版：包含 VC++ 运行时）"""
    if not FLUTTER_BUILD_DIR.exists():
        raise FileNotFoundError(f"构建目录不存在: {FLUTTER_BUILD_DIR}")
    
    dst_dir.mkdir(parents=True, exist_ok=True)
    
    # 复制所有文件和目录
    for item in FLUTTER_BUILD_DIR.iterdir():
        if item.name in EXCLUDE_FILES:
            continue
        
        dst_path = dst_dir / item.name
        if item.is_dir():
            if dst_path.exists():
                shutil.rmtree(dst_path)
            shutil.copytree(item, dst_path)
        else:
            shutil.copy2(item, dst_path)
    
    # 复制 VC++ 运行时 DLL（C++ DLL 依赖）
    vc_dlls = find_vc_runtime_dlls()
    for dll_path in vc_dlls:
        shutil.copy2(dll_path, dst_dir / dll_path.name)
        info(f"复制 VC++ DLL: {dll_path.name}")
    
    if not vc_dlls:
        warn("未找到任何 VC++ 运行时 DLL，便携版可能无法在缺少 VC++ 的系统上运行")


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
    parser.add_argument("--skip-build", action="store_true", help="跳过 flutter build")
    parser.add_argument("--no-zip", action="store_true", help="不生成 zip 压缩包")
    parser.add_argument("--version", "-v", help="指定版本号（默认从 pubspec.yaml 读取）")
    
    args = parser.parse_args()
    
    version = args.version or get_version()
    info(f"项目版本: {version}")
    info(f"项目目录: {PROJECT_ROOT}")
    
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
    
    # ========== 步骤 3: Release 构建 ==========
    if not args.skip_build:
        step("步骤 3/3: Release 构建 (flutter build windows --release)")
        try:
            run_cmd([flutter_cmd, "build", "windows", "--release"])
            success("Release 构建完成")
        except subprocess.CalledProcessError:
            error("Release 构建失败")
            sys.exit(1)
    else:
        warn("跳过构建，使用已有的构建产物")
        if not FLUTTER_BUILD_DIR.exists():
            error(f"构建目录不存在: {FLUTTER_BUILD_DIR}")
            sys.exit(1)
    
    # ========== 步骤 4: 打包 ==========
    step("打包便携版")
    
    clean_release_dir()
    
    # 便携版（含 VC++ 运行时）
    portable_name = f"vscope_serial-{version}-portable"
    portable_dir = RELEASE_DIR / portable_name
    info(f"打包便携版: {portable_name}")
    copy_build_output(portable_dir)
    success(f"便携版打包完成: {portable_dir}")
    
    # 生成 zip
    portable_zip = None
    if not args.no_zip:
        info("生成 zip 压缩包...")
        portable_zip = RELEASE_DIR / f"{portable_name}.zip"
        create_zip(portable_dir, portable_zip)
        success(f"便携版 zip: {portable_zip}")
    
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
    
    # 显示文件大小
    print(f"\n文件大小:")
    if portable_zip and portable_zip.exists():
        portable_size = portable_zip.stat().st_size / (1024 * 1024)
        print(f"  便携版 zip: {portable_size:.1f} MB")
    
    # 列出包含的 DLL
    print(f"\n包含的 DLL:")
    dll_files = sorted(portable_dir.glob("*.dll"))
    for dll in dll_files:
        size = dll.stat().st_size / 1024
        print(f"  {dll.name:40s} {size:8.1f} KB")
    
    print()


if __name__ == "__main__":
    main()
