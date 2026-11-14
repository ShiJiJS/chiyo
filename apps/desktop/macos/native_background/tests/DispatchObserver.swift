import AppKit
import ApplicationServices
import Foundation
private func pump(_ seconds: Double) {
  let until = Date().addingTimeInterval(seconds)
  while Date() < until { RunLoop.current.run(until: min(until, Date().addingTimeInterval(0.005))) }
}
private struct Snapshot {
  let front: pid_t
  let field: AXUIElement?
  let fieldPID: pid_t
  let mouse: CGPoint
  let clipboard: Int
  init() {
    front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    var value: CFTypeRef?
    if front > 0 { _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(front), kAXFocusedUIElementAttribute as CFString, &value) }
    if let value, CFGetTypeID(value) == AXUIElementGetTypeID() { field = unsafeBitCast(value, to: AXUIElement.self) }
    else { field = nil }
    var pid: pid_t = -1
    if let field { AXUIElementGetPid(field, &pid) }
    fieldPID = pid; mouse = CGEvent(source: nil)!.location
    clipboard = NSPasteboard.general.changeCount
  }
  var valid: Bool { front > 0 && field != nil && fieldPID == front }
  var wire: [String: Any] { ["at": Date().timeIntervalSince1970, "uptime": ProcessInfo.processInfo.systemUptime, "front": front, "focusPID": fieldPID,
    "valid": valid, "focusHash": field.map { CFHash($0) } ?? 0, "x": mouse.x, "y": mouse.y, "clipboard": clipboard] }
  func same(_ other: Snapshot) -> Bool {
    guard valid, other.valid, let field, let otherField = other.field else { return false }
    return front == other.front && CFEqual(field, otherField) && mouse == other.mouse && clipboard == other.clipboard
  }
}
@main enum ObserveSignedDispatch {
 static func main() throws {
  _=NSApplication.shared
  let root=URL(fileURLWithPath:CommandLine.arguments[1]), gate=URL(fileURLWithPath:CommandLine.arguments[2])
  if CommandLine.arguments.contains("--passive") {
    let baseline = Snapshot(); var trace = [baseline.wire], same = baseline.valid
    try Data("ready".utf8).write(to:gate.appendingPathComponent("observer-ready"),options:.atomic)
    let deadline = Date().addingTimeInterval(12)
    while !FileManager.default.fileExists(atPath:gate.appendingPathComponent("dispatch-completed").path) && Date() < deadline {
      pump(0.002); let value = Snapshot(); trace.append(value.wire); same = same && baseline.same(value)
    }
    let last = Snapshot(); trace.append(last.wire); same = same && baseline.same(last)
    let receipt: [String: Any] = ["observationsPreserved":same,
      "completed": FileManager.default.fileExists(atPath:gate.appendingPathComponent("dispatch-completed").path), "trace":trace]
    try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted]).write(to:gate.appendingPathComponent("observer.json"))
    return
  }
  func command(_ action:String) throws {
   let id=UUID().uuidString
   try JSONSerialization.data(withJSONObject:["id":id,"action":action]).write(to:root.appendingPathComponent("cover-command.json"),options:.atomic)
   for _ in 0..<200{pump(0.01);if let d=try? Data(contentsOf:root.appendingPathComponent("cover-ack.json")),let c=(try? JSONSerialization.jsonObject(with:d)) as? [String:Any],c["id"] as? String==id{return}}
   throw MacNativeBackgroundFailure.targetUnavailable
  }
  try command("cover")
  let open=Process();open.executableURL=URL(fileURLWithPath:"/usr/bin/open");open.arguments=["-a",root.appendingPathComponent("NativeWorkCover.app").path];try open.run();open.waitUntilExit();pump(0.25)
  let n=Snapshot();var neg=true
  for _ in 0..<20{neg = neg && n.same(Snapshot());pump(0.01)}
  try command("focus-b");pump(0.1);let m=Snapshot();let pos=n.valid && m.valid && n.field.map{f in m.field.map{!CFEqual(f,$0)} ?? false}==true
  try command("cover");pump(0.1)
  guard neg,pos else{throw MacNativeBackgroundFailure.sessionUnavailable}
  let b=Snapshot();var trace=[b.wire],same=b.valid
  try Data("go".utf8).write(to:gate.appendingPathComponent("dispatch-go"),options:.atomic)
  let deadline=Date().addingTimeInterval(15)
  while !FileManager.default.fileExists(atPath:gate.appendingPathComponent("dispatch-completed").path) && Date()<deadline {pump(0.01);let t=Snapshot();trace.append(t.wire);same = same && b.same(t)}
  for _ in 0..<20{pump(0.01);let t=Snapshot();trace.append(t.wire);same = same && b.same(t)}
  let receipt:[String:Any]=["negativeCalibrationPassed":neg,"positiveFocusDetected":pos,"observationsPreserved":same,"completed":FileManager.default.fileExists(atPath:gate.appendingPathComponent("dispatch-completed").path),"trace":trace]
  try JSONSerialization.data(withJSONObject:receipt,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("archive-signed-observer.json"))
  print("signed observer",same)
 }
}
