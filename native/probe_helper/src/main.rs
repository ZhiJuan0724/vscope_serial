use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender, TrySendError},
        Arc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{anyhow, bail, Context, Result};
use probe_rs::{
    config::{ChipFamily, Registry, TargetSelector},
    probe::{list::Lister, DebugProbeInfo, WireProtocol},
    rtt::{Rtt, ScanRegion},
    Permissions,
};
use serde::Deserialize;
use serde_json::{json, Map, Value};

const MAGIC: u32 = 0x3154_5452; // ASCII: RTT1
const PROTOCOL_VERSION: u64 = 1;
// Helper 独立于主应用发布，版本号统一取自 Cargo.toml，避免协议握手与产物版本不一致。
const HELPER_VERSION: &str = concat!("v", env!("CARGO_PKG_VERSION"));
const HELPER_CAPABILITIES: &[&str] = &[
    "probe.list",
    "probe.j-link",
    "probe.cmsis-dap.v1",
    "probe.cmsis-dap.v2",
    "target.list",
    "rtt.up.read",
];
const MAX_FRAME_LENGTH: usize = 16 * 1024 * 1024;
const RTT_READ_BLOCK_SIZE: usize = 8 * 1024;
const OUTPUT_QUEUE_FRAMES: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ControlBlockLocation {
    Automatic,
    Address(u64),
    Range { start: u64, end: u64 },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Command {
    id: u64,
    command: String,
    #[serde(default)]
    arguments: Map<String, Value>,
}

struct OutputFrame {
    kind: u8,
    payload: Vec<u8>,
}

#[derive(Clone)]
struct OutputQueue {
    sender: SyncSender<OutputFrame>,
}

impl OutputQueue {
    fn control(&self, kind: u8, payload: Vec<u8>) {
        let _ = self.sender.send(OutputFrame { kind, payload });
    }

    fn data(&self, payload: Vec<u8>) -> bool {
        match self.sender.try_send(OutputFrame { kind: 3, payload }) {
            Ok(()) => true,
            Err(TrySendError::Full(_)) => false,
            Err(TrySendError::Disconnected(_)) => false,
        }
    }

    fn diagnostic(&self, message: impl AsRef<str>) {
        self.control(4, message.as_ref().as_bytes().to_vec());
    }

    fn session_ended(&self, error: Option<&str>) {
        let payload = serde_json::to_vec(&json!({
            "connected": false,
            "error": error,
        }))
        .unwrap_or_default();
        self.control(5, payload);
    }
}

struct ActiveSession {
    stop: Arc<AtomicBool>,
    worker: JoinHandle<()>,
}

impl ActiveSession {
    fn stop(self) {
        self.stop.store(true, Ordering::Release);
        let _ = self.worker.join();
    }
}

#[derive(Default)]
struct CustomTargets {
    families: Vec<ChipFamily>,
    target_sources: HashMap<String, String>,
    diagnostics: Vec<String>,
}

fn main() -> Result<()> {
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!("probe_helper {HELPER_VERSION}");
        return Ok(());
    }
    let (output_tx, output_rx) = mpsc::sync_channel(OUTPUT_QUEUE_FRAMES);
    let writer = thread::spawn(move || writer_loop(output_rx));
    let output = OutputQueue { sender: output_tx };

    let mut active: Option<ActiveSession> = None;
    let result = command_loop(&output, &mut active);
    if let Some(session) = active.take() {
        session.stop();
    }
    drop(output);
    let _ = writer.join();
    result
}

fn command_loop(output: &OutputQueue, active: &mut Option<ActiveSession>) -> Result<()> {
    let stdin = io::stdin();
    let mut input = stdin.lock();
    loop {
        let Some(frame) = read_frame(&mut input)? else {
            return Ok(());
        };
        if frame.kind != 1 {
            continue;
        }
        let command: Command =
            serde_json::from_slice(&frame.payload).context("invalid command JSON")?;
        let id = command.id;
        let response = handle_command(command, output, active);
        match response {
            Ok(result) => send_response(output, id, true, result, None),
            Err(error) => send_response(output, id, false, json!({}), Some(error.to_string())),
        }
    }
}

fn handle_command(
    command: Command,
    output: &OutputQueue,
    active: &mut Option<ActiveSession>,
) -> Result<Value> {
    match command.command.as_str() {
        "hello" => Ok(json!({
            "protocolVersion": PROTOCOL_VERSION,
            "helperVersion": HELPER_VERSION,
            // 能力由握手显式声明，后续增加烧录等功能时无需更换进程协议入口。
            "capabilities": HELPER_CAPABILITIES,
        })),
        "listProbes" => list_probes(&command.arguments),
        "listTargets" => list_targets(&command.arguments, output),
        "connect" => {
            if let Some(session) = active.take() {
                session.stop();
            }
            *active = Some(start_session(&command.arguments, output.clone())?);
            Ok(json!({}))
        }
        "disconnect" => {
            if let Some(session) = active.take() {
                session.stop();
            }
            Ok(json!({}))
        }
        other => bail!("unsupported command: {other}"),
    }
}

fn list_probes(arguments: &Map<String, Value>) -> Result<Value> {
    let requested_kind = string_arg(arguments, "kind");
    let probes = Lister::new()
        .list_all()
        .into_iter()
        .filter_map(|probe| {
            let kind = probe_kind(&probe)?;
            if !requested_kind.is_empty() && requested_kind != kind {
                return None;
            }
            Some(json!({
                "id": probe_id(&probe),
                "name": probe_display_name(&probe),
                "kind": kind,
            }))
        })
        .collect::<Vec<_>>();
    Ok(json!({"probes": probes}))
}

fn list_targets(arguments: &Map<String, Value>, output: &OutputQueue) -> Result<Value> {
    let directory = PathBuf::from(string_arg(arguments, "directory"));
    let custom = load_custom_targets(&directory);
    for diagnostic in &custom.diagnostics {
        output.diagnostic(diagnostic);
    }

    let registry = Registry::from_builtin_families();
    let mut targets = HashMap::<String, Value>::new();
    for family in registry.families() {
        for chip in &family.variants {
            targets.insert(
                chip.name.to_ascii_lowercase(),
                json!({
                    "name": chip.name,
                    "vendor": family.name,
                    "source": "probe-rs",
                }),
            );
        }
    }
    // 用户目标按名称覆盖内置目标；来源信息用于连接窗口诊断。
    for family in &custom.families {
        for chip in &family.variants {
            let source = custom
                .target_sources
                .get(&chip.name.to_ascii_lowercase())
                .cloned()
                .unwrap_or_else(|| "user".to_string());
            targets.insert(
                chip.name.to_ascii_lowercase(),
                json!({
                    "name": chip.name,
                    "vendor": family.name,
                    "source": source,
                }),
            );
        }
    }
    let mut targets = targets.into_values().collect::<Vec<_>>();
    targets.sort_by(|left, right| {
        left["name"]
            .as_str()
            .unwrap_or_default()
            .cmp(right["name"].as_str().unwrap_or_default())
    });
    Ok(json!({"targets": targets}))
}

fn start_session(arguments: &Map<String, Value>, output: OutputQueue) -> Result<ActiveSession> {
    let stop = Arc::new(AtomicBool::new(false));
    let worker_stop = stop.clone();
    let arguments = arguments.clone();
    let (startup_tx, startup_rx) = mpsc::sync_channel::<Result<()>>(1);
    let worker = thread::spawn(move || {
        let result = run_rtt_session(&arguments, &output, worker_stop, &startup_tx);
        match result {
            Ok(()) => output.session_ended(None),
            Err(error) => {
                let message = format!("{error:#}");
                let _ = startup_tx.try_send(Err(anyhow!(message.clone())));
                output.diagnostic(format!("RTT 会话已结束: {message}"));
                output.session_ended(Some(&message));
            }
        }
    });
    match startup_rx.recv_timeout(Duration::from_secs(14)) {
        Ok(Ok(())) => Ok(ActiveSession { stop, worker }),
        Ok(Err(error)) => {
            stop.store(true, Ordering::Release);
            let _ = worker.join();
            Err(error)
        }
        Err(_) => {
            stop.store(true, Ordering::Release);
            let _ = worker.join();
            bail!("连接探针或扫描 RTT 控制块超时")
        }
    }
}

fn run_rtt_session(
    arguments: &Map<String, Value>,
    output: &OutputQueue,
    stop: Arc<AtomicBool>,
    startup: &SyncSender<Result<()>>,
) -> Result<()> {
    let probe_id = string_arg(arguments, "probeId");
    let requested_kind = string_arg(arguments, "kind");
    let probe_info = Lister::new()
        .list_all()
        .into_iter()
        .find(|probe| {
            probe_kind(probe) == Some(requested_kind.as_str())
                && (probe_id.is_empty() || probe_id == probe_id_for_match(probe))
        })
        .ok_or_else(|| anyhow!("未找到所选探针"))?;
    let mut probe = probe_info.open().context("无法打开探针")?;
    let protocol = match string_arg(arguments, "wireProtocol").as_str() {
        "jtag" => WireProtocol::Jtag,
        _ => WireProtocol::Swd,
    };
    probe
        .select_protocol(protocol)
        .context("无法选择调试接口")?;
    let clock_khz = integer_arg(arguments, "clockKhz").clamp(1, 50_000) as u32;
    probe.set_speed(clock_khz).context("无法设置调试时钟")?;

    let target_directory = PathBuf::from(string_arg(arguments, "targetsDirectory"));
    let custom = load_custom_targets(&target_directory);
    for diagnostic in &custom.diagnostics {
        output.diagnostic(diagnostic);
    }
    let mut registry = Registry::from_builtin_families();
    for family in custom.families {
        registry
            .add_target_family(family)
            .context("注册自定义目标失败")?;
    }
    let selector = if bool_arg(arguments, "autoDetectTarget") {
        TargetSelector::Auto
    } else {
        let target = string_arg(arguments, "target");
        if target.trim().is_empty() {
            bail!("请选择目标芯片或开启自动识别")
        }
        TargetSelector::Unspecified(target)
    };
    let mut session = probe
        .attach_with_registry(selector, Permissions::default(), &registry)
        .context("连接目标芯片失败")?;
    let mut core = session.core(0).context("无法访问目标核心 0")?;
    let control_block = control_block_location(arguments)?;
    let mut rtt = attach_rtt_with_retry(&mut core, control_block, &stop, Duration::from_secs(10))?;
    if rtt.up_channel(0).is_none() {
        bail!("目标未提供 RTT Up 0 通道")
    }
    startup.send(Ok(())).ok();

    let started = Instant::now();
    let mut buffer = vec![0u8; RTT_READ_BLOCK_SIZE];
    let mut dropped_frames = 0u64;
    let mut last_drop_notice = Instant::now();
    while !stop.load(Ordering::Acquire) {
        let read = rtt
            .up_channel(0)
            .ok_or_else(|| anyhow!("RTT Up 0 通道已消失"))?
            .read(&mut core, &mut buffer);
        let count = match read {
            Ok(count) => count,
            Err(error) => {
                output.diagnostic(format!("RTT 读取暂时中断，正在重新扫描控制块: {error}"));
                rtt =
                    attach_rtt_with_retry(&mut core, control_block, &stop, Duration::from_secs(5))
                        .context("目标复位后无法恢复 RTT")?;
                continue;
            }
        };
        if count == 0 {
            thread::sleep(Duration::from_millis(2));
            continue;
        }
        let monotonic_us = started.elapsed().as_micros().min(i64::MAX as u128) as i64;
        let wall_clock_us = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros()
            .min(i64::MAX as u128) as i64;
        let payload = data_payload(0, monotonic_us, wall_clock_us, &buffer[..count]);
        if !output.data(payload) {
            dropped_frames += 1;
            if last_drop_notice.elapsed() >= Duration::from_secs(1) {
                output.diagnostic(format!(
                    "内置 RTT 输出队列已满，累计丢弃 {dropped_frames} 个数据块"
                ));
                last_drop_notice = Instant::now();
            }
        }
    }
    Ok(())
}

fn attach_rtt_with_retry(
    core: &mut probe_rs::Core<'_>,
    control_block: ControlBlockLocation,
    stop: &AtomicBool,
    timeout: Duration,
) -> Result<Rtt> {
    let deadline = Instant::now() + timeout;
    let mut last_error = None;
    while !stop.load(Ordering::Acquire) && Instant::now() < deadline {
        let result = match control_block {
            ControlBlockLocation::Automatic => Rtt::attach(core),
            ControlBlockLocation::Address(address) => Rtt::attach_at(core, address),
            ControlBlockLocation::Range { start, end } => {
                // ScanRegion 接收多个地址段；当前界面只提供一个连续范围。
                let ranges = std::iter::once(start..end).collect();
                Rtt::attach_region(core, &ScanRegion::Ranges(ranges))
            }
        };
        match result {
            Ok(rtt) => return Ok(rtt),
            Err(error) => last_error = Some(error),
        }
        thread::sleep(Duration::from_millis(100));
    }
    if stop.load(Ordering::Acquire) {
        bail!("RTT 会话已取消")
    }
    let suggestion = match control_block {
        ControlBlockLocation::Automatic => "；Auto 扫描失败，请尝试指定地址或指定范围",
        _ => "",
    };
    Err(anyhow!(
        "未找到 RTT 控制块{}: {}",
        suggestion,
        last_error
            .map(|error| error.to_string())
            .unwrap_or_else(|| "未知错误".to_string())
    ))
}

fn load_custom_targets(directory: &Path) -> CustomTargets {
    let mut result = CustomTargets::default();
    if directory.as_os_str().is_empty() || !directory.is_dir() {
        return result;
    }
    let mut paths = match fs::read_dir(directory) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok().map(|item| item.path()))
            .filter(|path| is_target_yaml(path))
            .collect::<Vec<_>>(),
        Err(error) => {
            result
                .diagnostics
                .push(format!("读取自定义 RTT 目标目录失败: {error}"));
            return result;
        }
    };
    paths.sort();
    let mut custom_names = HashSet::new();
    for path in paths {
        let source = path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("unknown")
            .to_string();
        let parsed = fs::read_to_string(&path)
            .with_context(|| format!("读取 {source} 失败"))
            .and_then(|yaml| {
                serde_yaml::from_str::<ChipFamily>(&yaml)
                    .with_context(|| format!("解析 {source} 失败"))
            });
        let family = match parsed {
            Ok(family) => family,
            Err(error) => {
                result.diagnostics.push(error.to_string());
                continue;
            }
        };
        let names = family
            .variants
            .iter()
            .map(|chip| chip.name.to_ascii_lowercase())
            .collect::<Vec<_>>();
        if let Some(duplicate) = names.iter().find(|name| custom_names.contains(*name)) {
            result.diagnostics.push(format!(
                "自定义目标 {source} 与同目录已加载目标重名 ({duplicate})，已忽略该文件"
            ));
            continue;
        }
        for (key, chip) in names.into_iter().zip(&family.variants) {
            custom_names.insert(key.clone());
            result.target_sources.insert(key, source.clone());
            let _ = chip;
        }
        result.families.push(family);
    }
    result
}

fn is_target_yaml(path: &Path) -> bool {
    if path.file_name().and_then(|name| name.to_str()) == Some("_example.yaml") {
        return false;
    }
    matches!(
        path.extension().and_then(|extension| extension.to_str()),
        Some(extension) if extension.eq_ignore_ascii_case("yaml") || extension.eq_ignore_ascii_case("yml")
    )
}

fn probe_kind(info: &DebugProbeInfo) -> Option<&'static str> {
    let kind = info.probe_type().to_ascii_lowercase();
    if kind.contains("j-link") || kind.contains("jlink") {
        Some("jlink")
    } else if kind.contains("cmsis") || kind.contains("dap") {
        Some("cmsisDap")
    } else {
        None
    }
}

fn probe_id(info: &DebugProbeInfo) -> String {
    let interface = info
        .interface
        .map(|value| format!("/{value}"))
        .unwrap_or_default();
    format!(
        "{:04x}:{:04x}:{}{}",
        info.vendor_id,
        info.product_id,
        info.serial_number.as_deref().unwrap_or_default(),
        interface
    )
}

fn probe_id_for_match(info: &DebugProbeInfo) -> String {
    probe_id(info)
}

fn probe_display_name(info: &DebugProbeInfo) -> String {
    match info.serial_number.as_deref() {
        Some(serial) if !serial.is_empty() => format!("{} ({serial})", info.identifier),
        _ => info.identifier.clone(),
    }
}

fn string_arg(arguments: &Map<String, Value>, key: &str) -> String {
    arguments
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn bool_arg(arguments: &Map<String, Value>, key: &str) -> bool {
    arguments.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn integer_arg(arguments: &Map<String, Value>, key: &str) -> i64 {
    arguments.get(key).and_then(Value::as_i64).unwrap_or(0)
}

fn optional_integer_arg(arguments: &Map<String, Value>, key: &str) -> Option<i64> {
    arguments.get(key).and_then(Value::as_i64)
}

fn control_block_location(arguments: &Map<String, Value>) -> Result<ControlBlockLocation> {
    let mode = string_arg(arguments, "controlBlockMode");
    match mode.as_str() {
        "address" => {
            let address = non_negative_integer_arg(arguments, "controlBlockAddress")?;
            Ok(ControlBlockLocation::Address(address))
        }
        "range" => {
            let start = non_negative_integer_arg(arguments, "controlBlockRangeStart")?;
            let end = non_negative_integer_arg(arguments, "controlBlockRangeEnd")?;
            if end <= start {
                bail!("RTT 搜索范围无效，结束地址必须大于起始地址")
            }
            Ok(ControlBlockLocation::Range { start, end })
        }
        // 兼容仅携带旧版 controlBlockAddress 的客户端。
        "" if optional_integer_arg(arguments, "controlBlockAddress").is_some() => {
            Ok(ControlBlockLocation::Address(non_negative_integer_arg(
                arguments,
                "controlBlockAddress",
            )?))
        }
        _ => Ok(ControlBlockLocation::Automatic),
    }
}

fn non_negative_integer_arg(arguments: &Map<String, Value>, key: &str) -> Result<u64> {
    let value =
        optional_integer_arg(arguments, key).ok_or_else(|| anyhow!("缺少或无法识别参数 {key}"))?;
    u64::try_from(value).map_err(|_| anyhow!("参数 {key} 不能为负数"))
}

fn send_response(output: &OutputQueue, id: u64, ok: bool, result: Value, error: Option<String>) {
    let payload = serde_json::to_vec(&json!({
        "id": id,
        "ok": ok,
        "result": result,
        "error": error,
    }))
    .unwrap_or_else(|_| b"{\"ok\":false,\"error\":\"response encoding failed\"}".to_vec());
    output.control(2, payload);
}

fn data_payload(channel: u32, monotonic_us: i64, wall_clock_us: i64, data: &[u8]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(20 + data.len());
    payload.extend_from_slice(&channel.to_le_bytes());
    payload.extend_from_slice(&monotonic_us.to_le_bytes());
    payload.extend_from_slice(&wall_clock_us.to_le_bytes());
    payload.extend_from_slice(data);
    payload
}

fn writer_loop(receiver: Receiver<OutputFrame>) {
    let stdout = io::stdout();
    let mut output = stdout.lock();
    while let Ok(frame) = receiver.recv() {
        if write_frame(&mut output, frame.kind, &frame.payload).is_err() {
            break;
        }
    }
}

struct InputFrame {
    kind: u8,
    payload: Vec<u8>,
}

fn read_frame(input: &mut impl Read) -> Result<Option<InputFrame>> {
    let mut header = [0u8; 9];
    let mut read = 0;
    while read < header.len() {
        let count = input.read(&mut header[read..])?;
        if count == 0 {
            if read == 0 {
                return Ok(None);
            }
            bail!("truncated frame header")
        }
        read += count;
    }
    if u32::from_le_bytes(header[0..4].try_into().unwrap()) != MAGIC {
        bail!("invalid frame magic")
    }
    let kind = header[4];
    let length = u32::from_le_bytes(header[5..9].try_into().unwrap()) as usize;
    if length > MAX_FRAME_LENGTH {
        bail!("frame exceeds size limit")
    }
    let mut payload = vec![0u8; length];
    input.read_exact(&mut payload)?;
    Ok(Some(InputFrame { kind, payload }))
}

fn write_frame(output: &mut impl Write, kind: u8, payload: &[u8]) -> io::Result<()> {
    output.write_all(&MAGIC.to_le_bytes())?;
    output.write_all(&[kind])?;
    output.write_all(&(payload.len() as u32).to_le_bytes())?;
    output.write_all(payload)?;
    output.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary_targets_directory(test_name: &str) -> PathBuf {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "serialtools-rtt-{test_name}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn frame_round_trip() {
        let mut bytes = Vec::new();
        write_frame(&mut bytes, 1, b"hello").unwrap();
        let frame = read_frame(&mut bytes.as_slice()).unwrap().unwrap();
        assert_eq!(frame.kind, 1);
        assert_eq!(frame.payload, b"hello");
    }

    #[test]
    fn example_target_is_always_excluded() {
        assert!(!is_target_yaml(Path::new("_example.yaml")));
        assert!(is_target_yaml(Path::new("my-chip.yaml")));
        assert!(is_target_yaml(Path::new("my-chip.yml")));
        assert!(!is_target_yaml(Path::new("readme.txt")));
    }

    #[test]
    fn distributed_example_uses_valid_probe_rs_schema() {
        let yaml = include_str!("../../../assets/rtt/_example.yaml");
        serde_yaml::from_str::<ChipFamily>(yaml).expect("invalid distributed target example");
    }

    #[test]
    fn malformed_target_does_not_block_other_target_files() {
        let directory = temporary_targets_directory("malformed");
        fs::write(directory.join("bad.yaml"), "not: [valid").unwrap();
        fs::write(
            directory.join("good.yaml"),
            include_str!("../../../assets/rtt/_example.yaml"),
        )
        .unwrap();

        let targets = load_custom_targets(&directory);
        assert_eq!(targets.families.len(), 1);
        assert_eq!(targets.diagnostics.len(), 1);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn later_duplicate_target_file_is_ignored() {
        let directory = temporary_targets_directory("duplicate");
        let yaml = include_str!("../../../assets/rtt/_example.yaml");
        fs::write(directory.join("a.yaml"), yaml).unwrap();
        fs::write(directory.join("b.yaml"), yaml).unwrap();

        let targets = load_custom_targets(&directory);
        assert_eq!(targets.families.len(), 1);
        assert!(targets.diagnostics.iter().any(|line| line.contains("重名")));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn data_frame_keeps_channel_and_timestamps() {
        let payload = data_payload(3, 10, 20, &[1, 2, 3]);
        assert_eq!(u32::from_le_bytes(payload[0..4].try_into().unwrap()), 3);
        assert_eq!(i64::from_le_bytes(payload[4..12].try_into().unwrap()), 10);
        assert_eq!(i64::from_le_bytes(payload[12..20].try_into().unwrap()), 20);
        assert_eq!(&payload[20..], &[1, 2, 3]);
    }

    #[test]
    fn helper_contract_includes_cmsis_dap_v2() {
        assert!(HELPER_CAPABILITIES.contains(&"probe.cmsis-dap.v2"));
        assert!(HELPER_CAPABILITIES.contains(&"rtt.up.read"));
    }

    #[test]
    fn control_block_modes_parse_and_validate_ranges() {
        let automatic = Map::new();
        assert_eq!(
            control_block_location(&automatic).unwrap(),
            ControlBlockLocation::Automatic
        );

        let address = Map::from_iter([
            ("controlBlockMode".into(), json!("address")),
            ("controlBlockAddress".into(), json!(0x2000_1000_u64)),
        ]);
        assert_eq!(
            control_block_location(&address).unwrap(),
            ControlBlockLocation::Address(0x2000_1000)
        );

        let range = Map::from_iter([
            ("controlBlockMode".into(), json!("range")),
            ("controlBlockRangeStart".into(), json!(0x2000_0000_u64)),
            ("controlBlockRangeEnd".into(), json!(0x2001_0000_u64)),
        ]);
        assert_eq!(
            control_block_location(&range).unwrap(),
            ControlBlockLocation::Range {
                start: 0x2000_0000,
                end: 0x2001_0000,
            }
        );

        let invalid = Map::from_iter([
            ("controlBlockMode".into(), json!("range")),
            ("controlBlockRangeStart".into(), json!(0x2001_0000_u64)),
            ("controlBlockRangeEnd".into(), json!(0x2000_0000_u64)),
        ]);
        assert!(control_block_location(&invalid).is_err());
    }
}
