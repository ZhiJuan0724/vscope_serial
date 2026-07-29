#include "crash_dump_handler.h"

#include <windows.h>
#include <dbghelp.h>

#include <cstdio>
#include <string>

namespace {

constexpr wchar_t kCrashDumpDirectoryName[] = L"crash_dumps";
constexpr wchar_t kSettingsDirectoryName[] = L"settings";
constexpr wchar_t kDisabledMarkerName[] = L"crash_dump.disabled";

// 防止异常处理或 DbgHelp 自身再次异常时递归写入转储。
volatile LONG g_dump_in_progress = 0;

std::wstring GetExecutableDirectory() {
  std::wstring path(32768, L'\0');
  const DWORD length =
      ::GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) {
    return L".";
  }
  path.resize(length);
  const size_t separator = path.find_last_of(L"\\/");
  return separator == std::wstring::npos ? L"." : path.substr(0, separator);
}

std::wstring JoinPath(const std::wstring& directory, const wchar_t* name) {
  return directory + L"\\" + name;
}

bool IsCrashDumpEnabled(const std::wstring& executable_directory) {
  const std::wstring marker =
      JoinPath(JoinPath(executable_directory, kSettingsDirectoryName),
               kDisabledMarkerName);
  return ::GetFileAttributesW(marker.c_str()) == INVALID_FILE_ATTRIBUTES;
}

bool WriteBytes(const std::wstring& path, const char* bytes, DWORD length) {
  HANDLE file =
      ::CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  DWORD written = 0;
  const BOOL succeeded = ::WriteFile(file, bytes, length, &written, nullptr);
  ::FlushFileBuffers(file);
  ::CloseHandle(file);
  return succeeded && written == length;
}

LONG WINAPI HandleUnhandledException(EXCEPTION_POINTERS* exception_pointers) {
  if (::InterlockedCompareExchange(&g_dump_in_progress, 1, 0) != 0) {
    return EXCEPTION_CONTINUE_SEARCH;
  }

  const std::wstring executable_directory = GetExecutableDirectory();
  if (!IsCrashDumpEnabled(executable_directory)) {
    return EXCEPTION_CONTINUE_SEARCH;
  }

  const std::wstring dump_directory =
      JoinPath(executable_directory, kCrashDumpDirectoryName);
  if (!::CreateDirectoryW(dump_directory.c_str(), nullptr) &&
      ::GetLastError() != ERROR_ALREADY_EXISTS) {
    return EXCEPTION_CONTINUE_SEARCH;
  }

  SYSTEMTIME utc_time = {};
  ::GetSystemTime(&utc_time);
  const DWORD process_id = ::GetCurrentProcessId();
  const DWORD thread_id = ::GetCurrentThreadId();

  wchar_t base_name[128] = {};
  swprintf_s(base_name, L"vscope_crash_%04u%02u%02u_%02u%02u%02u_%03u_%lu",
             utc_time.wYear, utc_time.wMonth, utc_time.wDay, utc_time.wHour,
             utc_time.wMinute, utc_time.wSecond, utc_time.wMilliseconds,
             process_id);

  const std::wstring dump_path =
      JoinPath(dump_directory, (std::wstring(base_name) + L".dmp").c_str());
  HANDLE dump_file =
      ::CreateFileW(dump_path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);

  BOOL dump_written = FALSE;
  DWORD dump_error = ERROR_SUCCESS;
  if (dump_file != INVALID_HANDLE_VALUE) {
    MINIDUMP_EXCEPTION_INFORMATION exception_information = {};
    exception_information.ThreadId = thread_id;
    exception_information.ExceptionPointers = exception_pointers;
    exception_information.ClientPointers = FALSE;
    const MINIDUMP_TYPE dump_type = static_cast<MINIDUMP_TYPE>(
        MiniDumpNormal | MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules);
    dump_written =
        ::MiniDumpWriteDump(::GetCurrentProcess(), process_id, dump_file,
                            dump_type, &exception_information, nullptr, nullptr);
    if (!dump_written) {
      dump_error = ::GetLastError();
    }
    ::FlushFileBuffers(dump_file);
    ::CloseHandle(dump_file);
    if (!dump_written) {
      ::DeleteFileW(dump_path.c_str());
    }
  } else {
    dump_error = ::GetLastError();
  }

  const DWORD exception_code =
      exception_pointers != nullptr &&
              exception_pointers->ExceptionRecord != nullptr
          ? exception_pointers->ExceptionRecord->ExceptionCode
          : 0;
  const void* exception_address =
      exception_pointers != nullptr &&
              exception_pointers->ExceptionRecord != nullptr
          ? exception_pointers->ExceptionRecord->ExceptionAddress
          : nullptr;

  char metadata[2048] = {};
  const int metadata_length = sprintf_s(
      metadata,
      "{\r\n"
      "  \"schemaVersion\": 1,\r\n"
      "  \"application\": \"SerialTools\",\r\n"
      "  \"version\": \"%s\",\r\n"
      "  \"timestampUtc\": \"%04u-%02u-%02uT%02u:%02u:%02u.%03uZ\",\r\n"
      "  \"processId\": %lu,\r\n"
      "  \"threadId\": %lu,\r\n"
      "  \"architecture\": \"x64\",\r\n"
      "  \"exceptionCode\": \"0x%08lX\",\r\n"
      "  \"exceptionAddress\": \"%p\",\r\n"
      "  \"dumpFile\": \"%ls.dmp\",\r\n"
      "  \"dumpWritten\": %s,\r\n"
      "  \"dumpError\": %lu,\r\n"
      "  \"dumpType\": \"normal+threadInfo+unloadedModules\",\r\n"
      "  \"logsDirectory\": \"../logs\"\r\n"
      "}\r\n",
      FLUTTER_VERSION, utc_time.wYear, utc_time.wMonth, utc_time.wDay,
      utc_time.wHour, utc_time.wMinute, utc_time.wSecond,
      utc_time.wMilliseconds, process_id, thread_id, exception_code,
      exception_address, base_name, dump_written ? "true" : "false",
      dump_error);

  if (metadata_length > 0) {
    const std::wstring metadata_path =
        JoinPath(dump_directory, (std::wstring(base_name) + L".json").c_str());
    WriteBytes(metadata_path, metadata, static_cast<DWORD>(metadata_length));
  }

  // 让 Windows 按原有未处理异常流程终止进程；这里只负责尽快留下证据。
  return EXCEPTION_EXECUTE_HANDLER;
}

}  // namespace

void InstallCrashDumpHandler() {
  ::SetUnhandledExceptionFilter(HandleUnhandledException);
}
