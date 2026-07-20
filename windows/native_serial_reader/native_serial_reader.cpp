#include "native_serial_reader.h"
#include "native_time_utils.h"
#include "dart_api_dl.h"

#include <windows.h>
#include <cfgmgr32.h>
#include <setupapi.h>
#include <stdio.h>
#include <thread>
#include <atomic>
#include <chrono>
#include <algorithm>
#include <cctype>
#include <climits>
#include <cstring>
#include <cwctype>
#include <iterator>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <vector>

// 连接周期共享状态；访问读取线程相关资源时必须遵循 stop/close 的同步顺序。
static HANDLE g_hSerial = INVALID_HANDLE_VALUE;
static std::thread g_readThread;
static std::atomic<bool> g_running(false);
static std::mutex g_stateMutex;
static int64_t g_dartPort = 0;
static int g_timeoutMs = 0;
static LARGE_INTEGER g_qpcFrequency = {};
static std::atomic<uint64_t> g_readBytes(0);
static std::atomic<uint64_t> g_maxReadBlockBytes(0);
static std::atomic<uint64_t> g_readCallbackCount(0);
static std::atomic<uint64_t> g_postFailureCount(0);
// 仅由绘图活动所有者开启；其它页面始终逐块交付，避免影响终端交互延迟。
static std::atomic<bool> g_plotReceiveAggregationEnabled(false);
static HCMNOTIFICATION g_portNotification = NULL;
static std::atomic<int64_t> g_portMonitorDartPort(0);
static const GUID kComPortInterfaceGuid = {
    0x86e0d1e0,
    0x8089,
    0x11d0,
    {0x9c, 0xe4, 0x08, 0x00, 0x3e, 0x30, 0x1f, 0x73}};

static std::string wide_to_utf8(const std::wstring& value) {
    if (value.empty()) return std::string();
    int size = WideCharToMultiByte(
        CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
        NULL, 0, NULL, NULL);
    if (size <= 0) return std::string();

    std::string result(size, '\0');
    WideCharToMultiByte(
        CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
        result.data(), size, NULL, NULL);
    return result;
}

static bool is_com_port_name(const std::wstring& value) {
    if (value.size() <= 3) return false;
    if (towupper(value[0]) != L'C' ||
        towupper(value[1]) != L'O' ||
        towupper(value[2]) != L'M') {
        return false;
    }
    return std::all_of(
        value.begin() + 3, value.end(),
        [](wchar_t ch) { return iswdigit(ch) != 0; });
}

static std::wstring normalize_port_name(std::wstring value) {
    while (!value.empty() && iswspace(value.back())) value.pop_back();
    size_t start = 0;
    while (start < value.size() && iswspace(value[start])) start++;
    value.erase(0, start);
    std::transform(
        value.begin(), value.end(), value.begin(),
        [](wchar_t ch) { return static_cast<wchar_t>(towupper(ch)); });
    return value;
}

struct SerialPortDetail {
    std::wstring port;
    std::wstring name;
};

static std::wstring read_device_property(
    HDEVINFO devices,
    SP_DEVINFO_DATA* deviceData,
    DWORD property) {
    wchar_t value[1024] = {};
    DWORD valueType = 0;
    DWORD requiredSize = 0;
    if (!SetupDiGetDeviceRegistryPropertyW(
            devices,
            deviceData,
            property,
            &valueType,
            reinterpret_cast<PBYTE>(value),
            sizeof(value),
            &requiredSize)) {
        return std::wstring();
    }
    if (valueType != REG_SZ && valueType != REG_EXPAND_SZ) {
        return std::wstring();
    }
    return std::wstring(value);
}

static std::wstring normalize_device_name(std::wstring value) {
    while (!value.empty() && iswspace(value.back())) value.pop_back();
    size_t start = 0;
    while (start < value.size() && iswspace(value[start])) start++;
    value.erase(0, start);
    std::replace(value.begin(), value.end(), L'\t', L' ');
    std::replace(value.begin(), value.end(), L'\r', L' ');
    std::replace(value.begin(), value.end(), L'\n', L' ');
    return value;
}

static void append_setupapi_ports(
    std::map<std::wstring, std::wstring>& ports,
    bool includeNames) {
    HDEVINFO devices = SetupDiGetClassDevsW(
        &kComPortInterfaceGuid,
        NULL,
        NULL,
        DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (devices == INVALID_HANDLE_VALUE) return;

    for (DWORD index = 0;; index++) {
        SP_DEVICE_INTERFACE_DATA interfaceData = {};
        interfaceData.cbSize = sizeof(interfaceData);
        if (!SetupDiEnumDeviceInterfaces(
                devices, NULL, &kComPortInterfaceGuid, index,
                &interfaceData)) {
            if (GetLastError() == ERROR_NO_MORE_ITEMS) break;
            continue;
        }

        DWORD requiredSize = 0;
        SetupDiGetDeviceInterfaceDetailW(
            devices, &interfaceData, NULL, 0, &requiredSize, NULL);
        if (requiredSize < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)) continue;

        std::vector<uint8_t> detailBuffer(requiredSize);
        auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(
            detailBuffer.data());
        detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);

        SP_DEVINFO_DATA deviceData = {};
        deviceData.cbSize = sizeof(deviceData);
        if (!SetupDiGetDeviceInterfaceDetailW(
                devices, &interfaceData, detail, requiredSize, NULL,
                &deviceData)) {
            continue;
        }

        HKEY deviceKey = SetupDiOpenDevRegKey(
            devices, &deviceData, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_READ);
        if (deviceKey == INVALID_HANDLE_VALUE) continue;

        wchar_t portName[256] = {};
        DWORD valueType = 0;
        DWORD valueSize = sizeof(portName);
        LONG queryResult = RegQueryValueExW(
            deviceKey, L"PortName", NULL, &valueType,
            reinterpret_cast<LPBYTE>(portName), &valueSize);
        RegCloseKey(deviceKey);

        if (queryResult == ERROR_SUCCESS &&
            (valueType == REG_SZ || valueType == REG_EXPAND_SZ)) {
            std::wstring normalized = normalize_port_name(portName);
            if (is_com_port_name(normalized)) {
                std::wstring friendlyName;
                if (includeNames) {
                    friendlyName = read_device_property(
                        devices, &deviceData, SPDRP_FRIENDLYNAME);
                    if (friendlyName.empty()) {
                        friendlyName = read_device_property(
                            devices, &deviceData, SPDRP_DEVICEDESC);
                    }
                }
                ports[normalized] = normalize_device_name(friendlyName);
            }
        }
    }

    SetupDiDestroyDeviceInfoList(devices);
}

static void append_registry_ports(
    std::map<std::wstring, std::wstring>& ports) {
    HKEY key = NULL;
    if (RegOpenKeyExW(
            HKEY_LOCAL_MACHINE,
            L"HARDWARE\\DEVICEMAP\\SERIALCOMM",
            0,
            KEY_READ,
            &key) != ERROR_SUCCESS) {
        return;
    }

    for (DWORD index = 0;; index++) {
        wchar_t valueName[512] = {};
        wchar_t valueData[256] = {};
        DWORD valueNameSize = static_cast<DWORD>(std::size(valueName));
        DWORD valueDataSize = sizeof(valueData);
        DWORD valueType = 0;
        LONG result = RegEnumValueW(
            key, index, valueName, &valueNameSize, NULL, &valueType,
            reinterpret_cast<LPBYTE>(valueData), &valueDataSize);
        if (result == ERROR_NO_MORE_ITEMS) break;
        if (result != ERROR_SUCCESS ||
            (valueType != REG_SZ && valueType != REG_EXPAND_SZ)) {
            continue;
        }

        std::wstring normalized = normalize_port_name(valueData);
        if (is_com_port_name(normalized) &&
            ports.find(normalized) == ports.end()) {
            ports[normalized] = std::wstring();
        }
    }

    RegCloseKey(key);
}

static int port_number(const std::wstring& value) {
    if (!is_com_port_name(value)) return INT_MAX;
    try {
        return std::stoi(value.substr(3));
    } catch (...) {
        return INT_MAX;
    }
}

static std::vector<SerialPortDetail> enumerate_port_details(
    bool includeNames) {
    std::map<std::wstring, std::wstring> uniquePorts;
    append_setupapi_ports(uniquePorts, includeNames);
    append_registry_ports(uniquePorts);

    std::vector<SerialPortDetail> ports;
    ports.reserve(uniquePorts.size());
    for (const auto& entry : uniquePorts) {
        ports.push_back({entry.first, entry.second});
    }
    std::sort(
        ports.begin(), ports.end(),
        [](const SerialPortDetail& left, const SerialPortDetail& right) {
            int leftNumber = port_number(left.port);
            int rightNumber = port_number(right.port);
            if (leftNumber != rightNumber) return leftNumber < rightNumber;
            return left.port < right.port;
        });
    return ports;
}

static std::vector<std::wstring> enumerate_ports() {
    const std::vector<SerialPortDetail> details =
        enumerate_port_details(false);
    std::vector<std::wstring> ports;
    ports.reserve(details.size());
    for (const SerialPortDetail& detail : details) {
        ports.push_back(detail.port);
    }
    return ports;
}

static DWORD CALLBACK port_notification_callback(
    HCMNOTIFICATION,
    PVOID,
    CM_NOTIFY_ACTION action,
    PCM_NOTIFY_EVENT_DATA,
    DWORD) {
    if (action != CM_NOTIFY_ACTION_DEVICEINTERFACEARRIVAL &&
        action != CM_NOTIFY_ACTION_DEVICEINTERFACEREMOVAL) {
        return ERROR_SUCCESS;
    }

    int64_t dartPort = g_portMonitorDartPort.load();
    if (dartPort != 0 && Dart_PostCObject_DL != NULL) {
        Dart_CObject message;
        message.type = Dart_CObject_kInt32;
        message.value.as_int32 = 1;
        Dart_PostCObject_DL(dartPort, &message);
    }
    return ERROR_SUCCESS;
}

// QPC 计数换算时不直接对完整计数乘一百万。
// 商余数拆分可避免进程长期运行后的整数乘法溢出。
static int64_t get_monotonic_time_us() {
    LARGE_INTEGER count;
    QueryPerformanceCounter(&count);
    return vscope::native_time::qpc_ticks_to_microseconds(
        count.QuadPart, g_qpcFrequency.QuadPart);
}

static int64_t get_wall_clock_time_us() {
    FILETIME fileTime = {};
    GetSystemTimePreciseAsFileTime(&fileTime);
    ULARGE_INTEGER ticks = {};
    ticks.LowPart = fileTime.dwLowDateTime;
    ticks.HighPart = fileTime.dwHighDateTime;
    return vscope::native_time::filetime_to_unix_microseconds(ticks.QuadPart);
}

static void update_max_read_block(uint64_t bytesRead) {
    uint64_t current = g_maxReadBlockBytes.load();
    while (bytesRead > current &&
           !g_maxReadBlockBytes.compare_exchange_weak(current, bytesRead)) {
    }
}

// 原生读取合并只用于高频绘图。三个阈值共同限制延迟与单次解析负担：
// - 连续数据空闲 8ms 后交付残留；
// - 累计 8KiB 立即交付；
// - 连续流最多保留 24ms，避免一直有数据时永不交付。
constexpr size_t kPlotAggregationMaxBytes = 8 * 1024;
constexpr int64_t kPlotAggregationIdleUs = 8 * 1000;
constexpr int64_t kPlotAggregationMaxWaitUs = 24 * 1000;
constexpr size_t kPacketHeaderBytes = 32;

struct PendingReadAggregate {
    std::vector<uint8_t> bytes;
    int64_t firstMonotonicUs = 0;
    int64_t lastMonotonicUs = 0;
    int64_t firstWallClockUs = 0;
    int64_t lastWallClockUs = 0;

    PendingReadAggregate() {
        bytes.reserve(kPlotAggregationMaxBytes);
    }

    bool empty() const { return bytes.empty(); }

    void begin_if_needed(int64_t monotonicUs, int64_t wallClockUs) {
        if (!bytes.empty()) return;
        firstMonotonicUs = monotonicUs;
        firstWallClockUs = wallClockUs;
    }

    void record_last(int64_t monotonicUs, int64_t wallClockUs) {
        lastMonotonicUs = monotonicUs;
        lastWallClockUs = wallClockUs;
    }

    void clear() {
        bytes.clear();
        firstMonotonicUs = 0;
        lastMonotonicUs = 0;
        firstWallClockUs = 0;
        lastWallClockUs = 0;
    }
};

static bool post_read_block(
    int64_t dartPort,
    std::vector<uint8_t>& message,
    const uint8_t* data,
    size_t length,
    int64_t firstMonotonicUs,
    int64_t lastMonotonicUs,
    int64_t firstWallClockUs,
    int64_t lastWallClockUs) {
    if (length == 0 || dartPort == 0 || Dart_PostCObject_DL == NULL) {
        return false;
    }

    message.resize(kPacketHeaderBytes + length);
    memcpy(message.data(), &firstMonotonicUs, sizeof(firstMonotonicUs));
    memcpy(
        message.data() + sizeof(firstMonotonicUs),
        &lastMonotonicUs,
        sizeof(lastMonotonicUs));
    memcpy(
        message.data() + sizeof(firstMonotonicUs) + sizeof(lastMonotonicUs),
        &firstWallClockUs,
        sizeof(firstWallClockUs));
    memcpy(
        message.data() + sizeof(firstMonotonicUs) + sizeof(lastMonotonicUs) +
            sizeof(firstWallClockUs),
        &lastWallClockUs,
        sizeof(lastWallClockUs));
    memcpy(message.data() + kPacketHeaderBytes, data, length);

    Dart_CObject msg;
    msg.type = Dart_CObject_kTypedData;
    msg.value.as_typed_data.type = Dart_TypedData_kUint8;
    msg.value.as_typed_data.length =
        static_cast<intptr_t>(kPacketHeaderBytes + length);
    msg.value.as_typed_data.values = message.data();

    if (Dart_PostCObject_DL(dartPort, &msg)) {
        g_readCallbackCount.fetch_add(1);
        return true;
    }
    g_postFailureCount.fetch_add(1);
    return false;
}

// 读取线程：复用 OVERLAPPED/event，停止时由 CancelIoEx 唤醒未完成 ReadFile。
static void read_thread_func() {
    constexpr DWORD kReadBufferBytes = 64 * 1024;
    std::vector<uint8_t> buffer(kReadBufferBytes);
    std::vector<uint8_t> message(kPacketHeaderBytes + kReadBufferBytes);
    PendingReadAggregate aggregate;
    OVERLAPPED overlapped = {};
    overlapped.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (overlapped.hEvent == NULL) return;

    auto flush_aggregate = [&](int64_t dartPort) {
        if (aggregate.empty()) return;
        post_read_block(
            dartPort,
            message,
            aggregate.bytes.data(),
            aggregate.bytes.size(),
            aggregate.firstMonotonicUs,
            aggregate.lastMonotonicUs,
            aggregate.firstWallClockUs,
            aggregate.lastWallClockUs);
        aggregate.clear();
    };

    auto aggregate_deadline_wait_ms = [&](int timeoutMs) {
        if (aggregate.empty()) {
            return timeoutMs > 0 ? static_cast<DWORD>(timeoutMs) : INFINITE;
        }
        const int64_t nowUs = get_monotonic_time_us();
        const int64_t untilIdleUs =
            kPlotAggregationIdleUs - (nowUs - aggregate.lastMonotonicUs);
        const int64_t untilMaxWaitUs =
            kPlotAggregationMaxWaitUs - (nowUs - aggregate.firstMonotonicUs);
        const int64_t remainingUs = (std::min)(untilIdleUs, untilMaxWaitUs);
        if (remainingUs <= 0) return static_cast<DWORD>(1);
        const DWORD deadlineMs = static_cast<DWORD>((remainingUs + 999) / 1000);
        if (timeoutMs <= 0) return deadlineMs;
        return (std::min)(static_cast<DWORD>(timeoutMs), deadlineMs);
    };

    while (g_running.load()) {
        HANDLE hSerial = INVALID_HANDLE_VALUE;
        int64_t dartPort = 0;
        int timeoutMs = 0;
        {
            std::lock_guard<std::mutex> lock(g_stateMutex);
            hSerial = g_hSerial;
            dartPort = g_dartPort;
            timeoutMs = g_timeoutMs;
        }

        if (hSerial == INVALID_HANDLE_VALUE) break;
        
        // 关闭聚合时先交付原有残留，保证后续直接交付不会越过旧数据。
        if (!g_plotReceiveAggregationEnabled.load()) {
            flush_aggregate(dartPort);
        }

        ResetEvent(overlapped.hEvent);
        DWORD bytesRead = 0;
        BOOL result = ReadFile(
            hSerial, buffer.data(), kReadBufferBytes, &bytesRead, &overlapped);
        if (!result && GetLastError() == ERROR_IO_PENDING) {
            while (g_running.load()) {
                const DWORD waitResult =
                    WaitForSingleObject(
                        overlapped.hEvent,
                        aggregate_deadline_wait_ms(timeoutMs));
                if (waitResult == WAIT_OBJECT_0) {
                    result = GetOverlappedResult(
                        hSerial, &overlapped, &bytesRead, FALSE);
                    break;
                }
                const int64_t nowUs = get_monotonic_time_us();
                if (!g_plotReceiveAggregationEnabled.load() ||
                    (!aggregate.empty() &&
                     (nowUs - aggregate.lastMonotonicUs >=
                          kPlotAggregationIdleUs ||
                      nowUs - aggregate.firstMonotonicUs >=
                          kPlotAggregationMaxWaitUs))) {
                    flush_aggregate(dartPort);
                }
                if (waitResult != WAIT_TIMEOUT) {
                    result = FALSE;
                    break;
                }
            }
            if (!g_running.load()) {
                CancelIoEx(hSerial, &overlapped);
                GetOverlappedResult(
                    hSerial, &overlapped, &bytesRead, TRUE);
                break;
            }
        }
        
        if (result && bytesRead > 0) {
            const int64_t monotonicUs = get_monotonic_time_us();
            const int64_t wallClockUs = get_wall_clock_time_us();
            g_readBytes.fetch_add(bytesRead);
            update_max_read_block(bytesRead);
            
            if (!g_plotReceiveAggregationEnabled.load()) {
                flush_aggregate(dartPort);
                post_read_block(
                    dartPort,
                    message,
                    buffer.data(),
                    bytesRead,
                    monotonicUs,
                    monotonicUs,
                    wallClockUs,
                    wallClockUs);
            } else {
                size_t offset = 0;
                while (offset < bytesRead) {
                    aggregate.begin_if_needed(monotonicUs, wallClockUs);
                    const size_t capacity =
                        kPlotAggregationMaxBytes - aggregate.bytes.size();
                    const size_t copyLength = (std::min)(
                        capacity, static_cast<size_t>(bytesRead) - offset);
                    aggregate.bytes.insert(
                        aggregate.bytes.end(),
                        buffer.begin() + offset,
                        buffer.begin() + offset + copyLength);
                    offset += copyLength;
                    aggregate.record_last(monotonicUs, wallClockUs);
                    if (aggregate.bytes.size() >= kPlotAggregationMaxBytes) {
                        flush_aggregate(dartPort);
                    }
                }

                if (!aggregate.empty() &&
                    monotonicUs - aggregate.firstMonotonicUs >=
                        kPlotAggregationMaxWaitUs) {
                    flush_aggregate(dartPort);
                }
            }
        }
    }

    // stopReading 在关闭 Dart ReceivePort 前等待本线程退出，此处可安全冲刷残留。
    flush_aggregate(g_dartPort);
    CloseHandle(overlapped.hEvent);
}

int nsr_init_dart_api(void* data) {
    if (data == NULL) return -1;
    if (g_qpcFrequency.QuadPart == 0 &&
        !QueryPerformanceFrequency(&g_qpcFrequency)) {
        return -1;
    }
    return Dart_InitializeApiDL(data) == 0 ? 0 : -1;
}

int nsr_open_port(const char* portName, int baudRate) {
    nsr_close_port();
    
    char fullName[256];
    snprintf(fullName, sizeof(fullName), "\\\\.\\%s", portName);
    
    HANDLE hSerial = CreateFileA(
        fullName,
        GENERIC_READ | GENERIC_WRITE,
        0,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED,
        NULL
    );
    
    if (hSerial == INVALID_HANDLE_VALUE) {
        return -1;
    }
    
    DCB dcb = {0};
    dcb.DCBlength = sizeof(DCB);
    
    if (!GetCommState(hSerial, &dcb)) {
        CloseHandle(hSerial);
        return -1;
    }
    
    dcb.BaudRate = baudRate;
    dcb.ByteSize = 8;
    dcb.StopBits = ONESTOPBIT;
    dcb.Parity = NOPARITY;
    dcb.fBinary = TRUE;
    dcb.fDtrControl = DTR_CONTROL_DISABLE;
    dcb.fRtsControl = RTS_CONTROL_DISABLE;
    
    if (!SetCommState(hSerial, &dcb)) {
        CloseHandle(hSerial);
        return -1;
    }
    
    constexpr DWORD kDriverBufferBytes = 64 * 1024;
    if (!SetupComm(hSerial, kDriverBufferBytes, kDriverBufferBytes)) {
        CloseHandle(hSerial);
        return -1;
    }
    
    COMMTIMEOUTS timeouts = {0};
    timeouts.ReadIntervalTimeout = MAXDWORD;
    timeouts.ReadTotalTimeoutMultiplier = 0;
    timeouts.ReadTotalTimeoutConstant = 0;
    timeouts.WriteTotalTimeoutMultiplier = 0;
    timeouts.WriteTotalTimeoutConstant = 0;
    SetCommTimeouts(hSerial, &timeouts);
    
    PurgeComm(hSerial, PURGE_RXCLEAR | PURGE_TXCLEAR);

    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        g_hSerial = hSerial;
    }
    
    return 0;
}

void nsr_close_port() {
    // nsr_stop_reading() 已关闭 g_hSerial 并等待读取线程退出。
    nsr_stop_reading();
}

int nsr_set_config(int dataBits, int stopBits, int parity) {
    std::lock_guard<std::mutex> lock(g_stateMutex);
    if (g_hSerial == INVALID_HANDLE_VALUE) return -1;
    
    DCB dcb = {0};
    dcb.DCBlength = sizeof(DCB);
    
    if (!GetCommState(g_hSerial, &dcb)) {
        return -1;
    }
    
    dcb.ByteSize = (BYTE)dataBits;
    dcb.StopBits = (stopBits == 2) ? TWOSTOPBITS : ONESTOPBIT;
    
    switch (parity) {
        case 1: dcb.Parity = ODDPARITY; break;
        case 2: dcb.Parity = EVENPARITY; break;
        default: dcb.Parity = NOPARITY; break;
    }
    
    if (!SetCommState(g_hSerial, &dcb)) {
        return -1;
    }
    
    return 0;
}

void nsr_set_rts(int on) {
    std::lock_guard<std::mutex> lock(g_stateMutex);
    if (g_hSerial == INVALID_HANDLE_VALUE) return;
    EscapeCommFunction(g_hSerial, on ? SETRTS : CLRRTS);
}

void nsr_set_dtr(int on) {
    std::lock_guard<std::mutex> lock(g_stateMutex);
    if (g_hSerial == INVALID_HANDLE_VALUE) return;
    EscapeCommFunction(g_hSerial, on ? SETDTR : CLRDTR);
}

int nsr_start_reading(int64_t dartPort, int timeoutMs) {
    std::lock_guard<std::mutex> lock(g_stateMutex);
    if (g_hSerial == INVALID_HANDLE_VALUE) return -1;
    if (g_running.load()) return -1;
    
    g_dartPort = dartPort;
    g_timeoutMs = timeoutMs;
    g_readBytes = 0;
    g_maxReadBlockBytes = 0;
    g_readCallbackCount = 0;
    g_postFailureCount = 0;
    g_running = true;
    
    g_readThread = std::thread(read_thread_func);
    
    return 0;
}

void nsr_set_plot_receive_aggregation(int enabled) {
    g_plotReceiveAggregationEnabled = enabled != 0;
}

void nsr_get_read_metrics(
    uint64_t* bytesRead,
    uint64_t* maxBlockBytes,
    uint64_t* callbackCount,
    uint64_t* postFailureCount) {
    if (bytesRead != NULL) *bytesRead = g_readBytes.load();
    if (maxBlockBytes != NULL) {
        *maxBlockBytes = g_maxReadBlockBytes.load();
    }
    if (callbackCount != NULL) {
        *callbackCount = g_readCallbackCount.load();
    }
    if (postFailureCount != NULL) {
        *postFailureCount = g_postFailureCount.load();
    }
}

void nsr_stop_reading() {
    g_running = false;
    
    HANDLE hTemp = INVALID_HANDLE_VALUE;
    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        hTemp = g_hSerial;
    }

    if (hTemp != INVALID_HANDLE_VALUE) {
        CancelIoEx(hTemp, NULL);
    }
    
    if (g_readThread.joinable()) {
        g_readThread.join();
    }

    {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        if (g_hSerial != INVALID_HANDLE_VALUE) {
            CloseHandle(g_hSerial);
            g_hSerial = INVALID_HANDLE_VALUE;
        }
        g_dartPort = 0;
    }
}

int nsr_write(const uint8_t* data, int length) {
    std::lock_guard<std::mutex> lock(g_stateMutex);
    if (g_hSerial == INVALID_HANDLE_VALUE) return -1;
    
    DWORD bytesWritten = 0;
    OVERLAPPED ov = {0};
    ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    
    BOOL result = WriteFile(g_hSerial, data, length, &bytesWritten, &ov);
    
    if (!result && GetLastError() == ERROR_IO_PENDING) {
        if (WaitForSingleObject(ov.hEvent, 1000) == WAIT_OBJECT_0) {
            GetOverlappedResult(g_hSerial, &ov, &bytesWritten, FALSE);
            result = TRUE;
        } else {
            CancelIoEx(g_hSerial, &ov);
            GetOverlappedResult(g_hSerial, &ov, &bytesWritten, TRUE);
        }
    }
    
    CloseHandle(ov.hEvent);
    
    return result ? (int)bytesWritten : -1;
}

int nsr_is_open() {
    std::lock_guard<std::mutex> lock(g_stateMutex);
    return g_hSerial != INVALID_HANDLE_VALUE ? 1 : 0;
}

int nsr_is_connection_healthy() {
    std::lock_guard<std::mutex> lock(g_stateMutex);
    if (g_hSerial == INVALID_HANDLE_VALUE) return 0;

    DWORD errors = 0;
    COMSTAT status = {0};
    return ClearCommError(g_hSerial, &errors, &status) ? 1 : 0;
}

int nsr_list_ports(char* buffer, int capacity) {
    try {
        const std::vector<std::wstring> ports = enumerate_ports();
        std::vector<char> multiString;
        for (const std::wstring& port : ports) {
            const std::string utf8 = wide_to_utf8(port);
            multiString.insert(multiString.end(), utf8.begin(), utf8.end());
            multiString.push_back('\0');
        }
        // MultiSZ 即使为空也必须以双 NUL 结束。
        if (multiString.empty()) multiString.push_back('\0');
        multiString.push_back('\0');

        const int required = static_cast<int>(multiString.size());
        if (buffer == NULL || capacity < required) return required;
        memcpy(buffer, multiString.data(), multiString.size());
        return required;
    } catch (...) {
        return -1;
    }
}

int nsr_list_port_details(char* buffer, int capacity) {
    try {
        const std::vector<SerialPortDetail> ports =
            enumerate_port_details(true);
        std::vector<char> multiString;
        for (const SerialPortDetail& detail : ports) {
            std::string entry = wide_to_utf8(detail.port);
            entry.push_back('\t');
            entry.append(wide_to_utf8(detail.name));
            multiString.insert(
                multiString.end(), entry.begin(), entry.end());
            multiString.push_back('\0');
        }
        if (multiString.empty()) multiString.push_back('\0');
        multiString.push_back('\0');

        const int required = static_cast<int>(multiString.size());
        if (buffer == NULL || capacity < required) return required;
        memcpy(buffer, multiString.data(), multiString.size());
        return required;
    } catch (...) {
        return -1;
    }
}

int nsr_start_port_monitor(int64_t dartPort) {
    nsr_stop_port_monitor();
    if (dartPort == 0 || Dart_PostCObject_DL == NULL) return -1;

    CM_NOTIFY_FILTER filter = {};
    filter.cbSize = sizeof(filter);
    filter.FilterType = CM_NOTIFY_FILTER_TYPE_DEVICEINTERFACE;
    filter.u.DeviceInterface.ClassGuid = kComPortInterfaceGuid;

    g_portMonitorDartPort.store(dartPort);
    CONFIGRET result = CM_Register_Notification(
        &filter,
        NULL,
        port_notification_callback,
        &g_portNotification);
    if (result != CR_SUCCESS) {
        g_portMonitorDartPort.store(0);
        g_portNotification = NULL;
        return -1;
    }
    return 0;
}

void nsr_stop_port_monitor() {
    HCMNOTIFICATION notification = g_portNotification;
    g_portNotification = NULL;
    g_portMonitorDartPort.store(0);
    if (notification != NULL) {
        CM_Unregister_Notification(notification);
    }
}
