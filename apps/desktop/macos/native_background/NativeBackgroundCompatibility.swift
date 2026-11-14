import Foundation

/// Reviewed, helper-owned version evidence. No RPC, preference, Agent claim,
/// caller PID or discovery selector can add/replace these entries. Updating an
/// App/OS version requires a new compatibility test and a signed helper build.
enum MacNativeBackgroundCompatibility {
  static var profiles: [MacNativeBackgroundProfile] {
    guard let archive = try? MacFocusApplication(
      executable: "/System/Library/CoreServices/Applications/Archive Utility.app/Contents/MacOS/Archive Utility",
      sha256: "55c8ec614dea515f9dbee6f9a497885be5a471df9cc8ac0bf7d93fbbc8ac4761") else { return [] }
    return [MacNativeBackgroundProfile(application: archive,
      bundleIdentifier: "com.apple.archiveutility",
      codeRequirement: "cdhash H\"aca35fcbf10ed3cbbf506c03d2d6500b7ff274a6\"",
      windowIdentifiers: ["_NS:8"], fieldIdentifiers: ["_NS:280"],
      fieldLabels: ["_NS:280": "Archive password"], operatingSystemBuild: "26A434",
      contextIdentifiers: ["_NS:270"], requiredSecureFieldIdentifiers: ["_NS:280"],
      contextPatterns: ["_NS:270": "^请输入“[^\\r\\n]{1,255}”的密码。$"])]
  }
}
