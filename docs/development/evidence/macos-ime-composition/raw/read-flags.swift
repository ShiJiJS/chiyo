import Foundation
import AppKit
let flags = NSEvent.modifierFlags
let values:[String:Any] = ["capsLock":flags.contains(.capsLock),"shift":flags.contains(.shift),"command":flags.contains(.command),"control":flags.contains(.control),"option":flags.contains(.option)]
let data=try JSONSerialization.data(withJSONObject:values,options:[.sortedKeys])
print(String(data:data,encoding:.utf8)!)
