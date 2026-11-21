import CoreServices
import Foundation
let scheme = "nxm" as CFString
let bundle = "com.fmorrisey.nxm-handler" as CFString
let status = LSSetDefaultHandlerForURLScheme(scheme, bundle)
let now = LSCopyDefaultHandlerForURLScheme(scheme)?.takeRetainedValue() as String? ?? "none"
print(status == 0 ? "nxm:// default handler: \(now)" : "LSSetDefaultHandlerForURLScheme failed (\(status)); current: \(now). Firefox will ask once; pick NXM Handler and tick Always.")
