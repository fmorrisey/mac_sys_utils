// display-mode: list / set display modes, and (as a LaunchAgent) keep an external display on the
// preferred mode every time it is plugged in. Written for a Samsung TV that presents different EDIDs
// depending on its mood: sometimes the full HDMI 2.1 list, sometimes a cut-down one with nothing above
// 60 Hz at 1440p. macOS keeps whatever it read at the moment the link came up, and System Settings'
// refresh-rate list goes stale, so this does the choosing.
import Foundation
import CoreGraphics
import Darwin

// MARK: - config (environment, set in the LaunchAgent plist)
let env = ProcessInfo.processInfo.environment
struct Pref { let w: Int; let h: Int; let hz: Double; let hidpi: Bool
    var text: String { "\(w)x\(h)@\(Int(hz))\(hidpi ? " HiDPI" : "")" } }
func parsePrefs(_ s: String) -> [Pref] {
    s.split(separator: ",").compactMap { item in
        let t = item.trimmingCharacters(in: .whitespaces).lowercased()
        let hidpi = t.hasSuffix("hidpi")
        let core = hidpi ? String(t.dropLast(5)) : t
        let parts = core.split(separator: "@"); guard parts.count == 2 else { return nil }
        let wh = parts[0].split(separator: "x"); guard wh.count == 2, let w = Int(wh[0]), let h = Int(wh[1]), let hz = Double(parts[1]) else { return nil }
        return Pref(w: w, h: h, hz: hz, hidpi: hidpi)
    }
}
let prefs = parsePrefs(env["DISPLAY_MODE_PREFER"] ?? "2560x1440@120,2560x1440@100,1920x1080@120,2560x1440@60")
let onlyVendor: UInt32? = env["DISPLAY_MODE_VENDOR"].flatMap { UInt32($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
let notifyEnabled = env["DISPLAY_MODE_NOTIFY"] != "0"
let gameGuard = env["DISPLAY_MODE_GAME_GUARD"] != "0"
let virtualVendor: UInt32 = 0x756e6b6e   // "unkn": macOS's headless virtual display

// MARK: - helpers
func ts() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date()) }
func log(_ m: String) { print("\(ts()) \(m)"); fflush(stdout) }
func notify(_ title: String, _ body: String) {
    guard notifyEnabled else { return }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
    try? p.run()
}
func modes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    return (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
}
func isHiDPI(_ m: CGDisplayMode) -> Bool { m.pixelWidth != m.width }
func desc(_ m: CGDisplayMode) -> String {
    String(format: "io=%-4d %5dx%-5d px=%5dx%-5d %6.2fHz %@ flags=0x%x%@", m.ioDisplayModeID, m.width, m.height,
           m.pixelWidth, m.pixelHeight, m.refreshRate, isHiDPI(m) ? "HiDPI" : "     ", m.ioFlags,
           m.isUsableForDesktopGUI() ? "" : " (not-desktop)")
}
func short(_ m: CGDisplayMode) -> String { "\(m.width)x\(m.height)@\(Int(m.refreshRate.rounded()))\(isHiDPI(m) ? " HiDPI" : "")" }
func identity(_ id: CGDirectDisplayID) -> String { String(format: "%04x:%04x", CGDisplayVendorNumber(id), CGDisplayModelNumber(id)) }
func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n); return Array(ids.prefix(Int(n)))
}
func managed(_ id: CGDirectDisplayID) -> Bool {
    if CGDisplayIsBuiltin(id) != 0 { return false }
    let v = CGDisplayVendorNumber(id)
    if v == virtualVendor { return false }
    if let ov = onlyVendor, ov != v { return false }
    return true
}
func setMode(_ id: CGDirectDisplayID, _ m: CGDisplayMode) -> CGError {
    var cfg: CGDisplayConfigRef?
    var err = CGBeginDisplayConfiguration(&cfg)
    if err == .success { err = CGConfigureDisplayWithDisplayMode(cfg, id, m, nil) }
    if err == .success { err = CGCompleteDisplayConfiguration(cfg, .permanently) } else { CGCancelDisplayConfiguration(cfg) }
    return err
}
/// A Wine game (anything *.exe that is not Steam or Wine plumbing) that would lose its audio on a mode switch.
func runningGame() -> String? {
    guard gameGuard else { return nil }
    let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0); var pids = [pid_t](repeating: 0, count: Int(n) / 4 + 64)
    let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * 4))
    let plumbing = ["steam", "wine", "explorer.exe", "services.exe", "plugplay.exe", "rpcss.exe", "conhost.exe", "svchost.exe",
                    "tabtip.exe", "start.exe", "winedevice.exe", "gameoverlayui.exe", "cmd.exe", "launcher", "dowser.exe"]
    for pid in pids.prefix(Int(got) / 4) where pid > 0 {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { continue }
        let name = String(cString: buf); let l = name.lowercased()
        if l.hasSuffix(".exe") && !plumbing.contains(where: { l.contains($0) }) { return "\(name) [\(pid)]" }
    }
    return nil
}

// MARK: - choosing
func bestMode(for id: CGDirectDisplayID) -> (CGDisplayMode, Int)? {
    let all = modes(id).filter { $0.isUsableForDesktopGUI() }
    for (i, p) in prefs.enumerated() {
        if let m = all.first(where: { $0.width == p.w && $0.height == p.h && abs($0.refreshRate - p.hz) < 0.6 && isHiDPI($0) == p.hidpi }) {
            return (m, i)
        }
    }
    return nil
}
final class Agent {
    var notified = Set<String>()        // identity -> already told the user about the cut-down list / game guard
    var pending: DispatchWorkItem?
    func apply(reason: String) {
        for id in onlineDisplays() where managed(id) {
            let ident = identity(id)
            guard let cur = CGDisplayCopyDisplayMode(id) else { continue }
            guard let (best, rank) = bestMode(for: id) else {
                log("\(ident): none of the preferred modes offered (current \(short(cur))) [\(reason)]"); continue
            }
            if cur.ioDisplayModeID == best.ioDisplayModeID {
                log("\(ident): already on \(short(best))\(rank > 0 ? " (preference #\(rank + 1))" : "") [\(reason)]")
            } else if let g = runningGame() {
                log("\(ident): would switch \(short(cur)) -> \(short(best)) but \(g) is running; leaving it [\(reason)]")
                if !notified.contains(ident + ":game") {
                    notified.insert(ident + ":game")
                    notify("TV mode not changed", "\(short(best)) is available but \(g) is running. Quit it and the switch happens by itself.")
                }
            } else {
                let err = setMode(id, best)
                log("\(ident): \(short(cur)) -> \(short(best)) \(err == .success ? "OK" : "FAILED \(err.rawValue)") [\(reason)]")
                if err == .success { notify("Display set to \(short(best))", rank == 0 ? "preferred mode" : "best the TV offers right now") }
            }
            if rank > 0 && !notified.contains(ident + ":cutdown") {
                notified.insert(ident + ":cutdown")
                let want = prefs.first.map { $0.text } ?? "?"
                log("\(ident): TV is presenting a mode list without \(want); best is \(short(best)). A TV power-cycle or input switch usually brings the full list back.")
                notify("TV came up without \(want)", "Using \(short(best)). Power-cycle the TV or switch its input to get the full list back.")
            }
        }
    }
    func schedule(_ reason: String) {
        pending?.cancel()
        let w = DispatchWorkItem { [self] in
            apply(reason: reason)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in apply(reason: reason + " (second pass)") }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }
    func watch() {
        log("display-mode agent starting: prefer " + prefs.map { $0.text }.joined(separator: " > ") + (onlyVendor.map { String(format: ", vendor 0x%04x only", $0) } ?? "") + ", game guard \(gameGuard ? "on" : "off")")
        apply(reason: "startup")
        let cb: CGDisplayReconfigurationCallBack = { id, flags, ctx in
            let agent = Unmanaged<Agent>.fromOpaque(ctx!).takeUnretainedValue()
            if flags.contains(.beginConfigurationFlag) { return }
            if flags.contains(.removeFlag) || flags.contains(.disabledFlag) {
                agent.notified = agent.notified.filter { !$0.hasPrefix(identity(id)) }   // next plug-in may be a different EDID
                log("display \(identity(id)) removed")
            }
            if flags.contains(.addFlag) || flags.contains(.enabledFlag) { agent.schedule("display \(identity(id)) added") }
            else if flags.contains(.setModeFlag) { agent.schedule("mode changed on \(identity(id))") }
        }
        CGDisplayRegisterReconfigurationCallback(cb, Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopRun()
    }
}

// MARK: - CLI
let args = CommandLine.arguments
if args.count >= 3 && args[1] == "set" {
    let id = onlineDisplays().first(where: managed) ?? CGMainDisplayID()
    let want = Int32(args[2]) ?? -1
    guard let m = modes(id).first(where: { $0.ioDisplayModeID == want }) else { print("no mode io=\(want)"); exit(1) }
    let err = setMode(id, m)
    print("set io=\(want) -> \(err == .success ? "OK" : "err \(err.rawValue)")")
    exit(err == .success ? 0 : 1)
}
if args.count >= 2 && args[1] == "--watch" { Agent().watch(); exit(0) }
if args.count >= 2 && args[1] == "--apply" { Agent().apply(reason: "manual"); exit(0) }
if args.count >= 2 && (args[1] == "-h" || args[1] == "--help") {
    print("usage: display-mode            list displays and modes (>= 1920 wide)\n       display-mode set IO     switch the external display to mode IO\n       display-mode --apply    one-shot: pick the preferred mode now\n       display-mode --watch    agent: do it on every plug-in (DISPLAY_MODE_PREFER=\"2560x1440@120,...\", DISPLAY_MODE_VENDOR=0x4c2d, DISPLAY_MODE_NOTIFY=0, DISPLAY_MODE_GAME_GUARD=0)")
    exit(0)
}
for id in onlineDisplays() {
    print("display \(id) vendor=0x\(String(CGDisplayVendorNumber(id), radix: 16)) model=0x\(String(CGDisplayModelNumber(id), radix: 16)) main=\(CGDisplayIsMain(id)) bounds=\(CGDisplayBounds(id))\(managed(id) ? "" : "  (not managed)")")
    if let cur = CGDisplayCopyDisplayMode(id) { print("  CURRENT: " + desc(cur)) }
    if let (b, r) = bestMode(for: id), managed(id) { print("  preferred available: \(short(b)) (preference #\(r + 1), io=\(b.ioDisplayModeID))") }
    let all = modes(id)
    print("  modes: \(all.count)")
    for m in all where m.isUsableForDesktopGUI() && m.width >= 1920 { print("   " + desc(m)) }
}
