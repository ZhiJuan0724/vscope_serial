#include <windows.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <userenv.h>

#include <algorithm>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;

struct UpdatePlan {
  DWORD pid = 0;
  fs::path install_dir;
  fs::path payload_dir;
  std::wstring executable;
  fs::path result_file;
  fs::path cleanup_dir;
  fs::path rollback_dir;
  std::wstring rollback_channel;
  std::wstring current_version;
};

struct ManagedFile {
  fs::path relative_path;
  std::string sha256;
};

class ScopedUpdateMutex {
 public:
  ScopedUpdateMutex() {
    handle_ = CreateMutexW(nullptr, FALSE, L"Local\\vscope_serial_update_lock");
    if (!handle_) throw std::runtime_error("cannot create update lock");
    const DWORD result = WaitForSingleObject(handle_, 0);
    if (result != WAIT_OBJECT_0) {
      throw std::runtime_error("another update is already running");
    }
    owns_mutex_ = true;
  }

  ~ScopedUpdateMutex() {
    if (owns_mutex_) ReleaseMutex(handle_);
    if (handle_) CloseHandle(handle_);
  }

  ScopedUpdateMutex(const ScopedUpdateMutex&) = delete;
  ScopedUpdateMutex& operator=(const ScopedUpdateMutex&) = delete;

 private:
  HANDLE handle_ = nullptr;
  bool owns_mutex_ = false;
};

std::wstring ReadUtf8File(const fs::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("cannot open file");
  const std::string bytes(
      (std::istreambuf_iterator<char>(input)),
      std::istreambuf_iterator<char>());
  if (bytes.empty()) return {};
  const int length = MultiByteToWideChar(
      CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()), nullptr, 0);
  if (length <= 0) throw std::runtime_error("invalid utf-8");
  std::wstring result(length, L'\0');
  MultiByteToWideChar(
      CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()),
      result.data(), length);
  if (!result.empty() && result.front() == 0xFEFF) result.erase(result.begin());
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int length = WideCharToMultiByte(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      nullptr, 0, nullptr, nullptr);
  if (length <= 0) throw std::runtime_error("cannot encode utf-8");
  std::string result(length, '\0');
  WideCharToMultiByte(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      result.data(), length, nullptr, nullptr);
  return result;
}

std::string JsonEscape(const std::wstring& value) {
  std::string utf8 = WideToUtf8(value);
  std::string escaped;
  escaped.reserve(utf8.size());
  for (const char c : utf8) {
    if (c == '"' || c == '\\') escaped.push_back('\\');
    if (c == '\n' || c == '\r') {
      escaped.push_back(' ');
    } else {
      escaped.push_back(c);
    }
  }
  return escaped;
}

std::wstring JsonString(const std::wstring& json, const wchar_t* key) {
  const std::wregex pattern(
      std::wstring(L"\"") + key + L"\"\\s*:\\s*\"([^\"]*)\"");
  std::wsmatch match;
  if (!std::regex_search(json, match, pattern)) {
    throw std::runtime_error("missing json string");
  }
  const auto encoded = match[1].str();
  std::wstring decoded;
  decoded.reserve(encoded.size());
  bool escaped = false;
  for (const wchar_t value : encoded) {
    if (escaped) {
      switch (value) {
        case L'\\':
        case L'"':
        case L'/':
          decoded.push_back(value);
          break;
        case L'n':
          decoded.push_back(L'\n');
          break;
        case L'r':
          decoded.push_back(L'\r');
          break;
        case L't':
          decoded.push_back(L'\t');
          break;
        default:
          throw std::runtime_error("unsupported json escape");
      }
      escaped = false;
    } else if (value == L'\\') {
      escaped = true;
    } else {
      decoded.push_back(value);
    }
  }
  if (escaped) throw std::runtime_error("invalid json escape");
  return decoded;
}

std::wstring JsonStringOrEmpty(const std::wstring& json, const wchar_t* key) {
  try {
    return JsonString(json, key);
  } catch (...) {
    return {};
  }
}

DWORD JsonDword(const std::wstring& json, const wchar_t* key) {
  const std::wregex pattern(
      std::wstring(L"\"") + key + L"\"\\s*:\\s*(\\d+)");
  std::wsmatch match;
  if (!std::regex_search(json, match, pattern)) {
    throw std::runtime_error("missing json number");
  }
  return static_cast<DWORD>(std::stoul(match[1].str()));
}

UpdatePlan ParsePlan(const fs::path& path) {
  const auto json = ReadUtf8File(path);
  if (JsonDword(json, L"schemaVersion") != 1) {
    throw std::runtime_error("unsupported plan schema");
  }
  return {
      JsonDword(json, L"pid"),
      JsonString(json, L"installDir"),
      JsonString(json, L"payloadDir"),
      JsonString(json, L"executable"),
      JsonString(json, L"resultFile"),
      JsonString(json, L"cleanupDir"),
      JsonStringOrEmpty(json, L"rollbackDir"),
      JsonStringOrEmpty(json, L"rollbackChannel"),
      JsonStringOrEmpty(json, L"currentVersion"),
  };
}

std::vector<ManagedFile> ParseManagedFiles(const fs::path& path) {
  const auto json = ReadUtf8File(path);
  std::vector<ManagedFile> files;
  const std::wregex pattern(
      L"\\{\\s*\"path\"\\s*:\\s*\"([^\"]+)\"\\s*,\\s*"
      L"\"sha256\"\\s*:\\s*\"([a-fA-F0-9]{64})\"[^}]*\\}");
  for (auto it = std::wsregex_iterator(json.begin(), json.end(), pattern);
       it != std::wsregex_iterator(); ++it) {
    auto relative = fs::path((*it)[1].str()).lexically_normal();
    if (relative.is_absolute() || relative.empty()) {
      throw std::runtime_error("invalid managed file path");
    }
    for (const auto& part : relative) {
      if (part == L"..") throw std::runtime_error("unsafe managed file path");
    }
    std::wstring digest_w = (*it)[2].str();
    std::string digest;
    digest.reserve(digest_w.size());
    for (const wchar_t value : digest_w) {
      digest.push_back(static_cast<char>(value));
    }
    std::transform(
        digest.begin(), digest.end(), digest.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    files.push_back({relative, digest});
  }
  if (files.empty()) throw std::runtime_error("empty app-files manifest");
  return files;
}

std::string Sha256File(const fs::path& path) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD hash_object_size = 0;
  DWORD result_size = 0;
  DWORD hash_size = 0;
  std::vector<UCHAR> hash_object;
  std::vector<UCHAR> digest;

  auto check = [](NTSTATUS status) {
    if (status < 0) throw std::runtime_error("sha256 failure");
  };
  check(BCryptOpenAlgorithmProvider(
      &algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0));
  try {
    check(BCryptGetProperty(
        algorithm, BCRYPT_OBJECT_LENGTH,
        reinterpret_cast<PUCHAR>(&hash_object_size),
        sizeof(hash_object_size), &result_size, 0));
    check(BCryptGetProperty(
        algorithm, BCRYPT_HASH_LENGTH,
        reinterpret_cast<PUCHAR>(&hash_size),
        sizeof(hash_size), &result_size, 0));
    hash_object.resize(hash_object_size);
    digest.resize(hash_size);
    check(BCryptCreateHash(
        algorithm, &hash, hash_object.data(), hash_object_size,
        nullptr, 0, 0));

    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("cannot hash file");
    std::vector<char> buffer(1024 * 1024);
    while (input) {
      input.read(buffer.data(), static_cast<std::streamsize>(buffer.size()));
      const auto count = input.gcount();
      if (count > 0) {
        check(BCryptHashData(
            hash, reinterpret_cast<PUCHAR>(buffer.data()),
            static_cast<ULONG>(count), 0));
      }
    }
    check(BCryptFinishHash(hash, digest.data(), hash_size, 0));
  } catch (...) {
    if (hash) BCryptDestroyHash(hash);
    BCryptCloseAlgorithmProvider(algorithm, 0);
    throw;
  }
  BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);

  std::ostringstream output;
  output << std::hex << std::setfill('0');
  for (const auto value : digest) output << std::setw(2) << int(value);
  return output.str();
}

void WriteResult(
    const fs::path& path, bool success, const std::string& message) {
  fs::create_directories(path.parent_path());
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output << "{\"success\":" << (success ? "true" : "false")
         << ",\"message\":\"";
  for (const char c : message) {
    if (c == '"' || c == '\\') output << '\\';
    if (c == '\n' || c == '\r') {
      output << ' ';
    } else {
      output << c;
    }
  }
  output << "\"}";
}

bool CanWriteDirectory(const fs::path& directory) {
  const auto probe = directory / L".vscope-update-write-test";
  HANDLE handle = CreateFileW(
      probe.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
      FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
  if (handle == INVALID_HANDLE_VALUE) return false;
  CloseHandle(handle);
  return true;
}

void RelaunchElevated(const fs::path& plan_path) {
  wchar_t module[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, module, MAX_PATH);
  const std::wstring parameters =
      L"--plan \"" + plan_path.wstring() + L"\" --elevated";
  const auto result = reinterpret_cast<INT_PTR>(ShellExecuteW(
      nullptr, L"runas", module, parameters.c_str(), nullptr, SW_SHOWNORMAL));
  if (result <= 32) throw std::runtime_error("administrator permission denied");
}

void WaitForProcess(DWORD pid) {
  if (pid == 0) return;
  HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid);
  if (!process) return;
  const DWORD result = WaitForSingleObject(process, 30000);
  CloseHandle(process);
  if (result != WAIT_OBJECT_0) {
    throw std::runtime_error("application did not exit in time");
  }
}

std::wstring NormalizePathForCompare(const fs::path& path) {
  std::wstring value = fs::absolute(path).lexically_normal().wstring();
  std::replace(value.begin(), value.end(), L'/', L'\\');
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) {
    return static_cast<wchar_t>(std::towlower(c));
  });
  return value;
}

std::wstring ProcessImagePath(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return {};
  std::wstring path(32768, L'\0');
  DWORD size = static_cast<DWORD>(path.size());
  const BOOL ok = QueryFullProcessImageNameW(process, 0, path.data(), &size);
  CloseHandle(process);
  if (!ok || size == 0) return {};
  path.resize(size);
  return path;
}

bool HasRunningApplicationInstance(const fs::path& executable) {
  const auto expected = NormalizePathForCompare(executable);
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return false;

  PROCESSENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  bool found = false;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      const auto image = ProcessImagePath(entry.th32ProcessID);
      if (!image.empty() && NormalizePathForCompare(image) == expected) {
        found = true;
        break;
      }
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return found;
}

void CopyFileReplacing(const fs::path& source, const fs::path& destination) {
  fs::create_directories(destination.parent_path());
  const auto temporary = destination.wstring() + L".update-new";
  fs::copy_file(source, temporary, fs::copy_options::overwrite_existing);
  if (!MoveFileExW(
          temporary.c_str(), destination.c_str(),
          MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    fs::remove(temporary);
    throw std::runtime_error("cannot replace application file");
  }
}

std::wstring UtcTimestamp() {
  SYSTEMTIME time = {};
  GetSystemTime(&time);
  wchar_t buffer[32] = {};
  swprintf_s(
      buffer, L"%04d-%02d-%02dT%02d:%02d:%02dZ",
      time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
      time.wSecond);
  return buffer;
}

void SaveRollbackSlot(
    const UpdatePlan& plan,
    const fs::path& old_manifest_path,
    const std::vector<ManagedFile>& old_files) {
  if (plan.rollback_dir.empty() || plan.current_version.empty() ||
      !fs::exists(old_manifest_path) || old_files.empty()) {
    return;
  }

  const auto payload = plan.rollback_dir / L"payload";
  fs::remove_all(plan.rollback_dir);
  fs::create_directories(payload);
  fs::copy_file(
      old_manifest_path, payload / L"app-files.json",
      fs::copy_options::overwrite_existing);

  for (const auto& file : old_files) {
    const auto installed = plan.install_dir / file.relative_path;
    if (!fs::exists(installed)) continue;
    const auto backup = payload / file.relative_path;
    fs::create_directories(backup.parent_path());
    fs::copy_file(installed, backup, fs::copy_options::overwrite_existing);
  }

  {
    std::ofstream output(
        plan.rollback_dir / L"update-manifest.json",
        std::ios::binary | std::ios::trunc);
    output << "{\n"
           << "  \"schemaVersion\": 1,\n"
           << "  \"version\": \"" << JsonEscape(plan.current_version) << "\",\n"
           << "  \"packageName\": \"\",\n"
           << "  \"packageSize\": 0,\n"
           << "  \"sha256\": \"\",\n"
           << "  \"executable\": \"" << JsonEscape(plan.executable) << "\"\n"
           << "}\n";
  }
  {
    std::ofstream output(
        plan.rollback_dir / L"rollback.json",
        std::ios::binary | std::ios::trunc);
    output << "{\n"
           << "  \"schemaVersion\": 1,\n"
           << "  \"channel\": \"" << JsonEscape(plan.rollback_channel) << "\",\n"
           << "  \"version\": \"" << JsonEscape(plan.current_version) << "\",\n"
           << "  \"createdAt\": \"" << JsonEscape(UtcTimestamp()) << "\"\n"
           << "}\n";
  }
}

bool IsCurrentProcessElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION elevation = {};
  DWORD size = 0;
  const BOOL success = GetTokenInformation(
      token, TokenElevation, &elevation, sizeof(elevation), &size);
  CloseHandle(token);
  return success && elevation.TokenIsElevated != 0;
}

void RestartApplication(const fs::path& executable) {
  if (!IsCurrentProcessElevated()) {
    std::wstring command = L"\"" + executable.wstring() + L"\"";
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {};
    if (CreateProcessW(
            executable.c_str(), command.data(), nullptr, nullptr, FALSE, 0,
            nullptr, executable.parent_path().c_str(), &startup, &process)) {
      CloseHandle(process.hThread);
      CloseHandle(process.hProcess);
      return;
    }
  }

  const HWND shell_window = GetShellWindow();
  DWORD shell_pid = 0;
  if (shell_window) GetWindowThreadProcessId(shell_window, &shell_pid);
  if (shell_pid != 0) {
    HANDLE shell_process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, shell_pid);
    HANDLE shell_token = nullptr;
    HANDLE primary_token = nullptr;
    if (shell_process &&
        OpenProcessToken(
            shell_process, TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ASSIGN_PRIMARY,
            &shell_token) &&
        DuplicateTokenEx(
            shell_token, TOKEN_ALL_ACCESS, nullptr, SecurityImpersonation,
            TokenPrimary, &primary_token)) {
      void* environment = nullptr;
      CreateEnvironmentBlock(&environment, primary_token, FALSE);
      std::wstring command = L"\"" + executable.wstring() + L"\"";
      STARTUPINFOW startup = {};
      startup.cb = sizeof(startup);
      PROCESS_INFORMATION process = {};
      const BOOL created = CreateProcessWithTokenW(
          primary_token, LOGON_WITH_PROFILE, executable.c_str(),
          command.data(), CREATE_UNICODE_ENVIRONMENT, environment,
          executable.parent_path().c_str(), &startup, &process);
      if (environment) DestroyEnvironmentBlock(environment);
      if (created) {
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
      }
      CloseHandle(primary_token);
      CloseHandle(shell_token);
      CloseHandle(shell_process);
      if (created) return;
    } else {
      if (primary_token) CloseHandle(primary_token);
      if (shell_token) CloseHandle(shell_token);
      if (shell_process) CloseHandle(shell_process);
    }
  }

  SHELLEXECUTEINFOW info = {};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOCLOSEPROCESS;
  info.lpVerb = L"open";
  info.lpFile = executable.c_str();
  info.lpDirectory = executable.parent_path().c_str();
  info.nShow = SW_SHOWNORMAL;
  ShellExecuteExW(&info);
  if (info.hProcess) CloseHandle(info.hProcess);
}

void ApplyUpdate(const UpdatePlan& plan) {
  const auto installed_exe = plan.install_dir / plan.executable;
  if (!fs::exists(installed_exe) ||
      !fs::equivalent(installed_exe.parent_path(), plan.install_dir)) {
    throw std::runtime_error("invalid installation directory");
  }

  const auto new_manifest_path = plan.payload_dir / L"app-files.json";
  const auto old_manifest_path = plan.install_dir / L"app-files.json";
  const auto new_files = ParseManagedFiles(new_manifest_path);
  std::vector<ManagedFile> old_files;
  if (fs::exists(old_manifest_path)) {
    old_files = ParseManagedFiles(old_manifest_path);
  }
  SaveRollbackSlot(plan, old_manifest_path, old_files);

  const auto backup_dir = plan.cleanup_dir / L"backup";
  fs::remove_all(backup_dir);
  fs::create_directories(backup_dir);
  std::vector<fs::path> installed_paths;

  try {
    if (fs::exists(old_manifest_path)) {
      fs::copy_file(
          old_manifest_path, backup_dir / L"app-files.json",
          fs::copy_options::overwrite_existing);
    }
    for (const auto& file : old_files) {
      const auto installed = plan.install_dir / file.relative_path;
      if (fs::exists(installed)) {
        const auto backup = backup_dir / file.relative_path;
        fs::create_directories(backup.parent_path());
        fs::copy_file(installed, backup, fs::copy_options::overwrite_existing);
      }
    }
    for (const auto& file : new_files) {
      const auto installed = plan.install_dir / file.relative_path;
      const auto backup = backup_dir / file.relative_path;
      if (fs::exists(installed) && !fs::exists(backup)) {
        fs::create_directories(backup.parent_path());
        fs::copy_file(installed, backup, fs::copy_options::overwrite_existing);
      }
    }

    for (const auto& file : new_files) {
      const auto source = plan.payload_dir / file.relative_path;
      if (!fs::exists(source) || Sha256File(source) != file.sha256) {
        throw std::runtime_error("payload file hash mismatch");
      }
      const auto installed = plan.install_dir / file.relative_path;
      CopyFileReplacing(source, installed);
      installed_paths.push_back(file.relative_path);
    }
    CopyFileReplacing(new_manifest_path, old_manifest_path);
    installed_paths.push_back(L"app-files.json");

    std::map<std::wstring, bool> new_paths;
    for (const auto& file : new_files) {
      new_paths[file.relative_path.generic_wstring()] = true;
    }
    for (const auto& file : old_files) {
      if (!new_paths.count(file.relative_path.generic_wstring())) {
        fs::remove(plan.install_dir / file.relative_path);
      }
    }

    for (const auto& file : new_files) {
      if (Sha256File(plan.install_dir / file.relative_path) != file.sha256) {
        throw std::runtime_error("installed file hash mismatch");
      }
    }
  } catch (...) {
    for (const auto& relative : installed_paths) {
      fs::remove(plan.install_dir / relative);
    }
    if (fs::exists(backup_dir)) {
      for (const auto& entry : fs::recursive_directory_iterator(backup_dir)) {
        if (!entry.is_regular_file()) continue;
        const auto relative = fs::relative(entry.path(), backup_dir);
        const auto destination = plan.install_dir / relative;
        fs::create_directories(destination.parent_path());
        fs::copy_file(
            entry.path(), destination, fs::copy_options::overwrite_existing);
      }
    }
    throw;
  }

  fs::remove_all(backup_dir);
  fs::remove_all(plan.payload_dir);
  fs::remove(plan.cleanup_dir / L"package.zip");
  fs::remove(plan.cleanup_dir / L"prepared.json");
  WriteResult(plan.result_file, true, "Update installed successfully");
  RestartApplication(installed_exe);
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  fs::path plan_path;
  bool elevated = false;
  for (int i = 1; i < __argc; ++i) {
    const std::wstring argument = __wargv[i];
    if (argument == L"--plan" && i + 1 < __argc) {
      plan_path = __wargv[++i];
    } else if (argument == L"--elevated") {
      elevated = true;
    }
  }
  if (plan_path.empty()) return 2;

  UpdatePlan plan;
  try {
    plan = ParsePlan(plan_path);
    if (!elevated && !CanWriteDirectory(plan.install_dir)) {
      RelaunchElevated(plan_path);
      return 0;
    }
    ScopedUpdateMutex update_mutex;
    WaitForProcess(plan.pid);
    if (HasRunningApplicationInstance(plan.install_dir / plan.executable)) {
      throw std::runtime_error("other application instances are still running");
    }
    ApplyUpdate(plan);
    return 0;
  } catch (const std::exception& error) {
    if (!plan.result_file.empty()) {
      WriteResult(plan.result_file, false, error.what());
    }
    return 1;
  }
}
