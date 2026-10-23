import Foundation
import Darwin

struct MacFocusProcessWitness: Equatable {
  let pid: pid_t
  let startSeconds: UInt64
  let startMicros: UInt64
  let path: String

  init(_ pid: pid_t) throws {
    var info = proc_bsdinfo()
    let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
    guard count == MemoryLayout.size(ofValue: info), info.pbi_pid == UInt32(pid),
          info.pbi_uid == geteuid(), info.pbi_ruid == getuid(), info.pbi_start_tvsec > 0 else {
      throw MacFocusFailure("application_changed")
    }
    // PROC_PIDPATHINFO_MAXSIZE is a compound macro not imported by Swift.
    var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else {
      throw MacFocusFailure("application_changed")
    }
    self.pid = pid
    self.startSeconds = info.pbi_start_tvsec
    self.startMicros = info.pbi_start_tvusec
    self.path = URL(fileURLWithPath: String(cString: bytes)).resolvingSymlinksInPath().standardizedFileURL.path
  }
}
