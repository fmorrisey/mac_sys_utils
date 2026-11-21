# display_mode

Keeps an external display (the living-room Samsung TV) on the mode you actually
want, every time it is plugged in, so you stop doing it in System Settings. Also
a plain CLI for listing and switching modes by id.

Why this exists: the TV presents different EDIDs depending on its own state.
Sometimes the full HDMI 2.1 list (2560x1440 and 3840x2160 at 100/120 Hz),
sometimes a cut-down one with nothing above 60 Hz at 1440p. macOS keeps whatever
it read when the link came up, can park the desktop on 25 Hz, and System
Settings' refresh-rate dropdown goes stale. `system_profiler` only shows the
current mode.

```
./install.sh                # swiftc -> ~/.local/bin/display-mode, installs + starts the LaunchAgent
display-mode                # list: identity (vendor/model), CURRENT mode, preferred-available, modes >= 1920 wide
display-mode set 172        # switch the external display to the mode with io=172
display-mode --apply        # one-shot: pick the preferred mode now
./uninstall.sh
```

The agent (`display-mode --watch`, LaunchAgent `com.fmorrisey.display-mode`)
- on startup and on every display add/enable/mode-change event (debounced 3 s,
  second pass 10 s later because the mode list can grow after the EDID settles),
  picks the first entry of `DISPLAY_MODE_PREFER` the display offers and switches
  to it;
- does **not** switch while a Wine game is running (a mode switch drops the HDMI
  audio endpoint for a few seconds and the game loses its sound); it notifies and
  switches by itself once the game quits (`DISPLAY_MODE_GAME_GUARD=0` disables);
- notifies once per TV identity when the TV came up with the cut-down list, so
  you know a TV power-cycle or input switch is the only thing left to do;
- logs to `~/Library/Logs/display-mode.log`.

Settings live in the plist's `EnvironmentVariables`:

| variable | default | meaning |
|---|---|---|
| `DISPLAY_MODE_PREFER` | `2560x1440@120,2560x1440@100,1920x1080@120,2560x1440@60` | order of preference; append `hidpi` for a scaled mode |
| `DISPLAY_MODE_VENDOR` | `0x4c2d` (Samsung) | only manage displays from this EDID vendor; unset = any external display |
| `DISPLAY_MODE_NOTIFY` | `1` | macOS notifications |
| `DISPLAY_MODE_GAME_GUARD` | `1` | leave the mode alone while a `*.exe` game process runs |

Reading the identity line: `vendor=0x4c2d` is Samsung; `model` is the EDID
product code and changes with the TV's EDID variant. Seen so far:

| model  | what it offered |
|--------|-----------------|
| 0x73ac | full list: 1440p @ 100/120, 4K @ 100/120 |
| 0x7417 | full list, used at 1440p @ 120 |
| 0x73ab | cut down: 1080p @ 120 but 1440p/4K only up to 60 Hz |

Notes
- Modes marked HiDPI render a 2x backing store (5120x2880 for "2560x1440") that
  WindowServer scales for the TV; the non-HiDPI twin is cheaper for games. The
  defaults prefer non-HiDPI.
- A mode switch re-trains the HDMI link for a second or two and resets the HDMI
  audio endpoint; hdmi_audio_stereo puts the channel count and speaker layout
  back by itself.
- Nothing on the Mac can make the TV re-present its EDID. Forcing display sleep
  to provoke a re-handshake sent the lid-closed Mac into deep idle (2026-11-20);
  don't. Power-cycle the TV or switch its input instead.
