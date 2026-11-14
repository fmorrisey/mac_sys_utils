# 🔊 hdmi_audio_stereo

Keeps HDMI / DisplayPort audio endpoints (TVs, monitors) in a **consistent channel count and speaker
assignment**, automatically, every time one is plugged in: 5.1 with the right channel order for a
soundbar / AVR over eARC, or plain stereo for TV speakers. Fixes the "surround channels are messed
up / dialogue is missing" problem on a Mac plugged into a TV, with Wine / Porting Kit / CrossOver
games or anything else. (The name is from its first job; it does both.)

- **Why it happens.** A TV or monitor that advertises 5.1 / 7.1 PCM in its EDID makes CoreAudio
  publish a 6- or 8-channel output device. Wine's `winecoreaudio` builds the WASAPI mix format
  from that channel count, so Unreal and Unity games mix surround and put dialogue on a centre
  channel that the TV's stereo speakers never play. Music and effects (front L/R) still work,
  which is why it sounds "mostly fine but the voices are gone".
- **Why Audio MIDI Setup doesn't stick.** coreaudiod remembers the chosen format *and the
  "Configure Speakers" assignment per device UID*, and the same TV gets a different UID per port,
  EDID variant or picture mode (one Samsung TV showed up under eight UIDs), so the next plug-in
  comes back with the default format and no speaker assignment.
- **Why the speaker assignment matters.** HDMI carries 5.1 PCM as L R **LFE C** Ls Rs. Without an
  assignment macOS assumes L R **C LFE** Ls Rs, so dialogue lands in the subwoofer slot and the
  bass in the centre: "the surround channels are messed up". `--layout 1,2,4,3,5,6` is that wire
  order, and the agent re-applies it to every new identity.
- **What this does.** A tiny Swift agent subscribes to CoreAudio's device-list, default-output and
  stream-format notifications. Whenever a display-audio endpoint appears or its format changes,
  it sets the stream to the best stereo PCM format at the current sample rate (e.g. 2 ch 48 kHz
  24-bit) and tells you with a notification. Event-driven, no polling (a quiet 15-second re-check
  is the only timer), no sudo. Each event is checked twice, 1.5 s and 5.5 s after it, because a freshly plugged endpoint can appear before its streams report their real format.
- **Re-writes the assignment after every blink.** Clients that stay attached across a hot-plug (Wine's audio unit, for one) come back with their channels crossed even though the device still reports the right assignment; writing it again makes CoreAudio tell them to reconfigure, which is what redoing "Configure Speakers" by hand used to fix.
- **Hands the default output back.** On a hot-plug blink macOS falls back to the built-in
  speakers, and when the TV returns under a different EDID identity it does not always get the
  default back. The agent notices that the fallback happened *because* the managed endpoint
  vanished, and re-selects it when it reappears. A deliberate switch to the speakers while the TV
  is present is never overridden.
- **Reversible.** `hdmi-audio-stereo --once --channels 6` puts an endpoint back to 5.1 for the
  session; uninstalling leaves formats as they are.

## Requirements

- macOS on Apple Silicon or Intel (tested on macOS 26 / M5 Pro with a Samsung TV over HDMI)
- Xcode Command Line Tools for `swiftc` (`xcode-select --install`)

## Install

```bash
./hdmi_audio_stereo/install.sh
```

That builds the binary to `~/.local/bin/hdmi-audio-stereo`, writes the LaunchAgent to
`~/Library/LaunchAgents/com.fmorrisey.hdmi-audio-stereo.plist`, starts it, and prints what it
sees. The agent starts automatically at every login from then on. Re-run the script after editing
`main.swift` or the plist; it rebuilds and restarts in place.

## Use

Nothing to do. Plug the Mac into the TV: the endpoint is forced to stereo within about two
seconds and you get a notification. Games launched after that mix 2.0.

```bash
hdmi-audio-stereo --status                   # every output device, its stream format, what would change
hdmi-audio-stereo --once                     # fix now and exit (no agent needed)
hdmi-audio-stereo --target 2                 # TV-speakers night: keep the endpoint stereo
hdmi-audio-stereo --target default           # back to the plist default (6 ch as shipped here)
hdmi-audio-stereo --layout 1,2,4,3,5,6       # speaker assignment to enforce (labels per device channel)
hdmi-audio-stereo --save-layout              # capture what you set in Audio MIDI Setup as the assignment to enforce
hdmi-audio-stereo --layout default           # stop enforcing a layout
tail -f ~/Library/Logs/hdmi-audio-stereo.log # every decision it makes
```

> `--target` is remembered in your user preferences and picked up by the running agent within
> seconds, so no reinstall or restart is needed to switch between stereo and surround.
>
> A game that is already running keeps the mix format it started with. Launch (or relaunch)
> the game after the endpoint is stereo. Changing the format also makes coreaudiod re-publish
> the device, and macOS may pick it as the default output again at that moment.

### Agent control

```bash
launchctl kickstart -k "gui/$(id -u)/com.fmorrisey.hdmi-audio-stereo"   # restart
launchctl bootout   "gui/$(id -u)/com.fmorrisey.hdmi-audio-stereo"      # stop until next login / install
```

## Tuning

Environment variables in the plist (`EnvironmentVariables`), or on the command line for one-off runs:

| Variable | Default | Meaning |
| --- | --- | --- |
| `HDMI_AUDIO_STEREO_CHANNELS` | `6` | Target channel count (`--target N` overrides at runtime, `--channels N` for one invocation) |
| `HDMI_AUDIO_STEREO_LAYOUT` | `1,2,4,3,5,6` | Speaker assignment (CoreAudio channel labels per device channel: 1=L 2=R 3=C 4=LFE 5=Ls 6=Rs); applied when the endpoint has that many channels (`--layout` overrides at runtime) |
| `HDMI_AUDIO_STEREO_DEVICES` | *(empty = every HDMI / DisplayPort output)* | Comma-separated device names to manage instead, e.g. `SAMSUNG` (`--device NAME` adds one) |
| `HDMI_AUDIO_STEREO_NOTIFY` | `1` | `0` turns off the macOS notification |
| `HDMI_AUDIO_STEREO_RESTORE_DEFAULT` | `1` | `0` stops it re-selecting a vanished-and-returned endpoint as the default output |

USB, Thunderbolt and built-in devices are never touched unless you name them. (A USB interface
such as a Scarlett 18i8 has the same 8-channel problem, but its channels are real outputs, so
the right fix there is a mixer downmix, not a format change.)

## How it works

1. `kAudioHardwarePropertyDevices` / `kAudioHardwarePropertyDefaultOutputDevice` listeners on the
   system object catch hot-plug and default-device changes; a `kAudioDevicePropertyStreamConfiguration`
   listener on each managed device and a `kAudioStreamPropertyPhysicalFormat` listener on each of its
   output streams catch a format being flipped back (by coreaudiod, Audio MIDI Setup or an app).
2. Notifications are debounced for 1.5 s (hot-plug fires a burst), then every managed device whose
   output stream has a different channel count is set to the best matching PCM format: same sample
   rate, linear PCM, same bit depth as now if offered, otherwise the deepest. The result is verified
   by reading the format back.
3. `kAudioDevicePropertyStreamConfiguration` (the channel count Wine reads) follows the stream format,
   so games see a 2-channel device.

## Uninstall

```bash
./hdmi_audio_stereo/uninstall.sh
```
