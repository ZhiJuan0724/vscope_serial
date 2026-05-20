#include "native_serial_reader.h"
#include "dart_api_dl.h"

#include <windows.h>
#include <stdio.h>
#include <thread>
#include <atomic>
#include <chrono>

// Global state
static HANDLE g_hSerial = INVALID_HANDLE_VALUE;
static std::thread g_readThread;
static std::atomic<bool> g_running(false);
static int64_t g_dartPort = 0;
static int g_timeoutMs = 0;

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
        // Check handle validity (may be closed by nsr_stop_reading)
        if (g_hSerial == INVALID_HANDLE_VALUE) {
            break;
        }
        
        DWORD bytesRead = 0;
        BOOL result = FALSE;
        
        if (g_timeoutMs > 0) {
            OVERLAPPED ov = {0};
            ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
            
            result = ReadFile(g_hSerial, buffer, sizeof(buffer), &bytesRead, &ov);
            
            if (!result && GetLastError() == ERROR_IO_PENDING) {
                DWORD waitResult = WaitForSingleObject(ov.hEvent, g_timeoutMs);
                if (waitResult == WAIT_OBJECT_0) {
                    // Check handle validity again
                    if (g_hSerial != INVALID_HANDLE_VALUE) {
                        GetOverlappedResult(g_hSerial, &ov, &bytesRead, FALSE);
                        result = TRUE;
                    }
                } else if (waitResult == WAIT_TIMEOUT) {
                    // Check handle validity after timeout
                    if (g_hSerial != INVALID_HANDLE_VALUE) {
                        CancelIo(g_hSerial);
                    }
                    result = FALSE;
                }
            }
            
            CloseHandle(ov.hEvent);
        } else {
            result = ReadFile(g_hSerial, buffer, sizeof(buffer), &bytesRead, NULL);
        }
        
        if (result && bytesRead > 0) {
            int64_t timestampUs = get_time_us();
            
            // Send data to Dart using Dart_PostCObject_DL
            // Only post if Dart API is initialized (Dart_PostCObject_DL != NULL)
            if (g_dartPort != 0 && Dart_PostCObject_DL != NULL) {
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
                    
                    Dart_PostCObject_DL(g_dartPort, &msg);
                    
                    free(combined);
                }
            }
        }
    }
}

int nsr_init_dart_api(void* data) {
    if (data == NULL) return -1;
    return Dart_InitializeApiDL(data);
}

int nsr_open_port(const char* portName, int baudRate) {
    if (g_hSerial != INVALID_HANDLE_VALUE) {
        nsr_close_port();
    }
    
    char fullName[256];
    snprintf(fullName, sizeof(fullName), "\\\\.\\%s", portName);
    
    g_hSerial = CreateFileA(
        fullName,
        GENERIC_READ | GENERIC_WRITE,
        0,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_OVERLAPPED,
        NULL
    );
    
    if (g_hSerial == INVALID_HANDLE_VALUE) {
        return -1;
    }
    
    DCB dcb = {0};
    dcb.DCBlength = sizeof(DCB);
    
    if (!GetCommState(g_hSerial, &dcb)) {
        CloseHandle(g_hSerial);
        g_hSerial = INVALID_HANDLE_VALUE;
        return -1;
    }
    
    dcb.BaudRate = baudRate;
    dcb.ByteSize = 8;
    dcb.StopBits = ONESTOPBIT;
    dcb.Parity = NOPARITY;
    dcb.fBinary = TRUE;
    dcb.fDtrControl = DTR_CONTROL_DISABLE;
    dcb.fRtsControl = RTS_CONTROL_DISABLE;
    
    if (!SetCommState(g_hSerial, &dcb)) {
        CloseHandle(g_hSerial);
        g_hSerial = INVALID_HANDLE_VALUE;
        return -1;
    }
    
    SetupComm(g_hSerial, 1, 1);
    
    COMMTIMEOUTS timeouts = {0};
    timeouts.ReadIntervalTimeout = MAXDWORD;
    timeouts.ReadTotalTimeoutMultiplier = 0;
    timeouts.ReadTotalTimeoutConstant = 0;
    timeouts.WriteTotalTimeoutMultiplier = 0;
    timeouts.WriteTotalTimeoutConstant = 0;
    SetCommTimeouts(g_hSerial, &timeouts);
    
    PurgeComm(g_hSerial, PURGE_RXCLEAR | PURGE_TXCLEAR);
    
    return 0;
}

void nsr_close_port() {
    // nsr_stop_reading() already closes g_hSerial and waits for thread
    nsr_stop_reading();
}

int nsr_set_config(int dataBits, int stopBits, int parity) {
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
    if (g_hSerial == INVALID_HANDLE_VALUE) return;
    EscapeCommFunction(g_hSerial, on ? SETRTS : CLRRTS);
}

void nsr_set_dtr(int on) {
    if (g_hSerial == INVALID_HANDLE_VALUE) return;
    EscapeCommFunction(g_hSerial, on ? SETDTR : CLRDTR);
}

int nsr_start_reading(int64_t dartPort, int timeoutMs) {
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
    
    // Close serial handle to force ReadFile/WaitForSingleObject to return error
    // so the read thread can exit the while loop
    HANDLE hTemp = g_hSerial;
    g_hSerial = INVALID_HANDLE_VALUE;
    if (hTemp != INVALID_HANDLE_VALUE) {
        CloseHandle(hTemp);
    }
    
    // Safely join the read thread with timeout
    if (g_readThread.joinable()) {
        // Wait up to 500ms for the thread to finish
        auto start = std::chrono::steady_clock::now();
        while (g_readThread.joinable()) {
            auto elapsed = std::chrono::steady_clock::now() - start;
            if (std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count() > 500) {
                // Thread didn't exit in time - this shouldn't happen but
                // we detach to avoid std::terminate() on thread destruction
                g_readThread.detach();
                break;
            }
            // Yield and retry
            Sleep(10);
        }
        if (g_readThread.joinable()) {
            g_readThread.join();
        }
    }
    
    // Clear Dart Port AFTER thread is done, to ensure no more Dart_PostCObject_DL calls
    g_dartPort = 0;
}

int nsr_write(const uint8_t* data, int length) {
    if (g_hSerial == INVALID_HANDLE_VALUE) return -1;
    
    DWORD bytesWritten = 0;
    OVERLAPPED ov = {0};
    ov.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    
    BOOL result = WriteFile(g_hSerial, data, length, &bytesWritten, &ov);
    
    if (!result && GetLastError() == ERROR_IO_PENDING) {
        if (WaitForSingleObject(ov.hEvent, 1000) == WAIT_OBJECT_0) {
            GetOverlappedResult(g_hSerial, &ov, &bytesWritten, FALSE);
            result = TRUE;
        }
    }
    
    CloseHandle(ov.hEvent);
    
    return result ? (int)bytesWritten : -1;
}

int nsr_is_open() {
    return g_hSerial != INVALID_HANDLE_VALUE ? 1 : 0;
}
