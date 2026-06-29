#include "native_serial_reader.h"
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
#include <mutex>
#include <set>
#include <string>
#include <vector>

// Global state
static HANDLE g_hSerial = INVALID_HANDLE_VALUE;
static std::thread g_readThread;
static std::atomic<bool> g_running(false);
static std::mutex g_stateMutex;
static int64_t g_dartPort = 0;
static int g_timeoutMs = 0;
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

static void append_setupapi_ports(std::set<std::wstring>& ports) {
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
            if (is_com_port_name(normalized)) ports.insert(normalized);
        }
    }

    SetupDiDestroyDeviceInfoList(devices);
}

static void append_registry_ports(std::set<std::wstring>& ports) {
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
        if (is_com_port_name(normalized)) ports.insert(normalized);
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

static std::vector<std::wstring> enumerate_ports() {
    std::set<std::wstring> uniquePorts;
    append_setupapi_ports(uniquePorts);
    append_registry_ports(uniquePorts);

    std::vector<std::wstring> ports(uniquePorts.begin(), uniquePorts.end());
    std::sort(
        ports.begin(), ports.end(),
        [](const std::wstring& left, const std::wstring& right) {
            int leftNumber = port_number(left);
            int rightNumber = port_number(right);
            if (leftNumber != rightNumber) return leftNumber < rightNumber;
            return left < right;
        });
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

// Get current time in microseconds
static int64_t get_time_us() {
    LARGE_INTEGER freq, count;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&count);
    return (count.QuadPart * 1000000LL) / freq.QuadPart;
}

// Read thread
static void read_thread_func() {
    uint8_t buffer[4096];
    
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
        
        DWORD bytesRead = 0;
        BOOL result = FALSE;
        
        if (timeoutMs > 0) {
            OVERLAPPED ov = {0};
            ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
            if (ov.hEvent == NULL) break;
            
            result = ReadFile(hSerial, buffer, sizeof(buffer), &bytesRead, &ov);
            
            if (!result && GetLastError() == ERROR_IO_PENDING) {
                DWORD waitResult = WaitForSingleObject(ov.hEvent, timeoutMs);
                if (waitResult == WAIT_OBJECT_0) {
                    result = GetOverlappedResult(hSerial, &ov, &bytesRead, FALSE);
                } else if (waitResult == WAIT_TIMEOUT) {
                    CancelIoEx(hSerial, &ov);
                    GetOverlappedResult(hSerial, &ov, &bytesRead, TRUE);
                    result = FALSE;
                }
            }
            
            CloseHandle(ov.hEvent);
        } else {
            result = ReadFile(hSerial, buffer, sizeof(buffer), &bytesRead, NULL);
        }
        
        if (result && bytesRead > 0) {
            int64_t timestampUs = get_time_us();
            
            // Send data to Dart using Dart_PostCObject_DL
            // Only post if Dart API is initialized (Dart_PostCObject_DL != NULL)
            if (dartPort != 0 && Dart_PostCObject_DL != NULL) {
                // Debug: log that we're about to post data
                // char debugMsg[256];
                // snprintf(debugMsg, sizeof(debugMsg), "[NSR] Posting %lu bytes to port %lld\n", bytesRead, g_dartPort);
                // OutputDebugStringA(debugMsg);
                uint8_t* combined = (uint8_t*)malloc(8 + bytesRead);
                if (combined != NULL) {
                    memcpy(combined, &timestampUs, 8);
                    memcpy(combined + 8, buffer, bytesRead);
                    
                    Dart_CObject msg;
                    msg.type = Dart_CObject_kTypedData;
                    msg.value.as_typed_data.type = Dart_TypedData_kUint8;
                    msg.value.as_typed_data.length = 8 + bytesRead;
                    msg.value.as_typed_data.values = combined;
                    
                    Dart_PostCObject_DL(dartPort, &msg);
                    
                    free(combined);
                }
            }
        }
    }
}

int nsr_init_dart_api(void* data) {
    if (data == NULL) return -1;
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
    
    SetupComm(hSerial, 1, 1);
    
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
    // nsr_stop_reading() already closes g_hSerial and waits for thread
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
    g_running = true;
    
    g_readThread = std::thread(read_thread_func);
    
    return 0;
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
