# display_mode

Tiny CoreGraphics CLI that lists every mode the current display offers (with the
IOKit mode id, logical and pixel size, refresh rate and whether it is HiDPI) and
can switch to one by id. Written for the Samsung TV in the living room, which
hands the Mac a different EDID depending on its own state: sometimes the full
HDMI 2.1 list (2560x1440 and 3840x2160 at 100/120 Hz), sometimes a cut-down one
with nothing above 60 Hz at 1440p. `system_profiler` only shows the current mode,
and System Settings hides most of the list, so this is the quick way to see what
the TV is actually offering right now.

```
./build.sh                  # swiftc -O -> ~/.local/bin/display-mode
display-mode                # list: identity (vendor/model), CURRENT mode, modes >= 1920 wide
display-mode set 172        # switch to the mode with io=172
```

Reading the identity line: `vendor=0x4c2d` is Samsung; the `model` is the EDID
product code and changes with the TV's EDID variant. Seen so far:

| model  | what it offered                                      |
|--------|------------------------------------------------------|
| 0x73ac | full list: 1440p @ 100/120, 4K @ 100/120 (good nights) |
| 0x7417 | full list, used at 1440p @ 120                        |
| 0x73ab | cut down: 1080p @ 120 but 1440p/4K only up to 60 Hz   |

Notes
- A mode switch re-trains the HDMI link for a second or two. With the lid
  closed that is fine, but it resets the HDMI audio endpoint, so a game that is
  running under Wine will usually lose its sound and need a relaunch. Switch
  before launching the game, not during.
- Modes marked HiDPI render a 2x backing store (5120x2880 for "2560x1440") that
  WindowServer scales for the TV. The non-HiDPI twin of the same size/refresh
  is cheaper for games.
- If the TV comes up with the cut-down list, switching the TV to another input
  and back (or Input Signal Plus off/on for that HDMI port) makes it re-present
  its EDID; the Mac re-reads it on the hot-plug.
