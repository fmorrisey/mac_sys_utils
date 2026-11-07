# 📡 wifi_autoswitch

Turns Wi-Fi **off** the moment a wired Ethernet link (Thunderbolt dock, USB adapter, anything)
comes up with a usable IP address, and turns it back **on** when the wired link goes away.
One less thing to do when docking and undocking a MacBook.

- **Port-agnostic.** Every wired Ethernet port the Mac can see is a candidate; the first one with
  an active link *and* a real IPv4 address wins. Nothing is hardcoded to a specific `enX`.
- **Event-driven.** A tiny Swift daemon subscribes to macOS SystemConfiguration link/IPv4 change
  notifications. It reacts in about a second and never polls.
- **Edge-triggered.** It acts only when the *wired* state changes. Turn Wi-Fi on manually while
  docked (AirDrop, Handoff, iPhone hotspot) and it stays on until the next unplug/replug.
- **Fail-safe.** It needs a real IPv4 on the wired link before it drops Wi-Fi. A dead switch port or
  a failed DHCP (169.254.x.x) will never leave you offline.
- No sudo. Runs as a per-user LaunchAgent; `networksetup` lets admin users toggle Wi-Fi power.

## Requirements

- macOS on Apple Silicon or Intel (tested on macOS 26 / M5 Pro)
- Xcode Command Line Tools for `swiftc` (`xcode-select --install`)
- An admin account (required by `networksetup -setairportpower`)

## Install

```bash
./wifi_autoswitch/install.sh
```

That builds the binary to `~/.local/bin/wifi-autoswitch`, writes the LaunchAgent to
`~/Library/LaunchAgents/com.fmorrisey.wifi-autoswitch.plist`, starts it, and prints what it sees.
The agent starts automatically at every login from then on. Re-run the script after editing
`main.swift` or the plist; it rebuilds and restarts in place.

## Use

Nothing to do. Plug in: Wi-Fi goes off and you get a notification. Unplug: Wi-Fi comes back.

```bash
wifi-autoswitch --status                    # what it sees right now
tail -f ~/Library/Logs/wifi-autoswitch.log  # every decision it makes
```

Example log from a dock cycle:

```
20:22:04 wired UP at startup [startup]: USB 10/100/1G/2.5G LAN (en9) 192.168.0.234
20:22:04 Wi-Fi (en0) turned OFF
21:48:20 wired DOWN [en9/Link en9/IPv4 State:/Network/Interface]
21:48:20 Wi-Fi (en0) turned ON
21:50:15 wired UP [en9/IPv4]: USB 10/100/1G/2.5G LAN (en9) 192.168.0.234
21:50:16 Wi-Fi (en0) turned OFF
```

The tag in brackets is the dynamic-store key that triggered the decision. `en9/IPv4` on a replug
means it waited for DHCP to finish before dropping Wi-Fi, which is the intended behaviour.

### Agent control

```bash
launchctl print     gui/$(id -u)/com.fmorrisey.wifi-autoswitch | grep -E 'state|pid'
launchctl kickstart -k gui/$(id -u)/com.fmorrisey.wifi-autoswitch     # restart
launchctl bootout      gui/$(id -u)/com.fmorrisey.wifi-autoswitch     # stop until next install/login
```

## Tuning

Set these under `EnvironmentVariables` in the plist, then re-run `install.sh`.

| Variable                     | Default | Meaning |
|------------------------------|---------|---------|
| `WIFI_AUTOSWITCH_IFACES`     | *(auto)*| Space/comma list of BSD names (e.g. `en9`) to consider instead of every wired port |
| `WIFI_AUTOSWITCH_UP_GRACE`   | `1`     | Seconds after link + IP before Wi-Fi goes off |
| `WIFI_AUTOSWITCH_DOWN_GRACE` | `6`     | Seconds after link loss before Wi-Fi comes back; absorbs link flaps on sleep/wake and dock re-enumeration |
| `WIFI_AUTOSWITCH_NOTIFY`     | `1`     | `0` silences the macOS notifications |
| `WIFI_AUTOSWITCH_DEBUG`      | `0`     | `1` logs every raw network event (noisy; for troubleshooting) |

Auto-discovery takes every `SCNetworkInterface` of type Ethernet except Wi-Fi itself, the
IP-over-Thunderbolt ports (`Thunderbolt 1/2/3`, used for Mac-to-Mac networking) and Apple's
internal `Ethernet Adapter (enX)` pseudo-interfaces.

## How it works

`main.swift` opens an `SCDynamicStore` session and asks to be notified on
`State:/Network/Interface/*/Link`, `State:/Network/Interface/*/IPv4` and the interface list.
Bursts of events are coalesced with a grace timer whose length depends on the direction of the
change. When the timer fires it re-reads the real state: *wired up* means some candidate interface
has `Link.Active == true` and an IPv4 address outside `169.254/16`. If that boolean differs from
the last one it saw, it calls `networksetup -setairportpower <wifi> off|on` and posts a
notification. If it does not differ, it does nothing, which is what makes manual Wi-Fi toggles
stick.

At startup it syncs once in both directions, so logging in while docked turns Wi-Fi off and
rebooting after undocking turns it back on.

## Uninstall

```bash
./wifi_autoswitch/uninstall.sh
```
