import Foundation
import Darwin

let maximumFrame = 262144
func line(_ fd: Int32) -> Data? {
  var data = Data()
  var byte: UInt8 = 0
  while data.count < maximumFrame {
    let n = Darwin.read(fd, &byte, 1)
    if n != 1 { return nil }
    if byte == 10 { return data }
    data.append(byte)
  }
  return nil
}
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
  data.withUnsafeBytes { raw in
    var sent = 0
    while sent < raw.count {
      let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
      if n <= 0 { return false }
      sent += n
    }
    return true
  }
}
func json(_ value: [String: Any]) -> Data {
  var data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
  data.append(10)
  return data
}
func object(_ data: Data?) -> [String: Any]? {
  guard let data else { return nil }
  return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
struct Witness: Equatable {
  let pid: pid_t, parent: pid_t
  let seconds: UInt64, micros: UInt64
  let path: String
  init?(_ pid: pid_t) {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
          info.pbi_uid == geteuid(), info.pbi_ruid == getuid() else { return nil }
    var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
    self.pid = pid; parent = pid_t(info.pbi_ppid)
    seconds = info.pbi_start_tvsec; micros = info.pbi_start_tvusec
    path = URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().path
  }
  var identity: String { "\(seconds):\(micros)" }
}
func unixAddress(_ path: String) -> sockaddr_un? {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8) + [0]
  guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
  withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
  return address
}
func connectSocket(_ path: String) -> Int32? {
  guard var address = unixAddress(path) else { return nil }
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
  }
  if result != 0 { close(fd); return nil }
  return fd
}
if CommandLine.arguments == [CommandLine.arguments[0], "--capabilities"] {
  _ = writeAll(STDOUT_FILENO, json(["transport": 1, "askpass": 1, "headless": true])); exit(0)
}
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
if ProcessInfo.processInfo.environment["CHIYO_SSH_SOCKET"] != nil {
  // OpenSSH invokes this same binary as ASKPASS. Its stdout is OpenSSH's private
  // password pipe, never a terminal or the public protocol stream.
  guard let path = ProcessInfo.processInfo.environment["CHIYO_SSH_SOCKET"],
        let fd = connectSocket(path), CommandLine.arguments.count == 2,
        CommandLine.arguments[1].hasSuffix("'s password: ") else { exit(1) }
  defer { close(fd) }
  guard writeAll(fd, json(["category": "password"])),
        let reply = object(line(fd)), let value = reply["data"] as? String,
        let data = Data(base64Encoded: value), !data.contains(10), !data.contains(13), !data.contains(0) else { exit(1) }
  var password = data; password.append(10)
  guard writeAll(STDOUT_FILENO, password) else { exit(1) }
  exit(0)
}

// Foundation Process creates a child process group on Darwin. Use an explicit
// spawn group so broker death cannot make live SSH/ASKPASS consumers disappear
// from the registered group used for identity-bound material cleanup.
final class OwnedProcess {
  var executableURL: URL?
  var arguments: [String]?
  var environment: [String: String]?
  var standardInput: Pipe?
  var standardOutput: Pipe?
  var standardError: Pipe?
  private(set) var processIdentifier: pid_t = 0
  private let condition = NSCondition()
  private var running = false, reaping = false
  private var status: Int32 = 255
  var isRunning: Bool { condition.lock(); defer { condition.unlock() }; return running }
  var terminationStatus: Int32 { condition.lock(); defer { condition.unlock() }; return status }
  func run() throws {
    guard let path = executableURL?.path, let input = standardInput,
          let output = standardOutput, let error = standardError else {
      throw NSError(domain: "spawn", code: 1)
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
    posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, error.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attributes, getpgrp())
    let args = ([path] + (arguments ?? [])).map { strdup($0) } + [nil]
    let env = (environment ?? [:]).map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for pointer in args { free(pointer) }; for pointer in env { free(pointer) } }
    var child: pid_t = 0
    let result = args.withUnsafeBufferPointer { argv in
      env.withUnsafeBufferPointer { envp in
        posix_spawn(&child, path, &actions, &attributes,
          UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
      }
    }
    guard result == 0 else { throw NSError(domain: "spawn", code: Int(result)) }
    processIdentifier = child; running = true
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close(); try? error.fileHandleForWriting.close()
  }
  func terminate() { if isRunning { kill(processIdentifier, SIGTERM) } }
  func waitUntilExit() {
    condition.lock()
    if reaping { while running { condition.wait() }; condition.unlock(); return }
    if !running { condition.unlock(); return }
    reaping = true; condition.unlock()
    var value: Int32 = 0
    var result: pid_t
    repeat { result = waitpid(processIdentifier, &value, 0) } while result < 0 && errno == EINTR
    condition.lock()
    status = result < 0 ? 255 : ((value & 0x7f) == 0 ? (value >> 8) & 0xff : 128 + (value & 0x7f))
    running = false; condition.broadcast(); condition.unlock()
  }
}

final class Broker {
  let emitLock = NSLock(), stateLock = NSLock(), writerLock = NSLock()
  let writer = DispatchQueue(label: "chiyo.ssh.stdin")
  var queuedBytes = 0
  let process = OwnedProcess(), input = Pipe(), output = Pipe(), diagnostic = Pipe()
  var pending: [String: (DispatchSemaphore, Data?)] = [:]
  var witness: Witness?
  var authenticated = false
  var socketFD: Int32 = -1
  var root = ""
  func emit(_ value: [String: Any]) {
    emitLock.lock(); defer { emitLock.unlock() }
    _ = writeAll(STDOUT_FILENO, json(value))
  }
  func clean() {
    if socketFD >= 0 { shutdown(socketFD, SHUT_RDWR); close(socketFD); socketFD = -1 }
    if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }
  }
  func serve(_ client: Int32) {
    defer { close(client) }
    var peer: pid_t = 0
    var size = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0,
          let helper = Witness(peer), helper.path == executable,
          let expected = witness, helper.parent == expected.pid,
          Witness(expected.pid) == expected,
          object(line(client))?["category"] as? String == "password" else { return }
    stateLock.lock()
    if authenticated { stateLock.unlock(); return }
    authenticated = true
    let id = UUID().uuidString
    let ready = DispatchSemaphore(value: 0)
    pending[id] = (ready, nil)
    stateLock.unlock()
    emit(["type": "challenge", "challengeId": id, "processId": Int(expected.pid),
          "processIdentity": expected.identity, "category": "password"])
    _ = ready.wait(timeout: .now() + 120)
    stateLock.lock()
    let data = pending.removeValue(forKey: id)?.1
    stateLock.unlock()
    guard let data, Witness(expected.pid) == expected,
          Witness(peer) == helper else { return }
    _ = writeAll(client, json(["data": data.base64EncodedString()]))
  }
  func start(_ launch: [String: Any]) throws {
    guard let path = launch["executable"] as? String,
          let arguments = launch["arguments"] as? [String],
          var environment = launch["environment"] as? [String: String],
          path.hasPrefix("/"), arguments.contains("-T") else { throw NSError(domain: "invalid_launch", code: 1) }
    root = "/tmp/chiyo-ssh-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    let endpoint = root + "/askpass.sock"
    guard var address = unixAddress(endpoint) else { throw NSError(domain: "endpoint", code: 1) }
    socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0, listen(socketFD, 4) == 0 else { throw NSError(domain: "endpoint", code: 1) }
    chmod(endpoint, 0o600)
    environment["SSH_ASKPASS"] = executable
    environment["SSH_ASKPASS_REQUIRE"] = "force"
    environment["DISPLAY"] = "chiyo-ssh"
    environment["CHIYO_SSH_SOCKET"] = endpoint
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments; process.environment = environment
    process.standardInput = input; process.standardOutput = output; process.standardError = diagnostic
    try process.run()
    guard let child = Witness(process.processIdentifier), child.path == URL(fileURLWithPath: path).resolvingSymlinksInPath().path else {
      process.terminate(); throw NSError(domain: "process_identity", code: 1)
    }
    witness = child
    emit(["type": "started", "processId": Int(child.pid), "processIdentity": child.identity])
    DispatchQueue.global().async {
      while self.socketFD >= 0 {
        let client = accept(self.socketFD, nil, nil)
        if client < 0 { return }
        self.serve(client)
      }
    }
    let group = DispatchGroup()
    for (pipe, kind) in [(output, "output"), (diagnostic, "diagnostic")] {
      group.enter()
      DispatchQueue.global().async {
        defer { group.leave() }
        while true {
          let data = pipe.fileHandleForReading.availableData
          if data.isEmpty { return }
          self.emit(["type": kind, "data": data.base64EncodedString()])
        }
      }
    }
    DispatchQueue.global().async {
      self.process.waitUntilExit(); group.wait()
      self.emit(["type": "exit", "exitCode": Int(self.process.terminationStatus)])
      self.clean(); exit(0)
    }
  }
  func consume(_ value: [String: Any]) {
    switch value["type"] as? String {
    case "send":
      if let raw = value["data"] as? String, let data = Data(base64Encoded: raw) {
        writerLock.lock()
        if queuedBytes + data.count > 524288 {
          writerLock.unlock(); emit(["type": "failure", "code": "input_limit"])
          if process.isRunning { process.terminate() }; return
        }
        queuedBytes += data.count; writerLock.unlock()
        writer.async {
          try? self.input.fileHandleForWriting.write(contentsOf: data)
          self.writerLock.lock(); self.queuedBytes -= data.count; self.writerLock.unlock()
        }
      }
    case "credential":
      guard let id = value["challengeId"] as? String else { return }
      let data = (value["data"] as? String).flatMap { Data(base64Encoded: $0) }
      stateLock.lock()
      if let previous = pending[id] {
        pending[id] = (previous.0, data); previous.0.signal()
      }
      stateLock.unlock()
    case "close": writer.async { try? self.input.fileHandleForWriting.close() }
    case "terminate": if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close()
    default: break
    }
  }
}
signal(SIGPIPE, SIG_IGN)
// Establish the observable consumer group before reading the launch gate.
if setsid() < 0 { exit(70) }
let broker = Broker()
do {
  guard let launch = object(line(STDIN_FILENO)) else { exit(64) }
  try broker.start(launch)
  while let value = object(line(STDIN_FILENO)) { broker.consume(value) }
  if broker.process.isRunning { broker.process.terminate() }
  broker.process.waitUntilExit()
  broker.clean()
} catch {
  broker.emit(["type": "failure", "code": "transport_unavailable"])
  broker.clean(); exit(70)
}
