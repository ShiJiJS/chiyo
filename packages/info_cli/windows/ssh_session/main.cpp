#include <windows.h>
#include <sddl.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Data.Json.h>
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {
using Bytes = std::vector<BYTE>;
using winrt::Windows::Data::Json::JsonObject;
using winrt::Windows::Data::Json::JsonValue;
constexpr DWORD kLimit = 1024 * 1024;
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  Handle() = default;
  explicit Handle(HANDLE h) : value(h) {}
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
};
struct EnvironmentKeyLess {
  bool operator()(const std::wstring& left, const std::wstring& right) const {
    return CompareStringOrdinal(left.data(), static_cast<int>(left.size()), right.data(),
        static_cast<int>(right.size()), TRUE) == CSTR_LESS_THAN;
  }
};
bool Read(HANDLE h, BYTE* data, DWORD size) {
  while (size) {
    DWORD n = 0;
    if (!ReadFile(h, data, size, &n, nullptr) || !n) return false;
    data += n; size -= n;
  }
  return true;
}
bool Write(HANDLE h, const BYTE* data, DWORD size) {
  while (size) {
    DWORD n = 0;
    if (!WriteFile(h, data, size, &n, nullptr) || !n) return false;
    data += n; size -= n;
  }
  return true;
}
bool ReadFrame(HANDLE h, Bytes& bytes) {
  BYTE head[4];
  if (!Read(h, head, 4)) return false;
  DWORD size = head[0] | (DWORD(head[1]) << 8) | (DWORD(head[2]) << 16) | (DWORD(head[3]) << 24);
  if (!size || size > kLimit) return false;
  bytes.resize(size);
  return Read(h, bytes.data(), size);
}
bool WriteFrame(HANDLE h, const BYTE* bytes, DWORD size) {
  BYTE head[]{BYTE(size), BYTE(size >> 8), BYTE(size >> 16), BYTE(size >> 24)};
  return size && size <= kLimit && Write(h, head, 4) && Write(h, bytes, size);
}
std::wstring Wide(const std::string& text) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (!n) return {};
  std::wstring result(n, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), n);
  return result;
}
std::string Utf8(const std::wstring& text) {
  return winrt::to_string(winrt::hstring(text));
}
std::wstring Env(const wchar_t* name) {
  DWORD n = GetEnvironmentVariableW(name, nullptr, 0);
  if (!n) return {};
  std::wstring result(n, L'\0');
  GetEnvironmentVariableW(name, result.data(), n); result.resize(n - 1); return result;
}
std::wstring Image(HANDLE process) {
  std::wstring path(32768, L'\0'); DWORD n = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &n)) return {};
  path.resize(n); return path;
}
uint64_t Identity(HANDLE process) {
  FILETIME c{}, e{}, k{}, u{};
  if (!GetProcessTimes(process, &c, &e, &k, &u)) return 0;
  return (uint64_t(c.dwHighDateTime) << 32) | c.dwLowDateTime;
}
bool SameFile(const std::wstring& left, const std::wstring& right) {
  Handle a(CreateFileW(left.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr));
  Handle b(CreateFileW(right.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr));
  BY_HANDLE_FILE_INFORMATION ai{}, bi{};
  return GetFileInformationByHandle(a.value, &ai) && GetFileInformationByHandle(b.value, &bi) &&
      ai.dwVolumeSerialNumber == bi.dwVolumeSerialNumber && ai.nFileIndexHigh == bi.nFileIndexHigh && ai.nFileIndexLow == bi.nFileIndexLow;
}
DWORD Parent(DWORD pid) {
  Handle snap(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  PROCESSENTRY32W entry{}; entry.dwSize = sizeof(entry);
  if (Process32FirstW(snap.value, &entry)) do {
    if (entry.th32ProcessID == pid) return entry.th32ParentProcessID;
  } while (Process32NextW(snap.value, &entry));
  return 0;
}
std::wstring Random() {
  BYTE bytes[16];
  if (BCryptGenRandom(nullptr, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) return {};
  std::wstring text;
  for (BYTE b : bytes) { text += L"0123456789abcdef"[b >> 4]; text += L"0123456789abcdef"[b & 15]; }
  return text;
}
// Windows command-line quoting, including empty arguments and trailing slashes.
std::wstring Quote(const std::wstring& arg) {
  std::wstring result = L"\""; size_t slashes = 0;
  for (wchar_t c : arg) {
    if (c == L'\\') { ++slashes; continue; }
    result.append(c == L'"' ? slashes * 2 + 1 : slashes, L'\\');
    result += c; slashes = 0;
  }
  result.append(slashes * 2, L'\\'); result += L'"'; return result;
}
std::wstring Category(std::wstring prompt) {
  std::transform(prompt.begin(), prompt.end(), prompt.begin(), [](wchar_t c) { return wchar_t(towlower(c)); });
  while (!prompt.empty() && prompt.back() == L' ') prompt.pop_back();
  // Only OpenSSH's password-authentication prompt. Keyboard-interactive/MFA and
  // key passphrases must not receive a password by guessing from "Password:".
  const std::wstring suffix = L"'s password:";
  if (prompt.size() > suffix.size() && prompt.compare(prompt.size() - suffix.size(), suffix.size(), suffix) == 0 &&
      prompt.find(L'@') != std::wstring::npos && prompt.find_first_of(L"\r\n") == std::wstring::npos) return L"password";
  return L"unsupported";
}
int Askpass(const std::wstring& prompt) {
  const auto name = Env(L"CHIYO_SSH_ASKPASS_PIPE");
  if (name.rfind(L"\\\\.\\pipe\\chiyo-ssh-", 0) != 0) return 1;
  Handle pipe(CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr));
  ULONG serverPid = 0;
  const DWORD sshPid = Parent(GetCurrentProcessId());
  GetNamedPipeServerProcessId(pipe.value, &serverPid);
  Handle server(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, serverPid));
  Handle ssh(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, sshPid));
  if (!serverPid || Parent(sshPid) != serverPid ||
      WaitForSingleObject(server.value, 0) != WAIT_TIMEOUT || WaitForSingleObject(ssh.value, 0) != WAIT_TIMEOUT ||
      !Identity(server.value) || Identity(server.value) > Identity(ssh.value) ||
      !SameFile(Image(server.value), Image(GetCurrentProcess()))) return 1;
  const std::string category = Utf8(Category(prompt));
  if (!WriteFrame(pipe.value, reinterpret_cast<const BYTE*>(category.data()), static_cast<DWORD>(category.size()))) return 1;
  Bytes reply;
  if (!ReadFrame(pipe.value, reply) || reply[0] != 1) return 1;
  bool valid = reply.size() <= 65537 && std::find(reply.begin() + 1, reply.end(), '\n') == reply.end() &&
      std::find(reply.begin() + 1, reply.end(), '\r') == reply.end() && std::find(reply.begin() + 1, reply.end(), 0) == reply.end();
  bool ok = valid && Write(GetStdHandle(STD_OUTPUT_HANDLE), reply.data() + 1, static_cast<DWORD>(reply.size() - 1)) &&
      Write(GetStdHandle(STD_OUTPUT_HANDLE), reinterpret_cast<const BYTE*>("\n"), 1);
  SecureZeroMemory(reply.data(), reply.size()); return ok ? 0 : 1;
}
struct State {
  HANDLE ssh = nullptr, auth = nullptr;
  std::atomic<HANDLE> input{nullptr};
  DWORD pid = 0;
  uint64_t identity = 0;
  std::wstring helper;
  std::atomic<bool> stopped{false};
  std::mutex outputMutex, replyMutex, inputMutex;
  std::condition_variable replyReady, inputReady;
  std::deque<Bytes> inputQueue;
  size_t queuedBytes = 0;
  bool inputEof = false;
  std::string pending;
  Bytes reply;
  bool answered = false;
  void Emit(BYTE type, const BYTE* bytes, DWORD size) {
    std::lock_guard<std::mutex> lock(outputMutex);
    Bytes frame{type}; if (size) frame.insert(frame.end(), bytes, bytes + size);
    WriteFrame(GetStdHandle(STD_OUTPUT_HANDLE), frame.data(), static_cast<DWORD>(frame.size()));
  }
  void Text(BYTE type, const std::string& text) { Emit(type, reinterpret_cast<const BYTE*>(text.data()), static_cast<DWORD>(text.size())); }
  void Error(const char* code) { Text(0x15, code); }
  bool Live() { return !stopped && WaitForSingleObject(ssh, 0) == WAIT_TIMEOUT && Identity(ssh) == identity; }
};
bool Verified(const std::shared_ptr<State>& state, HANDLE helper, DWORD pid) {
  return state->Live() && WaitForSingleObject(helper, 0) == WAIT_TIMEOUT &&
      Parent(pid) == state->pid && Identity(helper) >= state->identity && SameFile(Image(helper), state->helper);
}
void Authentication(std::shared_ptr<State> state) {
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  bool used = false;
  while (!state->stopped) {
    if (!ConnectNamedPipe(state->auth, nullptr) && GetLastError() != ERROR_PIPE_CONNECTED) break;
    ULONG client = 0;
    GetNamedPipeClientProcessId(state->auth, &client);
    Handle helper(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, client));
    Bytes request, reply{0};
    if (Verified(state, helper.value, client) && ReadFrame(state->auth, request)) {
      const std::string category(request.begin(), request.end());
      if (category != "password") state->Error("ssh_login_challenge_unsupported");
      else if (used) state->Error("ssh_login_challenge_repeated");
      else {
        used = true;
        const std::string id = Utf8(Random());
        if (id.empty()) { state->Error("ssh_challenge_identity_failed"); break; }
        JsonObject challenge;
        challenge.SetNamedValue(L"challengeId", JsonValue::CreateStringValue(Wide(id)));
        challenge.SetNamedValue(L"processId", JsonValue::CreateNumberValue(state->pid));
        challenge.SetNamedValue(L"processIdentity", JsonValue::CreateStringValue(std::to_wstring(state->identity)));
        challenge.SetNamedValue(L"category", JsonValue::CreateStringValue(L"password"));
        {
          std::lock_guard<std::mutex> lock(state->replyMutex);
          state->pending = id; state->answered = false;
        }
        state->Text(0x13, Utf8(std::wstring(challenge.Stringify())));
        std::unique_lock<std::mutex> lock(state->replyMutex);
        state->replyReady.wait(lock, [&] { return state->answered || state->stopped; });
        if (state->answered && Verified(state, helper.value, client)) reply.swap(state->reply);
        state->pending.clear();
        if (!state->reply.empty()) SecureZeroMemory(state->reply.data(), state->reply.size());
        state->reply.clear();
      }
    }
    WriteFrame(state->auth, reply.data(), static_cast<DWORD>(reply.size()));
    SecureZeroMemory(reply.data(), reply.size());
    FlushFileBuffers(state->auth);
    DisconnectNamedPipe(state->auth);
  }
}
void Input(std::shared_ptr<State> state) {
  // Dart's stdio pipe can be opened for overlapped I/O by its creator. Polling
  // availability avoids an uncancellable synchronous read during job shutdown.
  auto read = [&](BYTE* bytes, DWORD size) {
    while (size && !state->stopped) {
      DWORD available = 0, received = 0;
      if (!PeekNamedPipe(GetStdHandle(STD_INPUT_HANDLE), nullptr, 0, nullptr, &available, nullptr)) return false;
      if (!available) { Sleep(2); continue; }
      DWORD count = (std::min)(available, size);
      if (!ReadFile(GetStdHandle(STD_INPUT_HANDLE), bytes, count, &received, nullptr) || !received) return false;
      bytes += received; size -= received;
    }
    return size == 0;
  };
  Bytes frame;
  while (!state->stopped) {
    BYTE head[4];
    if (!read(head, 4)) break;
    DWORD size = head[0] | (DWORD(head[1]) << 8) | (DWORD(head[2]) << 16) | (DWORD(head[3]) << 24);
    if (!size || size > kLimit) break;
    frame.resize(size);
    if (!read(frame.data(), size)) break;
    BYTE kind = frame[0];
    if (kind == 2) {
      std::lock_guard<std::mutex> lock(state->inputMutex);
      if (state->inputEof || state->queuedBytes + frame.size() > kLimit) {
        state->Error("ssh_input_backpressure"); break;
      }
      state->inputQueue.emplace_back(frame.begin() + 1, frame.end());
      state->queuedBytes += frame.size() - 1;
      state->inputReady.notify_one();
    } else if (kind == 3) {
      std::lock_guard<std::mutex> lock(state->inputMutex);
      state->inputEof = true; state->inputReady.notify_one();
    }
    else if (kind == 4) { TerminateProcess(state->ssh, 255); break; }
    else if (kind == 5 && frame.size() >= 34) {
      std::lock_guard<std::mutex> lock(state->replyMutex);
      const std::string id(frame.begin() + 1, frame.begin() + 33);
      if (!state->pending.empty() && id == state->pending && !state->answered) {
        state->reply.assign(frame.begin() + 33, frame.end());
        state->answered = true; state->replyReady.notify_one();
      }
    } else break;
    SecureZeroMemory(frame.data(), frame.size());
  }
  if (!frame.empty()) SecureZeroMemory(frame.data(), frame.size());
  if (state->Live()) TerminateProcess(state->ssh, 255);
}
void SshInput(std::shared_ptr<State> state) {
  // SSH may not consume stdin until authentication finishes. Never let that
  // backpressure block the independent ASKPASS response/control reader.
  while (!state->stopped) {
    Bytes bytes;
    {
      std::unique_lock<std::mutex> lock(state->inputMutex);
      state->inputReady.wait(lock, [&] { return state->stopped || state->inputEof || !state->inputQueue.empty(); });
      if (state->stopped) break;
      if (state->inputQueue.empty() && state->inputEof) {
        CloseHandle(state->input.exchange(nullptr)); return;
      }
      bytes.swap(state->inputQueue.front()); state->inputQueue.pop_front();
      state->queuedBytes -= bytes.size();
    }
    bool ok = Write(state->input.load(), bytes.data(), static_cast<DWORD>(bytes.size()));
    if (!bytes.empty()) SecureZeroMemory(bytes.data(), bytes.size());
    if (!ok) { if (state->Live()) TerminateProcess(state->ssh, 255); break; }
  }
  std::lock_guard<std::mutex> lock(state->inputMutex);
  for (auto& bytes : state->inputQueue) if (!bytes.empty()) SecureZeroMemory(bytes.data(), bytes.size());
  state->inputQueue.clear(); state->queuedBytes = 0;
}
void Pump(std::shared_ptr<State> state, HANDLE pipe, BYTE type) {
  BYTE bytes[32768]; DWORD count = 0;
  while (ReadFile(pipe, bytes, sizeof(bytes), &count, nullptr) && count) state->Emit(type, bytes, count);
}
int Broker() {
  auto state = std::make_shared<State>();
  Bytes frame;
  if (!ReadFrame(GetStdHandle(STD_INPUT_HANDLE), frame) || frame[0] != 1) return 2;
  JsonObject launch;
  if (!JsonObject::TryParse(Wide(std::string(frame.begin() + 1, frame.end())), launch)) return 2;
  const std::wstring executable(launch.GetNamedString(L"executable"));
  if (executable.size() < 3 || executable[1] != L':' || executable.find(L'\0') != std::wstring::npos) return 2;
  std::wstring command = Quote(executable);
  for (auto arg : launch.GetNamedArray(L"arguments")) command += L" " + Quote(std::wstring(arg.GetString()));
  state->helper = Image(GetCurrentProcess());
  // Keep the image path pinned while authenticating child image identities.
  Handle helperImage(CreateFileW(state->helper.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING, 0, nullptr));
  const auto nonce = Random();
  if (helperImage.value == INVALID_HANDLE_VALUE || nonce.empty()) return 2;
  auto pipeName = L"\\\\.\\pipe\\chiyo-ssh-" + nonce;
  Handle token; OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token.value);
  DWORD size = 0; GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
  Bytes user(size);
  if (!GetTokenInformation(token.value, TokenUser, user.data(), size, &size)) return 2;
  LPWSTR sid = nullptr;
  if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(user.data())->User.Sid, &sid)) return 2;
  std::wstring sddl = L"D:P(A;;GA;;;" + std::wstring(sid) + L")"; LocalFree(sid);
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) return 2;
  SECURITY_ATTRIBUTES privateAttributes{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
  Handle auth(CreateNamedPipeW(pipeName.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 4096, 0, &privateAttributes));
  LocalFree(descriptor);
  if (auth.value == INVALID_HANDLE_VALUE) return 2;
  state->auth = auth.value;
  std::map<std::wstring, std::wstring, EnvironmentKeyLess> environment;
  LPWCH block = GetEnvironmentStringsW();
  for (LPWCH p = block; p && *p; p += wcslen(p) + 1) {
    std::wstring pair(p); auto separator = pair.find(L'=', pair[0] == L'=' ? 1 : 0);
    if (separator != std::wstring::npos) environment[pair.substr(0, separator)] = pair.substr(separator + 1);
  }
  FreeEnvironmentStringsW(block);
  for (const auto& pair : launch.GetNamedObject(L"environment")) environment[std::wstring(pair.Key())] = std::wstring(pair.Value().GetString());
  // Environment keys are case insensitive on Windows. Remove aliases before
  // applying the forced private ASKPASS configuration.
  for (auto it = environment.begin(); it != environment.end();) {
    auto key = it->first;
    std::transform(key.begin(), key.end(), key.begin(), [](wchar_t c) { return wchar_t(towupper(c)); });
    if (key == L"SSH_ASKPASS" || key == L"SSH_ASKPASS_REQUIRE" || key == L"CHIYO_SSH_ASKPASS_PIPE") it = environment.erase(it); else ++it;
  }
  environment[L"SSH_ASKPASS"] = state->helper;
  environment[L"SSH_ASKPASS_REQUIRE"] = L"force";
  environment[L"CHIYO_SSH_ASKPASS_PIPE"] = pipeName;
  std::wstring env;
  for (const auto& pair : environment) { env += pair.first + L"=" + pair.second; env += L'\0'; }
  env += L'\0';
  SECURITY_ATTRIBUTES inherit{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
  Handle input, childInput, output, childOutput, errors, childErrors;
  if (!CreatePipe(&childInput.value, &input.value, &inherit, 0) || !CreatePipe(&output.value, &childOutput.value, &inherit, 0) ||
      !CreatePipe(&errors.value, &childErrors.value, &inherit, 0)) return 2;
  SetHandleInformation(input.value, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(output.value, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(errors.value, HANDLE_FLAG_INHERIT, 0);
  STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = childInput.value;
  startup.StartupInfo.hStdOutput = childOutput.value;
  startup.StartupInfo.hStdError = childErrors.value;
  SIZE_T attributeSize = 0; InitializeProcThreadAttributeList(nullptr, 1, 0, &attributeSize);
  Bytes attributes(attributeSize);
  startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributeSize)) return 2;
  HANDLE handles[]{childInput.value, childOutput.value, childErrors.value};
  bool assigned = UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), nullptr, nullptr) != FALSE;
  PROCESS_INFORMATION process{};
  bool created = assigned && CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT,
      env.data(), nullptr, &startup.StartupInfo, &process) != FALSE;
  DeleteProcThreadAttributeList(startup.lpAttributeList);
  if (!created) { state->Error("ssh_process_start_failed"); return 2; }
  Handle ssh(process.hProcess), thread(process.hThread), job(CreateJobObjectW(nullptr, nullptr));
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{}; limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job.value, JobObjectExtendedLimitInformation, &limits, sizeof(limits)) || !AssignProcessToJobObject(job.value, ssh.value)) {
    TerminateProcess(ssh.value, 255); state->Error("ssh_process_job_failed"); return 2;
  }
  state->ssh = ssh.value; state->pid = process.dwProcessId; state->identity = Identity(ssh.value); state->input = input.value;
  if (!state->identity) { TerminateProcess(ssh.value, 255); return 2; }
  CloseHandle(childInput.value); childInput.value = INVALID_HANDLE_VALUE;
  CloseHandle(childOutput.value); childOutput.value = INVALID_HANDLE_VALUE;
  CloseHandle(childErrors.value); childErrors.value = INVALID_HANDLE_VALUE;
  std::thread authentication(Authentication, state);
  std::thread stdoutThread(Pump, state, output.value, BYTE(0x11));
  std::thread stderrThread(Pump, state, errors.value, BYTE(0x12));
  state->Text(0x10, std::to_string(state->pid));
  std::thread inputThread(Input, state);
  std::thread sshInputThread(SshInput, state);
  ResumeThread(thread.value);
  WaitForSingleObject(ssh.value, INFINITE);
  state->stopped = true; state->replyReady.notify_one(); state->inputReady.notify_one();
  // Repeat cancellation to cover a thread moving from an identity check into a
  // synchronous pipe read while shutdown starts. No thread outlives its handles.
  for (HANDLE worker : {authentication.native_handle(), inputThread.native_handle(), sshInputThread.native_handle()}) {
    while (WaitForSingleObject(worker, 10) == WAIT_TIMEOUT) CancelSynchronousIo(worker);
  }
  authentication.join(); inputThread.join(); sshInputThread.join();
  // Stop remaining ASKPASS children before draining output handles inherited by
  // those children. This job belongs solely to this transport.
  TerminateJobObject(job.value, 255);
  stdoutThread.join(); stderrThread.join();
  DWORD code = 255; GetExitCodeProcess(ssh.value, &code);
  BYTE result[]{BYTE(code), BYTE(code >> 8), BYTE(code >> 16), BYTE(code >> 24)};
  state->Emit(0x14, result, 4);
  if (!state->input.load()) input.value = INVALID_HANDLE_VALUE;
  return 0;
}
}  // namespace
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    int argc = 0; LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    bool broker = argc == 2 && std::wstring(argv[1]) == L"--broker";
    bool capabilities = argc == 2 && std::wstring(argv[1]) == L"--capabilities";
    std::wstring prompt = argc > 1 ? argv[1] : L""; LocalFree(argv);
    if (capabilities) {
      const std::string json = "{\"transport\":1,\"askpass\":1,\"headless\":true}\n";
      return Write(GetStdHandle(STD_OUTPUT_HANDLE), reinterpret_cast<const BYTE*>(json.data()), static_cast<DWORD>(json.size())) ? 0 : 2;
    }
    return broker ? Broker() : Askpass(prompt);
  } catch (...) { return 2; }
}
