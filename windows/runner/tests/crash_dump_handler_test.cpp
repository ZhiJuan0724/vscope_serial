#include <windows.h>

#include <cstdio>
#include <string>

#include "../crash_dump_handler.h"

namespace {

std::wstring GetExecutablePath() {
  std::wstring path(32768, L'\0');
  const DWORD length =
      ::GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) {
    return L"";
  }
  path.resize(length);
  return path;
}

std::wstring ParentDirectory(const std::wstring& path) {
  const size_t separator = path.find_last_of(L"\\/");
  return separator == std::wstring::npos ? L"." : path.substr(0, separator);
}

bool HasContent(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA attributes = {};
  return ::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard,
                                &attributes) &&
         (attributes.nFileSizeHigh != 0 || attributes.nFileSizeLow != 0);
}

}  // namespace

int wmain(int argc, wchar_t* argv[]) {
  if (argc == 2 && std::wstring(argv[1]) == L"--child") {
    ::SetErrorMode(SEM_NOGPFAULTERRORBOX);
    InstallCrashDumpHandler();
    ::RaiseException(EXCEPTION_ACCESS_VIOLATION, 0, 0, nullptr);
    return 2;
  }

  const std::wstring executable_path = GetExecutablePath();
  if (executable_path.empty()) return 10;

  std::wstring command_line = L"\"" + executable_path + L"\" --child";
  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
  PROCESS_INFORMATION process_info = {};
  if (!::CreateProcessW(nullptr, command_line.data(), nullptr, nullptr, FALSE, 0,
                        nullptr, nullptr, &startup_info, &process_info)) {
    return 11;
  }

  const DWORD wait_result = ::WaitForSingleObject(process_info.hProcess, 10000);
  if (wait_result == WAIT_TIMEOUT) {
    ::TerminateProcess(process_info.hProcess, 12);
  }
  const DWORD child_process_id = process_info.dwProcessId;
  ::CloseHandle(process_info.hThread);
  ::CloseHandle(process_info.hProcess);
  if (wait_result != WAIT_OBJECT_0) return 12;

  const std::wstring dump_directory =
      ParentDirectory(executable_path) + L"\\crash_dumps";
  wchar_t pattern[32768] = {};
  swprintf_s(pattern, L"%ls\\vscope_crash_*_%lu.json",
             dump_directory.c_str(), child_process_id);
  WIN32_FIND_DATAW find_data = {};
  HANDLE find_handle = ::FindFirstFileW(pattern, &find_data);
  if (find_handle == INVALID_HANDLE_VALUE) return 13;
  ::FindClose(find_handle);

  const std::wstring metadata_path =
      dump_directory + L"\\" + find_data.cFileName;
  std::wstring dump_path = metadata_path;
  dump_path.replace(dump_path.size() - 5, 5, L".dmp");
  const bool valid = HasContent(metadata_path) && HasContent(dump_path);

  ::DeleteFileW(metadata_path.c_str());
  ::DeleteFileW(dump_path.c_str());
  ::RemoveDirectoryW(dump_directory.c_str());
  return valid ? 0 : 14;
}
