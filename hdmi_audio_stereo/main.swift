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
    guard let want = (isAggregate(d) ? desiredAggregateLayout : desiredLayout) else { return false }
    let ch = outputChannels(d.id)
    guard ch == want.count else { if verbose { log("\(d.name): layout not applied (\(ch) ch, layout has \(want.count))") }; return false }
    let cur = currentLayoutLabels(d.id)
    if cur == want && !force { if verbose { log("\(d.name): speaker layout already \(describeLabels(cur))") }; return false }
    let st = setLayout(d.id, labels: want)
    let li = want.firstIndex(of: 1).map { UInt32($0 + 1) } ?? 1, ri = want.firstIndex(of: 2).map { UInt32($0 + 1) } ?? 2
    let st2 = setStereoPair(d.id, [li, ri])
    let after = currentLayoutLabels(d.id)
    log("\(d.name): speaker layout \(cur.isEmpty ? "unset" : describeLabels(cur)) -> \(describeLabels(want))\(cur == want ? " (re-written to resync clients)" : "") \(after == want ? "OK" : "FAILED status=\(st)") (stereo pair \(li),\(ri) status \(st2))")
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
var noFormatLogged = Set<String>()
@discardableResult
func applyFix(verbose: Bool, forceLayout: Bool = false) -> [String] {
    var changed: [String] = []
    ensureAggregate(verbose: verbose)
    if aggEnabled, let a = outputDevices().first(where: isAggregate) {
        if applyLayout(a, verbose: verbose, force: forceLayout) && !changed.contains(a.name) { changed.append(a.name) }
    }
    for d in outputDevices() where isManaged(d) {
        if let h = holdUntil[d.uid], h > Date() { continue }   // link settling: leave it at 2 ch for now (settle-then-raise)
        defer { if applyLayout(d, verbose: verbose, force: forceLayout) && !changed.contains(d.name) { changed.append(d.name) } }
        for s in outputStreams(d) {
            guard let cur = getValue(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription()) else { continue }
            if cur.mChannelsPerFrame == targetChannels {
                if verbose { log("\(d.name): already \(describe(cur)) (\(d.channels) out ch)") }
                continue
            }
            guard var want = stereoCandidate(for: s, current: cur, channels: targetChannels) else {
                if !noFormatLogged.contains(d.uid) {
                    noFormatLogged.insert(d.uid)
                    log("\(d.name): no \(targetChannels)-ch PCM format at \(Int(cur.mSampleRate)) Hz offered; leaving \(describe(cur)) (not repeated)")
                }
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
    print("target: \(targetChannels) ch [\(src)] on " + (onlyDevices.isEmpty ? "every HDMI / DisplayPort output" : onlyDevices.joined(separator: ", ")) + "  (notify=\(notifyEnabled), keep-alive=\(keepaliveEnabled ? "on" : "off"), settle-then-raise=\(bounceEnabled ? "on, \(Int(settleDelay)) s" : "off"))")
    for d in outputDevices() {
        let flag = d.id == def ? "*" : " "
        let managed = isManaged(d) ? (d.channels != Int(targetChannels) ? "WOULD FIX" : "managed, ok") : (isAggregate(d) ? "stable output (aggregate around the TV)" : "ignored")
        print("\(flag) \(d.name)  [\(d.transport)]  \(d.channels) out ch  \(managed)  uid=\(d.uid)")
        if isManaged(d) || isAggregate(d) {
            let cur = currentLayoutLabels(d.id)
            let want = isAggregate(d) ? desiredAggregateLayout : desiredLayout
            print("      speaker layout: \(cur.isEmpty ? "unset/tag-based" : describeLabels(cur))" + (want.map { "   wanted: \(describeLabels($0))" } ?? "   (no layout configured)"))
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


// MARK: - stable output: an aggregate device wrapping the TV endpoint
// Every TV blink makes macOS fall back to the built-in speakers for a couple of seconds; a Wine game follows
// the default output the moment it changes and never comes back (Halo, 2026-11-20). An aggregate device that
// wraps the HDMI endpoint survives the blink, so the default output never changes and the game keeps one stream.
let aggUID = "com.fmorrisey.hdmi-audio-stereo.aggregate"
let aggName = env["HDMI_AUDIO_STEREO_AGGREGATE_NAME"] ?? "TV"
func prefsAggregate() -> Bool? {
    guard let v = CFPreferencesCopyAppValue("aggregate" as CFString, prefsDomain) else { return nil }
    return (v as? Bool) ?? ((v as? NSNumber)?.boolValue)
}
var aggEnabled: Bool { prefsAggregate() ?? ((env["HDMI_AUDIO_STEREO_AGGREGATE"] ?? "1") != "0") }
func setPrefsAggregate(_ on: Bool?) {
    CFPreferencesSetAppValue("aggregate" as CFString, on.map { $0 as CFBoolean }, prefsDomain)
    CFPreferencesAppSynchronize(prefsDomain)
}
func isAggregate(_ d: Dev) -> Bool { d.uid == aggUID }
func prefsAggregateLayout() -> [UInt32]? {
    guard let v = CFPreferencesCopyAppValue("aggregate_layout" as CFString, prefsDomain) as? String else { return nil }
    return parseLabels(v)
}
func setPrefsAggregateLayout(_ labels: [UInt32]?) {
    CFPreferencesSetAppValue("aggregate_layout" as CFString, labels.map { $0.map(String.init).joined(separator: ",") as CFString }, prefsDomain)
    CFPreferencesAppSynchronize(prefsDomain)
}
/// Labels written onto the aggregate; normally the same as the endpoint's, overridable for A/B tests by ear.
var desiredAggregateLayout: [UInt32]? { prefsAggregateLayout() ?? parseLabels(env["HDMI_AUDIO_STEREO_AGGREGATE_LAYOUT"] ?? "") ?? desiredLayout }
/// Devices whose clients and layout we care about: the real HDMI endpoints plus the aggregate in front of them.
func watched() -> [Dev] { outputDevices().filter { isManaged($0) || (aggEnabled && isAggregate($0)) } }

func findAggregate() -> AudioObjectID? {
    let ids: [AudioObjectID] = getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    return ids.first { getString($0, kAudioDevicePropertyDeviceUID) == aggUID }
}
func aggregateSubUIDs(_ agg: AudioObjectID) -> [String] {
    var a = addr(kAudioAggregateDevicePropertyFullSubDeviceList); var size = UInt32(MemoryLayout<CFArray?>.size); var arr: Unmanaged<CFArray>? = nil
    let st = withUnsafeMutablePointer(to: &arr) { AudioObjectGetPropertyData(agg, &a, 0, nil, &size, $0) }
    guard st == noErr, let cf = arr?.takeRetainedValue() else { return [] }
    return (cf as? [String]) ?? []
}
func setAggregateSub(_ agg: AudioObjectID, _ uid: String) -> (OSStatus, OSStatus) {
    var a = addr(kAudioAggregateDevicePropertyFullSubDeviceList); var arr = [uid] as CFArray
    let st = withUnsafeMutablePointer(to: &arr) { AudioObjectSetPropertyData(agg, &a, 0, nil, UInt32(MemoryLayout<CFArray>.size), $0) }
    var m = addr(kAudioAggregateDevicePropertyMainSubDevice); var cf = uid as CFString
    let st2 = withUnsafeMutablePointer(to: &cf) { AudioObjectSetPropertyData(agg, &m, 0, nil, UInt32(MemoryLayout<CFString>.size), $0) }
    return (st, st2)
}
func createAggregate(sub uid: String) -> AudioObjectID? {
    let desc: [String: Any] = [kAudioAggregateDeviceUIDKey: aggUID, kAudioAggregateDeviceNameKey: aggName,
                               kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
                               kAudioAggregateDeviceMainSubDeviceKey: uid,
                               kAudioAggregateDeviceIsPrivateKey: 0, kAudioAggregateDeviceIsStackedKey: 0]
    var id: AudioObjectID = 0
    let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id)
    if st != noErr { log("aggregate '\(aggName)': create failed status \(st)") }
    return st == noErr ? id : nil
}
func destroyAggregate() {
    guard let a = findAggregate() else { return }
    let tv = outputDevices().first(where: isManaged)
    if defaultOutput() == a, let t = tv { _ = setDefault(kAudioHardwarePropertyDefaultOutputDevice, t.id); _ = setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, t.id) }
    let st = AudioHardwareDestroyAggregateDevice(a)
    log("aggregate '\(aggName)' destroyed (status \(st))")
}
/// Create / repoint the aggregate at the TV endpoint, mirror the speaker layout onto it, and make it the default output.
func ensureAggregate(verbose: Bool) {
    guard aggEnabled else { return }
    let devs = outputDevices()
    guard let tv = devs.first(where: isManaged) else { return }
    var agg = findAggregate()
    if agg == nil {
        guard let created = createAggregate(sub: tv.uid) else { return }
        agg = created
        log("aggregate '\(aggName)' created around \(tv.name) (\(tv.uid))")
        usleep(700_000)
    } else if aggregateSubUIDs(agg!) != [tv.uid] {
        let (st, st2) = setAggregateSub(agg!, tv.uid)
        log("aggregate '\(aggName)': sub-device -> \(tv.name) (\(tv.uid)) status \(st)/\(st2)")
        usleep(700_000)
    }
    guard let a = agg else { return }
    let def = defaultOutput()
    if def != a, let cur = devs.first(where: { $0.id == def }), cur.id == tv.id || cur.transport == "bltn" {
        let st = setDefault(kAudioHardwarePropertyDefaultOutputDevice, a)
        let sys = systemOutput(); var st2: OSStatus = noErr
        if sys == tv.id || sys == def { st2 = setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, a) }
        log("default output -> '\(aggName)' (was \(cur.name); status \(st), system \(st2))")
    } else if verbose && def == a {
        log("default output is '\(aggName)' (aggregate around \(tv.name))")
    }
}

// MARK: - keep-alive: a silent stream on each managed endpoint so the HDMI audio link never stops
// The Mac only sends HDMI audio while some app plays; every restart of the stream makes the TV and the
// soundbar renegotiate, and some of those land on stereo (2026-11-20..22). A permanent silent IOProc keeps
// the link up so the bar locks onto 6-channel PCM once.
func prefsKeepalive() -> Bool? {
    guard let v = CFPreferencesCopyAppValue("keepalive" as CFString, prefsDomain) else { return nil }
    return (v as? Bool) ?? ((v as? NSNumber)?.boolValue)
}
var keepaliveEnabled: Bool { prefsKeepalive() ?? ((env["HDMI_AUDIO_STEREO_KEEPALIVE"] ?? "1") != "0") }
func setPrefsKeepalive(_ on: Bool?) {
    CFPreferencesSetAppValue("keepalive" as CFString, on.map { $0 as CFBoolean }, prefsDomain)
    CFPreferencesAppSynchronize(prefsDomain)
}
var keepaliveProcs: [AudioObjectID: AudioDeviceIOProcID] = [:]
func startKeepalive(_ d: Dev) {
    guard keepaliveEnabled else { return }
    if let pid = keepaliveProcs[d.id] { _ = AudioDeviceStart(d.id, pid); return }   // idempotent; also restarts after a format change
    var procID: AudioDeviceIOProcID? = nil
    let st = AudioDeviceCreateIOProcIDWithBlock(&procID, d.id, nil) { _, _, _, outOutput, _ in
        for buf in UnsafeMutableAudioBufferListPointer(outOutput) {
            if let m = buf.mData { memset(m, 0, Int(buf.mDataByteSize)) }
        }
    }
    guard st == noErr, let pid = procID else { log("\(d.name): keep-alive IOProc could not be created (status \(st))"); return }
    let st2 = AudioDeviceStart(d.id, pid)
    if st2 == noErr { keepaliveProcs[d.id] = pid; log("\(d.name): keep-alive silent stream started") }
    else { AudioDeviceDestroyIOProcID(d.id, pid); log("\(d.name): keep-alive start failed (status \(st2))") }
}
func pruneKeepalive(present: Set<AudioObjectID>) {
    for (id, pid) in keepaliveProcs where !present.contains(id) {
        AudioDeviceStop(id, pid); AudioDeviceDestroyIOProcID(id, pid); keepaliveProcs[id] = nil
    }
}

// MARK: - settle-then-raise after a link-up
// After every HDMI link-up (plug-in, TV power-cycle / HPD pulse, Mac wake) the endpoint comes up at 2 ch. Raising it
// to 6 ch right away (what this agent did until 2026-11-22) leaves the Sonos on a stereo stream: the TV latches the
// format it hands the soundbar while the eARC link is still coming up and ignores the change. A format change made
// once the link has settled is honoured (verified by ear 17:14 and 17:40, bounces 6->2->6 minutes after link-up).
// So: hold a managed endpoint at 2 ch for a settle delay, then raise it to the target once. Going 6 -> 2 under a
// playing Wine game drops the HDMI link for ~1.5 s (17:55), so --reinit under a game needs --force.
func prefsBounce() -> Bool? {
    guard let v = CFPreferencesCopyAppValue("bounce" as CFString, prefsDomain) else { return nil }
    return (v as? Bool) ?? ((v as? NSNumber)?.boolValue)
}
var bounceEnabled: Bool { prefsBounce() ?? ((env["HDMI_AUDIO_STEREO_BOUNCE"] ?? "1") != "0") }
func setPrefsBounce(_ on: Bool?) {
    CFPreferencesSetAppValue("bounce" as CFString, on.map { $0 as CFBoolean }, prefsDomain)
    CFPreferencesAppSynchronize(prefsDomain)
}
let settleDelay: TimeInterval = Double(env["HDMI_AUDIO_STEREO_SETTLE"] ?? env["HDMI_AUDIO_STEREO_BOUNCE_DELAY"] ?? "") ?? 25
var holdUntil = [String: Date]()     // uid -> earliest moment the raise may happen (applyFix leaves the device alone until then)
var holdExpired = [String: Date]()   // uid -> last expiry (no re-hold loop when the raise keeps failing)
/// Sets every output stream of the device to an n-channel PCM format at its current rate. True if a write succeeded.
@discardableResult
func setChannels(_ d: Dev, _ n: UInt32, out: (String) -> Void) -> Bool {
    var ok = false
    for st in outputStreams(d) {
        guard let cur = getValue(st, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription()) else { continue }
        if cur.mChannelsPerFrame == n { out("\(d.name): already \(describe(cur))"); ok = true; continue }
        guard var want = stereoCandidate(for: st, current: cur, channels: n) else { out("\(d.name): no \(n)-ch format at \(Int(cur.mSampleRate)) Hz"); continue }
        var a = addr(kAudioStreamPropertyPhysicalFormat)
        let st1 = AudioObjectSetPropertyData(st, &a, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &want)
        out("\(d.name): \(describe(cur)) -> \(describe(want)) (status \(st1))")
        if st1 == noErr { ok = true }
    }
    return ok
}
/// The quick 6 -> 2 -> 6 bounce (3 s), kept for --reinit --quick: proven twice with no game running.
@discardableResult
func bounceFormat(_ d: Dev, out: (String) -> Void) -> Bool {
    let a = setChannels(d, 2, out: out)
    sleep(3)
    guard let d2 = outputDevices().first(where: { $0.uid == d.uid }) else { out("\(d.name): endpoint vanished during the bounce"); return false }
    let b = setChannels(d2, targetChannels, out: out)
    return a && b
}
/// The watch agent's pid, so the CLI can leave the raise to it.
func agentPID() -> pid_t? {
    guard let v = CFPreferencesCopyAppValue("agent_pid" as CFString, prefsDomain) as? NSNumber else { return nil }
    let pid = pid_t(v.int32Value)
    return (pid > 0 && kill(pid, 0) == 0) ? pid : nil
}

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
        if let pid = getValue(p, selProcPID, kAudioObjectPropertyScopeGlobal, pid_t(0)), pid > 0, pid != getpid(),
           procName(pid) != "hdmi-audio-stereo" { out.insert(pid) }   // the agent's own keep-alive stream is not a client
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
    var startupDone = false
    var holdWork = [String: DispatchWorkItem]()

    func fix(verbose: Bool, forceLayout: Bool = false) -> [String] { noteHolds(); return applyFix(verbose: verbose, forceLayout: forceLayout) }

    /// A managed endpoint below the target = the link just came up (or someone set 2 ch on purpose). Hold it there
    /// for the settle delay, then raise it once. Called before every fix pass.
    func noteHolds() {
        guard bounceEnabled else { return }
        for d in outputDevices() where isManaged(d) {
            if holdUntil[d.uid] != nil { continue }
            if let e = holdExpired[d.uid], Date().timeIntervalSince(e) < 60 { continue }
            let below = outputStreams(d).contains { st in
                (getValue(st, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription())?.mChannelsPerFrame ?? targetChannels) < targetChannels
            }
            guard below else { continue }
            holdUntil[d.uid] = Date().addingTimeInterval(settleDelay)
            log("\(d.name) is below \(targetChannels) ch (link just came up?); raising it in \(Int(settleDelay)) s so the TV hands the soundbar \(targetChannels) ch")
            let uid = d.uid
            let w = DispatchWorkItem { [self] in raise(uid: uid) }
            holdWork[uid] = w
            q.asyncAfter(deadline: .now() + settleDelay, execute: w)
        }
    }

    func raise(uid: String) {
        holdUntil[uid] = nil; holdWork[uid] = nil; holdExpired[uid] = Date()
        guard let d = outputDevices().first(where: { $0.uid == uid && isManaged($0) }) else { log("raise skipped: endpoint gone"); return }
        let changed = fix(verbose: false, forceLayout: true)
        let ok = changed.contains(d.name) && outputChannels(d.id) == Int(targetChannels)
        log("raised after settle: \(d.name) -> \(ok ? "\(targetChannels) ch OK" : "no change (\(outputChannels(d.id)) out ch)")")
        if ok { notify(title: "HDMI audio \(targetChannels) ch", body: "\(d.name) raised after the link settled") }
    }

    /// The endpoint got a new object id (link-up): forget any hold from the previous link so the delay starts afresh.
    func restartHold(uid: String) {
        guard startupDone else { return }
        holdWork[uid]?.cancel(); holdWork[uid] = nil; holdUntil[uid] = nil; holdExpired[uid] = nil
    }

    /// Every few seconds: did a new process start producing output on a managed device? Then the
    /// layout gets written again so that client maps its channels onto the right speakers.
    func pollClients() {
        var newcomers: [String] = []
        for d in watched() {
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
        _ = fix(verbose: false, forceLayout: true)
        q.asyncAfter(deadline: .now() + 3.0) { [self] in _ = fix(verbose: false, forceLayout: true) }
    }

    func noteDefault() {
        let def = defaultOutput()
        if let d = outputDevices().first(where: { $0.id == def }) {
            lastDefaultName = d.name
            lastDefaultWasManaged = isManaged(d) || isAggregate(d)
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
           !devs.contains(where: { $0.name == name && (isManaged($0) || isAggregate($0)) }) {
            pendingRestore = name
            pendingRestoreSystem = lastDefaultWasSystemToo
            log("default output fell back to \(c.name) because \(name) vanished; will hand it back when \(name) returns")
        }
        noteDefault()
    }

    func restoreIfPossible() {
        // General rule: the built-in speakers are never the wanted output while a managed display endpoint is
        // present (2026-11-22: coming from the desk, whose default was the Scarlett, the TV was never handed the default).
        if restoreDefault, pendingRestore == nil {
            let devs = outputDevices()
            if let cur = devs.first(where: { $0.id == defaultOutput() }), cur.transport == "bltn",
               let tv = devs.first(where: { isManaged($0) || (aggEnabled && isAggregate($0)) }) {
                let st = setDefault(kAudioHardwarePropertyDefaultOutputDevice, tv.id)
                let st2 = setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, tv.id)
                log("default output was \(cur.name) with \(tv.name) present; moved to \(tv.name) (status \(st), system \(st2))")
                if st == noErr { notify(title: "Audio on \(tv.name)", body: "Default output moved off the built-in speakers") }
                noteDefault()
                return
            }
        }
        guard let name = pendingRestore else { return }
        let devs = outputDevices()
        guard let d = devs.first(where: { $0.name == name && (isManaged($0) || isAggregate($0)) }) else { return }
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
        startupDone = true
        CFPreferencesSetAppValue("agent_pid" as CFString, NSNumber(value: Int32(getpid())), prefsDomain); CFPreferencesAppSynchronize(prefsDomain)
        // belt and braces: a quiet periodic re-check in case a notification is missed
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + recheckSeconds, repeating: recheckSeconds)
        t.setEventHandler { [self] in
            let changed = fix(verbose: false)
            if !changed.isEmpty { announce(changed, reason: "periodic re-check") }
            // while a Wine game is playing, quietly re-write the layout each pass (no notification)
            if watched().contains(where: { d in runningOutputPIDs(on: d.id).contains(where: { procName($0).lowercased().hasSuffix(".exe") }) }) {
                for d in watched() { _ = applyLayout(d, verbose: false, force: true) }
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
        let devs = outputDevices()
        pruneKeepalive(present: Set(devs.map { $0.id }))
        for d in devs where isManaged(d) { startKeepalive(d) }
        for d in devs where isManaged(d) {
            if !hooked.contains(d.id) {
                hooked.insert(d.id)
                restartHold(uid: d.uid)
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
            hookDevices(); fixNow(reason: why, verbose: false); restoreIfPossible()
            q.asyncAfter(deadline: .now() + 4.0) { [self] in
                let changed = fix(verbose: false, forceLayout: true)
                if !changed.isEmpty { announce(changed, reason: why + " (second pass)") }
                hookDevices(); restoreIfPossible()
            }
        }
        pending = w
        q.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func fixNow(reason: String, verbose: Bool) {
        let changed = fix(verbose: verbose, forceLayout: true)
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
var forceReinit = false   // --reinit --force: go ahead while a Wine .exe is playing on the endpoint (one picture blink)
var quickReinit = false   // --reinit --quick: the 3 s 6->2->6 bounce instead of settle-then-raise
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--status": mode = "status"
    case "--clients": mode = "clients"
    case "--reinit": mode = "reinit"
    case "--force": forceReinit = true
    case "--quick": quickReinit = true
    case "--bounce":
        guard !args.isEmpty else { print("usage: --bounce on|off"); exit(2) }
        let v = args.removeFirst().lowercased()
        if v == "on" || v == "off" { setPrefsBounce(v == "on"); print("settle-then-raise after link-up: \(v)"); exit(0) }
        print("usage: --bounce on|off"); exit(2)
    case "--keepalive":
        guard !args.isEmpty else { print("usage: --keepalive on|off"); exit(2) }
        let v = args.removeFirst().lowercased()
        if v == "on" || v == "off" { setPrefsKeepalive(v == "on"); print("keep-alive \(v); the agent follows it within ~15 s") ; exit(0) }
        print("usage: --keepalive on|off"); exit(2)
    case "--aggregate-layout":
        guard !args.isEmpty else { print("--aggregate-layout needs labels like 1,2,3,4,5,6 or 'default'"); exit(2) }
        let v = args.removeFirst()
        if v == "default" || v == "reset" { setPrefsAggregateLayout(nil); mode = "once"; print("aggregate layout follows the endpoint layout again") }
        else if let l = parseLabels(v) { setPrefsAggregateLayout(l); mode = "once"; print("aggregate layout set to \(describeLabels(l)); written now and kept by the agent") }
        else { print("bad labels"); exit(2) }
    case "--aggregate":
        guard !args.isEmpty else { print("usage: --aggregate on|off"); exit(2) }
        let v = args.removeFirst().lowercased()
        if v == "on" { setPrefsAggregate(true); mode = "once"; print("stable output (aggregate) enabled; the agent creates it and makes it the default output") }
        else if v == "off" { setPrefsAggregate(false); destroyAggregate(); mode = "status"; print("stable output disabled; aggregate removed, default output back on the TV endpoint") }
        else { print("usage: --aggregate on|off"); exit(2) }
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
        print("usage: hdmi-audio-stereo [--status | --clients | --once | --reinit [--force] [--quick] | --aggregate on|off | --keepalive on|off | --bounce on|off | --aggregate-layout L,L,..|default | --target N|default | --layout L,L,..|default | --save-layout] [--channels N] [--device NAME ...]"); exit(0)
    default:
        print("unknown option \(a)"); exit(2)
    }
}

switch mode {
case "status": printStatus()
case "reinit":
    // Set the endpoint to 2 ch; after the settle delay it goes back to the target (the agent does it if it runs,
    // otherwise this command waits). 6 -> 2 under a playing Wine game drops the HDMI link for ~1.5 s: --force.
    for d in outputDevices() where isManaged(d) {
        if let pid = runningOutputPIDs(on: d.id).first(where: { procName($0).lowercased().hasSuffix(".exe") }) {
            if forceReinit { print("\(d.name): \(procName(pid)) is playing on it; going ahead (--force): expect one picture blink") }
            else { print("\(d.name): \(procName(pid)) is playing on it; add --force (one picture blink) or quit the game first"); exit(1) }
        }
        if quickReinit {
            bounceFormat(d) { print($0) }
            _ = applyLayout(d, verbose: false, force: true)
            print("\(d.name): quick bounce done, layout re-applied")
            continue
        }
        setChannels(d, 2) { print($0) }
        if let pid = agentPID() {
            print("\(d.name): held at 2 ch; the agent (pid \(pid)) raises it to \(targetChannels) ch in ~\(Int(settleDelay)) s once the TV-soundbar link has settled")
            continue
        }
        print("\(d.name): waiting \(Int(settleDelay)) s for the TV-soundbar link to settle, then raising to \(targetChannels) ch")
        sleep(UInt32(settleDelay))
        guard let d2 = outputDevices().first(where: { $0.uid == d.uid }) else { print("\(d.name): endpoint gone"); continue }
        setChannels(d2, targetChannels) { print($0) }
        _ = applyLayout(d2, verbose: false, force: true)
        print("\(d2.name): layout re-applied")
    }
case "clients":
    for d in watched() {
        let pids = runningOutputPIDs(on: d.id).sorted()
        print("\(d.name): " + (pids.isEmpty ? "no process is producing output" : pids.map { "\(procName($0)) [\($0)]" }.joined(separator: ", ")))
    }
case "once":
    let changed = applyFix(verbose: true, forceLayout: true)
    log(changed.isEmpty ? "nothing to change" : "fixed: \(changed.joined(separator: ", ")) -> \(targetChannels) ch")
default: Watcher().start()
}
