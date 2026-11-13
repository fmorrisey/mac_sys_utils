// hdmi-audio-stereo — keep HDMI / DisplayPort audio endpoints (TVs, monitors) in stereo.
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
//   --channels N                   target channel count (default 2; also HDMI_AUDIO_STEREO_CHANNELS)
//   --device NAME                  act only on this device name (repeatable; also HDMI_AUDIO_STEREO_DEVICES=a,b)
//
// Env: HDMI_AUDIO_STEREO_NOTIFY=0 disables the macOS notification on each change.
//      HDMI_AUDIO_STEREO_RESTORE_DEFAULT=0 stops it re-selecting a display endpoint as the
//      default output after that endpoint vanished and came back (macOS falls back to the
//      built-in speakers on a hot-plug blink and does not always hand the default back).

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - config

let env = ProcessInfo.processInfo.environment
var targetChannels = UInt32(env["HDMI_AUDIO_STEREO_CHANNELS"] ?? "") ?? 2
var onlyDevices: [String] = (env["HDMI_AUDIO_STEREO_DEVICES"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
let notifyEnabled = env["HDMI_AUDIO_STEREO_NOTIFY"] != "0"
let restoreDefault = env["HDMI_AUDIO_STEREO_RESTORE_DEFAULT"] != "0"
let recheckSeconds: TimeInterval = 60

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
/// (so `--once --channels 6` also restores multichannel). Returns the names changed.
@discardableResult
func applyFix(verbose: Bool) -> [String] {
    var changed: [String] = []
    for d in outputDevices() where isManaged(d) {
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
    print("target: \(targetChannels) ch on " + (onlyDevices.isEmpty ? "every HDMI / DisplayPort output" : onlyDevices.joined(separator: ", ")) + "  (notify=\(notifyEnabled))")
    for d in outputDevices() {
        let flag = d.id == def ? "*" : " "
        let managed = isManaged(d) ? (d.channels != Int(targetChannels) ? "WOULD FIX" : "managed, ok") : "ignored"
        print("\(flag) \(d.name)  [\(d.transport)]  \(d.channels) out ch  \(managed)  uid=\(d.uid)")
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
        log("hdmi-audio-stereo starting: target=\(targetChannels)ch devices=" + (onlyDevices.isEmpty ? "all hdmi/dprt" : onlyDevices.joined(separator: ",")) + " notify=\(notifyEnabled) restore_default=\(restoreDefault)")
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
            hookDevices()
            restoreIfPossible()
        }
        t.resume()
        timer = t
        CFRunLoopRun()
    }
    var timer: DispatchSourceTimer?

    func listen(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ why: String) {
        var a = addr(sel, scope)
        AudioObjectAddPropertyListenerBlock(obj, &a, q) { [self] _, _ in schedule(why) }
    }

    func hookDevices() {
        for d in outputDevices() where isManaged(d) {
            if !hooked.contains(d.id) {
                hooked.insert(d.id)
                listen(d.id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, "\(d.name) stream configuration changed")
            }
            for s in outputStreams(d) where !hooked.contains(s) {
                hooked.insert(s)
                listen(s, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, "\(d.name) stream format changed")
            }
        }
    }

    /// Debounce: hot-plug fires a burst of notifications; act once, 1.5 s after the last one.
    func schedule(_ why: String) {
        pending?.cancel()
        let w = DispatchWorkItem { [self] in fixNow(reason: why, verbose: false); hookDevices(); restoreIfPossible() }
        pending = w
        q.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func fixNow(reason: String, verbose: Bool) {
        let changed = applyFix(verbose: verbose)
        if !changed.isEmpty { announce(changed, reason: reason) }
        else if !verbose { log("\(reason): nothing to change") }
    }

    func announce(_ names: [String], reason: String) {
        log("fixed (\(reason)): \(names.joined(separator: ", ")) -> \(targetChannels) ch")
        notify(title: "HDMI audio set to stereo", body: names.joined(separator: ", "))
    }
}

// MARK: - main

var args = Array(CommandLine.arguments.dropFirst())
var mode = "watch"
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--status": mode = "status"
    case "--once": mode = "once"
    case "--channels":
        guard !args.isEmpty, let n = UInt32(args.removeFirst()), n >= 1 else { print("--channels needs a number"); exit(2) }
        targetChannels = n
    case "--device":
        guard !args.isEmpty else { print("--device needs a name"); exit(2) }
        onlyDevices.append(args.removeFirst())
    case "-h", "--help":
        print("usage: hdmi-audio-stereo [--status | --once] [--channels N] [--device NAME ...]"); exit(0)
    default:
        print("unknown option \(a)"); exit(2)
    }
}

switch mode {
case "status": printStatus()
case "once":
    let changed = applyFix(verbose: true)
    log(changed.isEmpty ? "nothing to change" : "fixed: \(changed.joined(separator: ", ")) -> \(targetChannels) ch")
default: Watcher().start()
}
