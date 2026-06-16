#!/usr/bin/env python3
"""End-to-end smoke tests for the native Windows updater."""

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_manifest(root: Path, relative_paths: list[str]) -> None:
    manifest = {
        "schemaVersion": 1,
        "files": [
            {"path": path, "sha256": digest(root / path)}
            for path in relative_paths
        ],
    }
    (root / "app-files.json").write_text(
        json.dumps(manifest, indent=2), encoding="utf-8"
    )


def run_updater(
    updater: Path, install: Path, payload: Path, workspace: Path
) -> dict:
    result = workspace / "result.json"
    plan = workspace / "plan.json"
    plan.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "pid": 0,
                "installDir": str(install),
                "payloadDir": str(payload),
                "executable": "vscope_serial.exe",
                "resultFile": str(result),
                "cleanupDir": str(workspace),
            }
        ),
        encoding="utf-8",
    )
    subprocess.run(
        [str(updater), "--plan", str(plan), "--elevated"],
        check=False,
        timeout=30,
    )
    return json.loads(result.read_text(encoding="utf-8"))


def success_case(updater: Path, root: Path) -> None:
    install = root / "success-install"
    payload = root / "success-payload"
    workspace = root / "success-work"
    for directory in (install, payload, workspace):
        directory.mkdir(parents=True)

    system32 = Path(os.environ["SystemRoot"]) / "System32"
    shutil.copy2(system32 / "whoami.exe", install / "vscope_serial.exe")
    (install / "obsolete.dll").write_text("obsolete", encoding="utf-8")
    (install / "settings").mkdir()
    (install / "settings" / "settings.json").write_text(
        "user-data", encoding="utf-8"
    )
    write_manifest(install, ["vscope_serial.exe", "obsolete.dll"])

    shutil.copy2(system32 / "where.exe", payload / "vscope_serial.exe")
    expected_digest = digest(payload / "vscope_serial.exe")
    (payload / "new.dll").write_text("new-dll", encoding="utf-8")
    write_manifest(payload, ["vscope_serial.exe", "new.dll"])

    result = run_updater(updater, install, payload, workspace)
    assert result["success"] is True
    assert digest(install / "vscope_serial.exe") == expected_digest
    assert (install / "new.dll").exists()
    assert not (install / "obsolete.dll").exists()
    assert (
        install / "settings" / "settings.json"
    ).read_text(encoding="utf-8") == "user-data"


def rollback_case(updater: Path, root: Path) -> None:
    install = root / "rollback-install"
    payload = root / "rollback-payload"
    workspace = root / "rollback-work"
    for directory in (install, payload, workspace):
        directory.mkdir(parents=True)

    system32 = Path(os.environ["SystemRoot"]) / "System32"
    shutil.copy2(system32 / "whoami.exe", install / "vscope_serial.exe")
    original_digest = digest(install / "vscope_serial.exe")

    shutil.copy2(system32 / "where.exe", payload / "vscope_serial.exe")
    (payload / "missing.dll").write_text("temporary", encoding="utf-8")
    write_manifest(payload, ["vscope_serial.exe", "missing.dll"])
    (payload / "missing.dll").unlink()

    result = run_updater(updater, install, payload, workspace)
    assert result["success"] is False
    assert digest(install / "vscope_serial.exe") == original_digest


def main() -> None:
    project = Path(__file__).resolve().parent.parent
    updater = (
        project
        / "build"
        / "windows"
        / "x64"
        / "runner"
        / "Debug"
        / "vscope_updater.exe"
    )
    if not updater.exists():
        raise FileNotFoundError(f"missing updater build: {updater}")
    with tempfile.TemporaryDirectory(
        prefix="vscope-updater-test-", ignore_cleanup_errors=True
    ) as temp:
        root = Path(temp)
        copied_updater = root / "vscope_updater.exe"
        shutil.copy2(updater, copied_updater)
        success_case(copied_updater, root)
        rollback_case(copied_updater, root)
        time.sleep(0.5)
    print("Native updater integration tests passed.")


if __name__ == "__main__":
    main()
