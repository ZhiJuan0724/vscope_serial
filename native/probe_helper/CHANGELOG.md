# probe_helper Changelog

`probe_helper` 使用独立于 SerialTools 主应用的语义化版本号。主应用发布时可以继续捆绑原 helper 版本，也可以单独升级 helper；版本号只在 `Cargo.toml` 中维护。

## v1.0.0 - 2026-07-21

### Added

- 支持枚举和连接 J-Link、CMSIS-DAP v1 与 CMSIS-DAP v2 探针。
- 支持 probe-rs 内置目标及用户自定义目标 YAML。
- 支持 RTT Up 0 读取、自动扫描、指定地址和指定范围扫描。
- 提供版本化二进制帧协议、能力协商和独立版本查询。
