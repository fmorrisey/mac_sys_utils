// wifi-autoswitch — turn Wi-Fi off when a wired Ethernet link is up, back on when it goes away.
//
// Event-driven: subscribes to SystemConfiguration dynamic-store link/IPv4 changes (no polling).
// Edge-triggered: it only acts when the *wired* state changes, so a manual Wi-Fi toggle
// (AirDrop, Handoff, hotspot) sticks until the next dock plug/unplug.
//
// Usage:
//   wifi-autoswitch            run forever (what the LaunchAgent does)
//   wifi-autoswitch --status   print what it sees and exit
//   wifi-autoswitch --once     evaluate once, act if needed, exit
//
// Environment (set in the LaunchAgent plist):
//   WIFI_AUTOSWITCH_IFACES="en9 en8"  only consider these wired interfaces (default: auto-discover)
//   WIFI_AUTOSWITCH_NOTIFY=0          disable macOS notifications
//   WIFI_AUTOSWITCH_UP_GRACE=1        seconds to wait after link+IP before turning Wi-Fi off
//   WIFI_AUTOSWITCH_DOWN_GRACE=6      seconds to wait after link loss before turning Wi-Fi on
//                                     (absorbs link flaps during sleep/wake and dock re-enumeration)
//   WIFI_AUTOSWITCH_DEBUG=1           log every raw store event

import Foundation
import SystemConfiguration
import CoreWLAN

let env = ProcessInfo.processInfo.environment
let notifyEnabled = env["WIFI_AUTOSWITCH_NOTIFY"] != "0"
let ifaceOverride: [String] = (env["WIFI_AUTOSWITCH_IFACES"] ?? "")
    .split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
let upGrace = Double(env["WIFI_AUTOSWITCH_UP_GRACE"] ?? "") ?? 1.0
let downGrace = Double(env["WIFI_AUTOSWITCH_DOWN_GRACE"] ?? "") ?? 6.0
let debug = env["WIFI_AUTOSWITCH_DEBUG"] == "1"

let tsFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ msg: String) {
    print("\(tsFormatter.string(from: Date())) \(msg)")
    fflush(stdout)
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func notify(title: String, body: String) {
    guard notifyEnabled else { return }
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
}

// MARK: - Wi-Fi

func wifiInterface() -> CWInterface? { CWWiFiClient.shared().interface() }

func setWifiPower(_ name: String, on: Bool) -> Bool {
    let (status, out) = run("/usr/sbin/networksetup", ["-setairportpower", name, on ? "on" : "off"])
    if status != 0 { log("networksetup -setairportpower failed (\(status)): \(out)") }
    return status == 0
}

// MARK: - Wired interfaces

struct Wired { let bsd: String; let name: String }

/// Physical Ethernet-type interfaces currently present, minus Wi-Fi, IP-over-Thunderbolt ports
/// ("Thunderbolt 1/2/3") and Apple's internal "Ethernet Adapter (enX)" pseudo-interfaces.
func wiredCandidates(excluding wifiName: String?) -> [Wired] {
    guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
    var out: [Wired] = []
    for intf in all {
        guard let bsd = SCNetworkInterfaceGetBSDName(intf) as String?,
              let type = SCNetworkInterfaceGetInterfaceType(intf) as String?,
              type == kSCNetworkInterfaceTypeEthernet as String,
              bsd != wifiName else { continue }
        let name = (SCNetworkInterfaceGetLocalizedDisplayName(intf) as String?) ?? bsd
        if !ifaceOverride.isEmpty {
            if ifaceOverride.contains(bsd) { out.append(Wired(bsd: bsd, name: name)) }
            continue
        }
        if name.range(of: #"^Thunderbolt \d+$"#, options: .regularExpression) != nil { continue }
        if name.hasPrefix("Ethernet Adapter (") { continue }
        out.append(Wired(bsd: bsd, name: name))
    }
    return out
}

func storeDict(_ store: SCDynamicStore, _ key: String) -> [String: Any]? {
    SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
}

func linkActive(_ store: SCDynamicStore, _ bsd: String) -> Bool {
    (storeDict(store, "State:/Network/Interface/\(bsd)/Link")?["Active"] as? Bool) ?? false
}

/// First IPv4 address that isn't self-assigned (169.254.x.x means DHCP failed — not usable).
func usableIPv4(_ store: SCDynamicStore, _ bsd: String) -> String? {
    let addrs = storeDict(store, "State:/Network/Interface/\(bsd)/IPv4")?["Addresses"] as? [String] ?? []
    return addrs.first { !$0.hasPrefix("169.254.") }
}

struct Candidate { let iface: Wired; let link: Bool; let ip: String? }

struct Snapshot {
    let wifiName: String?
    let wifiOn: Bool?
    let candidates: [Candidate]
    var up: [Candidate] { candidates.filter { $0.link && $0.ip != nil } }
    var wiredUp: Bool { !up.isEmpty }
}

func snapshot(_ store: SCDynamicStore) -> Snapshot {
    let wifi = wifiInterface()
    let name = wifi?.interfaceName
    let cands = wiredCandidates(excluding: name).map {
        Candidate(iface: $0, link: linkActive(store, $0.bsd), ip: usableIPv4(store, $0.bsd))
    }
    return Snapshot(wifiName: name, wifiOn: wifi?.powerOn(), candidates: cands)
}

// MARK: - Decision

var lastWiredUp: Bool? = nil

func evaluate(_ store: SCDynamicStore, reason: String) {
    let s = snapshot(store)
    let wiredUp = s.wiredUp
    guard lastWiredUp != wiredUp else { return }      // no edge → leave Wi-Fi alone
    let firstRun = lastWiredUp == nil
    lastWiredUp = wiredUp
    guard let wifiName = s.wifiName else { log("no Wi-Fi interface found; nothing to do"); return }
    if wiredUp {
        let desc = s.up.map { "\($0.iface.name) (\($0.iface.bsd)) \($0.ip!)" }.joined(separator: ", ")
        log("wired UP\(firstRun ? " at startup" : "") [\(reason)]: \(desc)")
        if s.wifiOn == false { log("Wi-Fi (\(wifiName)) already off"); return }
        if setWifiPower(wifiName, on: false) {
            log("Wi-Fi (\(wifiName)) turned OFF")
            notify(title: "Wi-Fi off", body: "Using wired: \(desc)")
        }
    } else {
        log("wired DOWN\(firstRun ? " at startup" : "") [\(reason)]")
        if s.wifiOn == true { log("Wi-Fi (\(wifiName)) already on"); return }
        if setWifiPower(wifiName, on: true) {
            log("Wi-Fi (\(wifiName)) turned ON")
            notify(title: "Wi-Fi on", body: "Wired Ethernet disconnected")
        }
    }
}

func printStatus(_ store: SCDynamicStore) {
    let s = snapshot(store)
    print("Wi-Fi:  \(s.wifiName ?? "none") power=\(s.wifiOn.map { $0 ? "on" : "off" } ?? "unknown")")
    if s.candidates.isEmpty { print("Wired:  no candidate interfaces present") }
    for c in s.candidates {
        print("Wired:  \(c.iface.name) (\(c.iface.bsd)) link=\(c.link ? "active" : "inactive") ipv4=\(c.ip ?? "none")")
    }
    print("Wired is \(s.wiredUp ? "UP → Wi-Fi should be off" : "DOWN → Wi-Fi should be on")")
    print("Config: ifaces=\(ifaceOverride.isEmpty ? "auto" : ifaceOverride.joined(separator: ","))"
          + " up_grace=\(upGrace)s down_grace=\(downGrace)s notify=\(notifyEnabled)")
}

// MARK: - Event plumbing

var pending: DispatchWorkItem?

/// Coalesce bursts of store changes. The grace period depends on the direction of the change as
/// seen right now; evaluate() re-reads the real state when the timer fires.
func schedule(_ store: SCDynamicStore, reason: String) {
    pending?.cancel()
    let delay = snapshot(store).wiredUp ? upGrace : downGrace
    if debug { log("event [\(reason)] → re-evaluate in \(delay)s") }
    let item = DispatchWorkItem { evaluate(store, reason: reason) }
    pending = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
}

let storeCallback: SCDynamicStoreCallBack = { store, keys, _ in
    let changed = (keys as? [String]) ?? []
    schedule(store, reason: changed.map { $0.replacingOccurrences(of: "State:/Network/Interface/", with: "") }
                            .joined(separator: " "))
}

// MARK: - Main

guard let store = SCDynamicStoreCreate(nil, "wifi-autoswitch" as CFString, storeCallback, nil) else {
    log("SCDynamicStoreCreate failed"); exit(1)
}

let args = CommandLine.arguments.dropFirst()
if args.contains("--status") { printStatus(store); exit(0) }
if args.contains("--once")   { evaluate(store, reason: "once"); exit(0) }
if args.contains("-h") || args.contains("--help") {
    print("usage: wifi-autoswitch [--status | --once]"); exit(0)
}

let keys = ["State:/Network/Interface"] as CFArray
let patterns = ["State:/Network/Interface/.*/Link", "State:/Network/Interface/.*/IPv4"] as CFArray
guard SCDynamicStoreSetNotificationKeys(store, keys, patterns) else {
    log("SCDynamicStoreSetNotificationKeys failed"); exit(1)
}
guard let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else {
    log("SCDynamicStoreCreateRunLoopSource failed"); exit(1)
}
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

log("wifi-autoswitch started (pid \(getpid()))")
evaluate(store, reason: "startup")
CFRunLoopRun()
