#ifndef NATIVE_SERIAL_READER_H
#define NATIVE_SERIAL_READER_H

#ifdef NATIVE_SERIAL_READER_EXPORTS
#define NSR_API __declspec(dllexport)
#else
#define NSR_API __declspec(dllimport)
#endif

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

// Initialize the Dart API (must be called before any other function)
// data: NativeApi.initializeApiDLData from Dart
// Returns: 0 on success, -1 on failure
NSR_API int nsr_init_dart_api(void* data);

// Open serial port
// portName: e.g. "COM3"// baudRate: e.g. 115200
// Returns: 0 on success, -1 on failure
NSR_API int nsr_open_port(const char* portName, int baudRate);

// Close serial port
NSR_API void nsr_close_port();

// Set serial config
// dataBits: 5-8
// stopBits: 1 or 2
// parity: 0=none, 1=odd, 2=even
// Returns: 0 on success, -1 on failure
NSR_API int nsr_set_config(int dataBits, int stopBits, int parity);

// Set RTS/DTR
NSR_API void nsr_set_rts(int on);
NSR_API void nsr_set_dtr(int on);

// Start reading thread
// dartPort: Dart SendPort native port id
// timeoutMs: ReadFile timeout in ms, 0 = blocking
// Returns: 0 on success, -1 on failure
NSR_API int nsr_start_reading(int64_t dartPort, int timeoutMs);

// Stop reading thread
NSR_API void nsr_stop_reading();

// Write data to serial port
// Returns: bytes written, -1 on failure
NSR_API int nsr_write(const uint8_t* data, int length);

// Check if port is open
NSR_API int nsr_is_open();

#ifdef __cplusplus
}
#endif

#endif
