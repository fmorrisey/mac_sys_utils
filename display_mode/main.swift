import Foundation
import CoreGraphics

func modes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    return (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
}
func desc(_ m: CGDisplayMode) -> String {
    let hidpi = m.pixelWidth != m.width ? "HiDPI" : "     "
    return String(format: "io=%-4d %5dx%-5d px=%5dx%-5d %6.2fHz %@ flags=0x%x%@",
                  m.ioDisplayModeID, m.width, m.height, m.pixelWidth, m.pixelHeight, m.refreshRate, hidpi, m.ioFlags,
                  m.isUsableForDesktopGUI() ? "" : " (not-desktop)")
}
var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &n)
let args = CommandLine.arguments
if args.count >= 3 && args[1] == "set" {
    let id = ids[0]
    let want = Int32(args[2]) ?? -1
    guard let m = modes(id).first(where: { $0.ioDisplayModeID == want }) else { print("no mode io=\(want)"); exit(1) }
    var cfg: CGDisplayConfigRef?
    var err = CGBeginDisplayConfiguration(&cfg)
    if err == .success { err = CGConfigureDisplayWithDisplayMode(cfg, id, m, nil) }
    if err == .success { err = CGCompleteDisplayConfiguration(cfg, .permanently) } else { CGCancelDisplayConfiguration(cfg) }
    print("set io=\(want) -> \(err.rawValue == 0 ? "OK" : "err \(err.rawValue)")")
    exit(err == .success ? 0 : 1)
}
for i in 0..<Int(n) {
    let id = ids[i]
    print("display \(id) vendor=0x\(String(CGDisplayVendorNumber(id), radix: 16)) model=0x\(String(CGDisplayModelNumber(id), radix: 16)) main=\(CGDisplayIsMain(id)) bounds=\(CGDisplayBounds(id))")
    if let cur = CGDisplayCopyDisplayMode(id) { print("  CURRENT: " + desc(cur)) }
    let all = modes(id)
    print("  modes: \(all.count)")
    for m in all where m.isUsableForDesktopGUI() && (m.width >= 1920) { print("   " + desc(m)) }
}
