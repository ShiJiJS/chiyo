import Foundation
import CoreGraphics
let args = CommandLine.arguments
 guard args.count == 2, let target = Int32(args[1]), target > 0 else { exit(64) }
let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
 guard let all = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { exit(70) }
let owned = all.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
let windows = owned.map { row -> [String: Any] in
 ["windowID": row[kCGWindowNumber as String] ?? -1,
  "onScreen": (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
  "layer": row[kCGWindowLayer as String] ?? -1]
}
let result: [String: Any] = ["pid": target, "readOnlyPublicCGWindowList": true, "windows": windows, "onScreenCount": windows.filter { $0["onScreen"] as? Bool == true }.count]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
