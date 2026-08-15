# desktop_multi_window（本地 fork）

本目录是 [MixinNetwork/flutter-plugins](https://github.com/MixinNetwork/flutter-plugins/tree/main/packages/desktop_multi_window) 中 `desktop_multi_window` `0.2.1` 的本地 vendored 副本。

## 为什么 vendored

`pubspec.yaml` 通过 `dependency_overrides` 将 `desktop_multi_window` 指向本目录：

```yaml
dependency_overrides:
  desktop_multi_window:
    path: third_party/desktop_multi_window
```

这样做是为了在 Flutter/Windows 升级后仍能对多窗口插件做本地修补，而不必等待上游发布。

## 维护约定

- 保持与上游 `0.2.1` 的差异最小化；任何本地改动都应在此文件记录动机与日期。
- 升级 Flutter 或 Windows Runner 时，与上游对应版本比对，确认本地改动是否仍需要，能回退则回退。
- 具体差异以 `git diff` 相对 vendored 初始提交为准（本目录随仓库一起版本管理）。

## 已知本地改动

（暂无专项改动记录；如有修补请在此追加，例如「修复某 Windows 版本下的窗口句柄泄漏」。）
