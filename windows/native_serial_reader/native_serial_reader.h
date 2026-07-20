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

// 初始化 Dart API；必须在调用其它导出函数前完成。
// data：来自 Dart 的 NativeApi.initializeApiDLData。
// 返回 0 表示成功，-1 表示失败。
NSR_API int nsr_init_dart_api(void* data);

// 打开串口。
// portName 示例为 "COM3"，baudRate 示例为 115200。
// 返回 0 表示成功，-1 表示失败。
NSR_API int nsr_open_port(const char* portName, int baudRate);

// 关闭串口并释放当前读取周期的原生资源。
NSR_API void nsr_close_port();

// 设置串口参数。
// dataBits 范围为 5-8，stopBits 为 1 或 2，parity：0=无、1=奇、2=偶。
// 返回 0 表示成功，-1 表示失败。
NSR_API int nsr_set_config(int dataBits, int stopBits, int parity);

// 设置 RTS/DTR 线路状态。
NSR_API void nsr_set_rts(int on);
NSR_API void nsr_set_dtr(int on);

// 启动读取线程。
// dartPort 为 Dart SendPort 原生端口 ID；timeoutMs 是 ReadFile 超时毫秒数，0 表示阻塞。
// 返回 0 表示成功，-1 表示失败。
NSR_API int nsr_start_reading(int64_t dartPort, int timeoutMs);

// 取消未完成读取并等待读取线程退出。
NSR_API void nsr_stop_reading();

// 返回当前或最近一次完成的读取周期指标。
NSR_API void nsr_get_read_metrics(
    uint64_t* bytesRead,
    uint64_t* maxBlockBytes,
    uint64_t* callbackCount,
    uint64_t* postFailureCount);

// 向串口写入数据；返回实际写入字节数，-1 表示失败。
NSR_API int nsr_write(const uint8_t* data, int length);

// 检查原生串口句柄是否已打开。
NSR_API int nsr_is_open();

// 检查当前句柄是否仍响应 Windows 串口 API。USB 串口被拔出后句柄可能仍显示为打开。
NSR_API int nsr_is_connection_healthy();

// 枚举当前可用串口。
// buffer 为 NULL 或容量不足时返回所需字节数（包含末尾双 NUL）；
// 成功写入时同样返回实际字节数，失败返回负数。
NSR_API int nsr_list_ports(char* buffer, int capacity);

// 枚举串口及友好名称，仅在用户主动请求详细信息时调用。
// 每个 MultiSZ 项格式为 "COMx\t名称"；名称可能为空。
NSR_API int nsr_list_port_details(char* buffer, int capacity);

// 监听 Windows 串口设备到达和移除事件。
// 每次变化向 dartPort 投递整数 1，返回 0 表示成功。
NSR_API int nsr_start_port_monitor(int64_t dartPort);
NSR_API void nsr_stop_port_monitor();

#ifdef __cplusplus
}
#endif

#endif
