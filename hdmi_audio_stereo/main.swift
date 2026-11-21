// hdmi-audio-stereo — keep HDMI / DisplayPort audio endpoints (TVs, monitors) in a consistent
// channel count AND speaker assignment across hot-plugs (stereo for TV speakers, 5.1 for a
// soundbar/AVR). The name stuck from its first job.
//
// Why: a TV or monitor that advertises 5.1 / 7.1 PCM over HDMI makes CoreAudio publish a
// 6- or 8-channel output device. Wine's winecoreaudio builds the WASAPI mix format from that
// channel count, so Unreal / Unity games mix surround and put dialogue on a centre channel the
// TV's stereo speakers never play. coreaudiod remembers the chosen format per device UID, and
// the same TV gets a different UID per port / EDID variant, so an Audio MIDI Setup change does
// not survive the next plug-in. This agent sets every display-audio endpoint to a stereo PCM
// format whenever one appears or changes, and re-applies it if anything flips it back.
//
//   hdmi-audio-stereo              run as the LaunchAgent (watch + fix forever)
//   hdmi-audio-stereo --once       fix now and exit
//   hdmi-audio-stereo --status     print every output device, its stream format, and what would change
//   --channels N                   target channel count for this invocation (default 2; also HDMI_AUDIO_STEREO_CHANNELS)
//   --layout L,L,...               persist the speaker assignment (CoreAudio channel labels per device
//                                  channel: 1=L 2=R 3=C 4=LFE 5=Ls 6=Rs 7=Lc 8=Rc 9=Cs 10=Lsd 11=Rsd),
//                                  e.g. --layout 1,2,4,3,5,6 = HDMI wire order (LFE on 3, Center on 4);
//                                  --layout default clears it; --save-layout captures the device's current one
//   --target N | --target default  persist a target for the RUNNING agent (stored in user preferences,
//                                  picked up within seconds): e.g. `--target 6` for 5.1 to a soundbar tonight,
//                                  `--target default` to go back to the plist/env setting
//   --device NAME                  act only on this device name (repeatable; also HDMI_AUDIO_STEREO_DEVICES=a,b)
//
// Env: HDMI_AUDIO_STEREO_NOTIFY=0 disables the macOS notification on each change.
//      HDMI_AUDIO_STEREO_RESTORE_DEFAULT=0 stops it re-selecting a display endpoint as the
//      default output after that endpoint vanished and came back (macOS falls back to the
//      built-in speakers on a hot-plug blink and does not always hand the default back).

import Foundation
import Darwin
import CoreAudio
import AudioToolbox

// MARK: - config

let env = ProcessInfo.processInfo.environment
var baseTargetChannels = UInt32(env["HDMI_AUDIO_STEREO_CHANNELS"] ?? "") ?? 2
let prefsDomain = "com.fmorrisey.hdmi-audio-stereo" as CFString
/// A persisted override set with `--target N`; read live so the running agent follows it.
func prefsTarget() -> UInt32? {
    guard let v = CFPreferencesCopyAppValue("channels" as CFString, prefsDomain) else { return nil }
    if let n = v as? Int, n > 0 { return UInt32(n) }
    if let str = v as? String, let n = UInt32(str), n > 0 { return n }
    return nil
}
var targetChannels: UInt32 { prefsTarget() ?? baseTargetChannels }
func parseLabels(_ str: String) -> [UInt32]? {
    let parts = str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let nums = parts.compactMap { UInt32($0) }
    return nums.count == parts.count && !nums.isEmpty ? nums : nil
}
var baseLayout: [UInt32]? = parseLabels(env["HDMI_AUDIO_STEREO_LAYOUT"] ?? "")
func prefsLayout() -> [UInt32]? {
    guard let v = CFPreferencesCopyAppValue("layout" as CFString, prefsDomain) as? String else { return nil }
    return parseLabels(v)
}
/// Desired speaker assignment (labels per device channel); applied only when its length equals the
/// device's channel count after the format fix.
var desiredLayout: [UInt32]? { prefsLayout() ?? baseLayout }
func setPrefsLayout(_ labels: [UInt32]?) {
    CFPreferencesSetAppValue("layout" as CFString, labels.map { $0.map(String.init).joined(separator: ",") as CFString }, prefsDomain)
    CFPreferencesAppSynchronize(prefsDomain)
}
let labelNames: [UInt32: String] = [1:"L",2:"R",3:"C",4:"LFE",5:"Ls",6:"Rs",7:"Lc",8:"Rc",9:"Cs",10:"Lsd",11:"Rsd",0:"-"]
func describeLabels(_ l: [UInt32]) -> String { l.map { labelNames[$0] ?? "\($0)" }.joined(separator: " ") }

/// Current preferred channel layout as labels per channel; [] when it is tag/bitmap based or unset.
func currentLayoutLabels(_ dev: AudioObjectID) -> [UInt32] {
    var a = addr(kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size >= 12 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8); defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return [] }
    let tag = raw.load(as: UInt32.self); let n = Int(raw.load(fromByteOffset: 8, as: UInt32.self))
    guard tag == kAudioChannelLayoutTag_UseChannelDescriptions, 12 + n * 20 <= Int(size) else { return [] }
    return (0..<n).map { raw.load(fromByteOffset: 12 + $0 * 20, as: UInt32.self) }
}
/// Write a preferred channel layout built from labels (same thing Audio MIDI Setup's "Configure Speakers" writes).
func setLayout(_ dev: AudioObjectID, labels: [UInt32]) -> OSStatus {
    let n = labels.count, size = 12 + n * 20
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8); defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    raw.storeBytes(of: kAudioChannelLayoutTag_UseChannelDescriptions, toByteOffset: 0, as: UInt32.self)
    raw.storeBytes(of: UInt32(n), toByteOffset: 8, as: UInt32.self)
    for (i, l) in labels.enumerated() {
        let o = 12 + i * 20
        let az: Float32? = [1: -30, 2: 30, 3: 0, 5: -110, 6: 110, 7: -15, 8: 15, 9: 180, 10: -90, 11: 90][l]
        raw.storeBytes(of: l, toByteOffset: o, as: UInt32.self)
        raw.storeBytes(of: az == nil ? UInt32(0) : UInt32(2), toByteOffset: o + 4, as: UInt32.self)   // 2 = spherical coordinates
        raw.storeBytes(of: az ?? 0, toByteOffset: o + 8, as: Float32.self)
        raw.storeBytes(of: Float32(0), toByteOffset: o + 12, as: Float32.self)
        raw.storeBytes(of: az == nil ? Float32(0) : Float32(1), toByteOffset: o + 16, as: Float32.self)
    }
    var a = addr(kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeOutput)
    return AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(size), raw)
}
func setStereoPair(_ dev: AudioObjectID, _ pair: [UInt32]) -> OSStatus {
    var a = addr(kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput); var p = pair
    return AudioObjectSetPropertyData(dev, &a, 0, nil, 8, &p)
}
/// Apply the desired speaker assignment to one device if it has that many channels. With `force`
/// it is written even when it reads back identical: after a hot-plug blink the device comes back
/// with the right assignment stored, but clients that stayed attached (Wine's audio unit, for one)
/// come back with their channels crossed until the property is written again, which is what
/// re-doing "Configure Speakers" by hand used to fix. Returns true if written.
func applyLayout(_ d: Dev, verbose: Bool, force: Bool = false) -> Bool {
    guard let want = desiredLayout else { return false }
    let ch = outputChannels(d.id)
    guard ch == want.count else { if verbose { log("\(d.name): layout not applied (\(ch) ch, layout has \(want.count))") }; return false }
    let cur = currentLayoutLabels(d.id)
    if cur == want && !force { if verbose { log("\(d.name): speaker layout already \(describeLabels(cur))") }; return false }
    let st = setLayout(d.id, labels: want)
    let st2 = setStereoPair(d.id, [1, 2])
    let after = currentLayoutLabels(d.id)
    log("\(d.name): speaker layout \(cur.isEmpty ? "unset" : describeLabels(cur)) -> \(describeLabels(want))\(cur == want ? " (re-written to resync clients)" : "") \(after == want ? "OK" : "FAILED status=\(st)") (stereo pair 1,2 status \(st2))")
    return after == want
}
func setPrefsTarget(_ n: UInt32?) {
    CFPreferencesSetAppValue("channels" as CFString, n.map { $0 as CFNumber }, prefsDomain)
    CFPreferencesAppSynchronize(prefsDomain)
}
var onlyDevices: [String] = (env["HDMI_AUDIO_STEREO_DEVICES"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
let notifyEnabled = env["HDMI_AUDIO_STEREO_NOTIFY"] != "0"
let restoreDefault = env["HDMI_AUDIO_STEREO_RESTORE_DEFAULT"] != "0"
let recheckSeconds: TimeInterval = 15
let clientPollSeconds: TimeInterval = 3   // how often to look for new audio clients

// MARK: - helpers

func ts() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date()) }
func log(_ msg: String) { print("\(ts()) \(msg)"); fflush(stdout) }

func fourcc(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: b, encoding: .macOSRoman) ?? "????"
}

@discardableResult
func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
}

func notify(title: String, body: String) {
    guard notifyEnabled else { return }
    func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
}

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getValue<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ def: T) -> T? {
    var a = addr(sel, scope); var size = UInt32(MemoryLayout<T>.size); var v = def
    let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
    return st == noErr ? v : nil
}

func getArray<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
    var a = addr(sel, scope); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let n = Int(size) / MemoryLayout<T>.stride
    let p = UnsafeMutablePointer<T>.allocate(capacity: n); defer { p.deallocate() }
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, p) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: p, count: Int(size) / MemoryLayout<T>.stride))
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = addr(sel); var size = UInt32(MemoryLayout<CFString?>.size); var s: Unmanaged<CFString>? = nil
    let st = withUnsafeMutablePointer(to: &s) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
    guard st == noErr, let cf = s?.takeRetainedValue() else { return "" }
    return cf as String
}

/// Total output channels as published to clients (this is what Wine reads).
func outputChannels(_ dev: AudioObjectID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16); defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func describe(_ d: AudioStreamBasicDescription) -> String {
    let kind = (d.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? "float" : ((d.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0 ? "int" : "raw")
    return "\(d.mChannelsPerFrame)ch \(Int(d.mSampleRate))Hz \(d.mBitsPerChannel)-bit \(kind) \(fourcc(d.mFormatID))"
}

struct Dev { let id: AudioObjectID; let name: String; let uid: String; let transport: String; let channels: Int }

func outputDevices() -> [Dev] {
    let ids: [AudioObjectID] = getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    return ids.compactMap { id in
        let ch = outputChannels(id); if ch == 0 { return nil }
        let tt = getValue(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
        return Dev(id: id, name: getString(id, kAudioObjectPropertyName), uid: getString(id, kAudioDevicePropertyDeviceUID), transport: fourcc(tt), channels: ch)
    }
}

func defaultOutput() -> AudioObjectID {
    getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) ?? 0
}
func systemOutput() -> AudioObjectID {
    getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) ?? 0
}
@discardableResult
func setDefault(_ sel: AudioObjectPropertySelector, _ id: AudioObjectID) -> OSStatus {
    var a = addr(sel); var v = id
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &v)
}

/// Which devices this agent manages: display-audio transports by default, or the named ones.
func isManaged(_ d: Dev) -> Bool {
    onlyDevices.isEmpty ? (d.transport == "hdmi" || d.transport == "dprt") : onlyDevices.contains(d.name)
}

func outputStreams(_ d: Dev) -> [AudioStreamID] { getArray(d.id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput) }

/// Pick the best PCM format with `channels` channels at the stream's current sample rate.
func stereoCandidate(for stream: AudioStreamID, current: AudioStreamBasicDescription, channels: UInt32) -> AudioStreamBasicDescription? {
    let avail: [AudioStreamRangedDescription] = getArray(stream, kAudioStreamPropertyAvailablePhysicalFormats)
    let rate = current.mSampleRate
    let cands = avail
        .filter { $0.mFormat.mFormatID == kAudioFormatLinearPCM && $0.mFormat.mChannelsPerFrame == channels }
        .filter { $0.mFormat.mSampleRate == rate || ($0.mFormat.mSampleRate == 0 && $0.mSampleRateRange.mMinimum <= rate && rate <= $0.mSampleRateRange.mMaximum) }
        .sorted { a, b in
            // same bit depth as now first, then the deepest
            let sa = a.mFormat.mBitsPerChannel == current.mBitsPerChannel, sb = b.mFormat.mBitsPerChannel == current.mBitsPerChannel
            if sa != sb { return sa }
            return a.mFormat.mBitsPerChannel > b.mFormat.mBitsPerChannel
        }
    guard var f = cands.first?.mFormat else { return nil }
    if f.mSampleRate == 0 { f.mSampleRate = rate }
    return f
}

/// Apply the target format to every managed device whose streams carry a different channel count
/// (so `--once --channels 6` also restores multichannel), then the speaker assignment. Returns the names changed.
@discardableResult
func applyFix(verbose: Bool, forceLayout: Bool = false) -> [String] {
    var changed: [String] = []
    for d in outputDevices() where isManaged(d) {
        defer { if applyLayout(d, verbose: verbose, force: forceLayout) && !changed.contains(d.name) { changed.append(d.name) } }
        for s in outputStreams(d) {
            guard let cur = getValue(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription()) else { continue }
            if cur.mChannelsPerFrame == targetChannels {
                if verbose { log("\(d.name): already \(describe(cur)) (\(d.channels) out ch)") }
                continue
            }
            guard var want = stereoCandidate(for: s, current: cur, channels: targetChannels) else {
                log("\(d.name): no \(targetChannels)-ch PCM format at \(Int(cur.mSampleRate)) Hz offered; leaving \(describe(cur))")
                continue
            }
            var a = addr(kAudioStreamPropertyPhysicalFormat)
            let st = AudioObjectSetPropertyData(s, &a, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &want)
            usleep(300_000)
            let after = getValue(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
            let ok = st == noErr && (after?.mChannelsPerFrame ?? 0) == targetChannels
            log("\(d.name): \(describe(cur)) -> \(describe(want)) \(ok ? "OK" : "FAILED status=\(st)") now \(after.map(describe) ?? "?"), \(outputChannels(d.id)) out ch")
            if ok { changed.append(d.name) }
        }
    }
    return changed
}

func printStatus() {
    let def = defaultOutput()
    let src = prefsTarget() != nil ? "runtime override via --target" : "plist/env default"
    print("target: \(targetChannels) ch [\(src)] on " + (onlyDevices.isEmpty ? "every HDMI / DisplayPort output" : onlyDevices.joined(separator: ", ")) + "  (notify=\(notifyEnabled))")
    for d in outputDevices() {
        let flag = d.id == def ? "*" : " "
        let managed = isManaged(d) ? (d.channels != Int(targetChannels) ? "WOULD FIX" : "managed, ok") : "ignored"
        print("\(flag) \(d.name)  [\(d.transport)]  \(d.channels) out ch  \(managed)  uid=\(d.uid)")
        if isManaged(d) {
            let cur = currentLayoutLabels(d.id)
            print("      speaker layout: \(cur.isEmpty ? "unset/tag-based" : describeLabels(cur))" + (desiredLayout.map { "   wanted: \(describeLabels($0))" } ?? "   (no layout configured)"))
        }
        for s in outputStreams(d) {
            let phys = getValue(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())
            let avail: [AudioStreamRangedDescription] = getArray(s, kAudioStreamPropertyAvailablePhysicalFormats)
            let chs = Set(avail.filter { $0.mFormat.mFormatID == kAudioFormatLinearPCM }.map { Int($0.mFormat.mChannelsPerFrame) }).sorted()
            print("      stream: \(phys.map(describe) ?? "?")   PCM channel counts offered: \(chs.map(String.init).joined(separator: ","))")
        }
    }
    print("* = current default output")
}

// MARK: - watch loop


// MARK: - audio clients (macOS 14+ process objects)
// A Wine game that opens its stream after the TV has settled still plays with crossed channels until the
// preferred layout is written again (seen with Halo 2026-11-13/14 and Skyrim 2026-11-14). So: watch which
// processes are producing output on a managed device and re-write the layout whenever a new one appears.
func cc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
let selProcessObjectList = AudioObjectPropertySelector(cc("prs#"))   // kAudioHardwarePropertyProcessObjectList
let selProcIsRunningOutput = AudioObjectPropertySelector(cc("piro")) // kAudioProcessPropertyIsRunningOutput
let selProcDevices = AudioObjectPropertySelector(cc("pdv#"))         // kAudioProcessPropertyDevices
let selProcPID = AudioObjectPropertySelector(cc("ppid"))             // kAudioProcessPropertyPID

func runningOutputPIDs(on dev: AudioObjectID) -> Set<pid_t> {
    let procs: [AudioObjectID] = getArray(AudioObjectID(kAudioObjectSystemObject), selProcessObjectList)
    var out = Set<pid_t>()
    for p in procs {
        guard (getValue(p, selProcIsRunningOutput, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0) != 0 else { continue }
        let devs: [AudioObjectID] = getArray(p, selProcDevices, kAudioObjectPropertyScopeOutput)
        guard devs.contains(dev) else { continue }
        if let pid = getValue(p, selProcPID, kAudioObjectPropertyScopeGlobal, pid_t(0)), pid > 0 { out.insert(pid) }
    }
    return out
}

func procName(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    let n = proc_name(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : "pid \(pid)"
}

final class Watcher: @unchecked Sendable {
    let q = DispatchQueue(label: "hdmi-audio-stereo")
    var hooked = Set<AudioObjectID>()
    var pending: DispatchWorkItem?
    // default-output restore: remember which managed device was the default, and whether the
    // fallback to the built-in speakers happened because that device had vanished.
    var lastDefaultName: String?
    var lastDefaultWasManaged = false
    var lastDefaultWasSystemToo = false
    var pendingRestore: String?
    var pendingRestoreSystem = false
    var lastClients = [AudioObjectID: Set<pid_t>]()
    var lastClientRewrite = Date.distantPast

    /// Every few seconds: did a new process start producing output on a managed device? Then the
    /// layout gets written again so that client maps its channels onto the right speakers.
    func pollClients() {
        var newcomers: [String] = []
        for d in outputDevices() where isManaged(d) {
            let cur = runningOutputPIDs(on: d.id)
            if let prev = lastClients[d.id] {
                for pid in cur.subtracting(prev) { newcomers.append("\(procName(pid)) [\(pid)] on \(d.name)") }
            }
            lastClients[d.id] = cur
        }
        guard !newcomers.isEmpty else { return }
        log("new audio client: " + newcomers.joined(separator: ", "))
        guard Date().timeIntervalSince(lastClientRewrite) > 5 else { return }
        lastClientRewrite = Date()
        _ = applyFix(verbose: false, forceLayout: true)
        q.asyncAfter(deadline: .now() + 3.0) { [self] in _ = applyFix(verbose: false, forceLayout: true) }
    }

    func noteDefault() {
        let def = defaultOutput()
        if let d = outputDevices().first(where: { $0.id == def }) {
            lastDefaultName = d.name
            lastDefaultWasManaged = isManaged(d)
            lastDefaultWasSystemToo = systemOutput() == def
        }
    }

    /// Runs immediately on the default-output notification (not debounced), so it still sees the
    /// managed device as absent. A manual switch to the speakers while the TV is present never arms it.
    func onDefaultOutputChanged() {
        guard restoreDefault else { noteDefault(); return }
        let devs = outputDevices()
        let cur = devs.first(where: { $0.id == defaultOutput() })
        if let c = cur, c.transport == "bltn", lastDefaultWasManaged, let name = lastDefaultName,
           !devs.contains(where: { $0.name == name && isManaged($0) }) {
            pendingRestore = name
            pendingRestoreSystem = lastDefaultWasSystemToo
            log("default output fell back to \(c.name) because \(name) vanished; will hand it back when \(name) returns")
        }
        noteDefault()
    }

    func restoreIfPossible() {
        guard let name = pendingRestore else { return }
        let devs = outputDevices()
        guard let d = devs.first(where: { $0.name == name && isManaged($0) }) else { return }
        let cur = devs.first(where: { $0.id == defaultOutput() })
        if cur == nil || cur!.transport == "bltn" {
            let st = setDefault(kAudioHardwarePropertyDefaultOutputDevice, d.id)
            var st2: OSStatus = noErr
            if pendingRestoreSystem { st2 = setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, d.id) }
            log("restored default output to \(name) (status \(st)\(pendingRestoreSystem ? ", system output \(st2)" : ""))")
            if st == noErr { notify(title: "Audio back on \(name)", body: "Default output restored after the display re-connected") }
        }
        pendingRestore = nil
        noteDefault()
    }

    func start() {
        log("hdmi-audio-stereo starting: target=\(targetChannels)ch\(prefsTarget() != nil ? " (runtime override)" : "") layout=\(desiredLayout.map(describeLabels) ?? "none") devices=" + (onlyDevices.isEmpty ? "all hdmi/dprt" : onlyDevices.joined(separator: ",")) + " notify=\(notifyEnabled) restore_default=\(restoreDefault)")
        fixNow(reason: "startup", verbose: true)
        noteDefault()
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, "device list changed")
        var b = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &b, q) { [self] _, _ in
            onDefaultOutputChanged(); schedule("default output changed")
        }
        hookDevices()
        // belt and braces: a quiet periodic re-check in case a notification is missed
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + recheckSeconds, repeating: recheckSeconds)
        t.setEventHandler { [self] in
            let changed = applyFix(verbose: false)
            if !changed.isEmpty { announce(changed, reason: "periodic re-check") }
            // while a Wine game is playing, quietly re-write the layout each pass (no notification)
            for d in outputDevices() where isManaged(d) && runningOutputPIDs(on: d.id).contains(where: { procName($0).lowercased().hasSuffix(".exe") }) {
                _ = applyLayout(d, verbose: false, force: true)
            }
            hookDevices()
            restoreIfPossible()
        }
        t.resume()
        timer = t
        let c = DispatchSource.makeTimerSource(queue: q)
        c.schedule(deadline: .now() + 2.0, repeating: clientPollSeconds)
        c.setEventHandler { [self] in pollClients() }
        c.resume()
        clientTimer = c
        CFRunLoopRun()
    }
    var timer: DispatchSourceTimer?
    var clientTimer: DispatchSourceTimer?

    func listen(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ why: String) {
        var a = addr(sel, scope)
        AudioObjectAddPropertyListenerBlock(obj, &a, q) { [self] _, _ in schedule(why) }
    }

    func hookDevices() {
        for d in outputDevices() where isManaged(d) {
            if !hooked.contains(d.id) {
                hooked.insert(d.id)
                listen(d.id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, "\(d.name) stream configuration changed")
                listen(d.id, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, "\(d.name) IO started/stopped")
            }
            for s in outputStreams(d) where !hooked.contains(s) {
                hooked.insert(s)
                listen(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, "\(d.name) stream format changed")
            }
        }
    }

    /// Debounce: hot-plug fires a burst of notifications; act once, 1.5 s after the last one,
    /// then once more 4 s later because a freshly plugged endpoint can be listed before its
    /// streams report their real format (seen 2026-11-13: the first pass found nothing to do,
    /// the 60 s re-check then found 6 ch).
    func schedule(_ why: String) {
        pending?.cancel()
        let w = DispatchWorkItem { [self] in
            fixNow(reason: why, verbose: false); hookDevices(); restoreIfPossible()
            q.asyncAfter(deadline: .now() + 4.0) { [self] in
                let changed = applyFix(verbose: false, forceLayout: true)
                if !changed.isEmpty { announce(changed, reason: why + " (second pass)") }
                hookDevices(); restoreIfPossible()
            }
        }
        pending = w
        q.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func fixNow(reason: String, verbose: Bool) {
        let changed = applyFix(verbose: verbose, forceLayout: true)
        if !changed.isEmpty { announce(changed, reason: reason) }
        else if !verbose { log("\(reason): nothing to change") }
    }

    func announce(_ names: [String], reason: String) {
        log("fixed (\(reason)): \(names.joined(separator: ", ")) -> \(targetChannels) ch")
        notify(title: "HDMI audio set to \(targetChannels) ch", body: names.joined(separator: ", "))
    }
}

// MARK: - main

var args = Array(CommandLine.arguments.dropFirst())
var mode = "watch"
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--status": mode = "status"
    case "--clients": mode = "clients"
    case "--once": mode = "once"
    case "--channels":
        guard !args.isEmpty, let n = UInt32(args.removeFirst()), n >= 1 else { print("--channels needs a number"); exit(2) }
        baseTargetChannels = n; setPrefsTarget(nil)
    case "--layout":
        guard !args.isEmpty else { print("--layout needs labels like 1,2,4,3,5,6 or 'default'"); exit(2) }
        let v = args.removeFirst()
        if v == "default" || v == "reset" { setPrefsLayout(nil); mode = "once"; print("runtime layout cleared") }
        else if let l = parseLabels(v) { setPrefsLayout(l); mode = "once"; print("runtime layout set to \(describeLabels(l)); the running agent follows it within ~15 s") }
        else { print("--layout needs labels like 1,2,4,3,5,6"); exit(2) }
    case "--save-layout":
        let devs = outputDevices().filter { isManaged($0) }
        guard let d = devs.first else { print("no managed device present"); exit(1) }
        let cur = currentLayoutLabels(d.id)
        guard !cur.isEmpty else { print("\(d.name) has no description-based layout to save (configure it in Audio MIDI Setup first)"); exit(1) }
        setPrefsLayout(cur); print("saved \(d.name) layout \(describeLabels(cur)) as the runtime layout"); exit(0)
    case "--target":
        guard !args.isEmpty else { print("--target needs a number or 'default'"); exit(2) }
        let v = args.removeFirst()
        if v == "default" || v == "reset" { setPrefsTarget(nil); mode = "once"; print("runtime target cleared; back to \(baseTargetChannels) ch (plist/env)") }
        else if let n = UInt32(v), n >= 1 { setPrefsTarget(n); mode = "once"; print("runtime target set to \(n) ch; the running agent follows it within ~15 s") }
        else { print("--target needs a number or 'default'"); exit(2) }
    case "--device":
        guard !args.isEmpty else { print("--device needs a name"); exit(2) }
        onlyDevices.append(args.removeFirst())
    case "-h", "--help":
        print("usage: hdmi-audio-stereo [--status | --clients | --once | --target N|default | --layout L,L,..|default | --save-layout] [--channels N] [--device NAME ...]"); exit(0)
    default:
        print("unknown option \(a)"); exit(2)
    }
}

switch mode {
case "status": printStatus()
case "clients":
    for d in outputDevices() where isManaged(d) {
        let pids = runningOutputPIDs(on: d.id).sorted()
        print("\(d.name): " + (pids.isEmpty ? "no process is producing output" : pids.map { "\(procName($0)) [\($0)]" }.joined(separator: ", ")))
    }
case "once":
    let changed = applyFix(verbose: true, forceLayout: true)
    log(changed.isEmpty ? "nothing to change" : "fixed: \(changed.joined(separator: ", ")) -> \(targetChannels) ch")
default: Watcher().start()
}
