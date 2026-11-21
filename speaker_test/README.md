# speaker_test

Surround-channel check that doesn't need good ears. Each speaker **says its own
name** through the current default output (6-channel WAV, routed by the output
device's speaker labels, the same path a game uses), so the finding is simply
"the voice saying *left rear* came out of the bar". The sub gets a 50 Hz hum,
which proves nothing on a soundbar system (all bass is sent to the sub anyway).

```
./speaker-test.py all            # intro + the six channels, 2 s apart
./speaker-test.py rightrear      # one channel, said twice (left right centre sub leftrear rightrear)
./speaker-test.py --build        # regenerate the WAVs (needs `say`)
```

What the results mean (TV + Sonos chain, 6-channel LPCM over HDMI/eARC):
- every voice from the right speaker → Mac assignment, TV pass-through and the bar are all fine
- centre / rears from the fronts only → the TV is folding to stereo (Digital Output Audio Format on PCM, or plain ARC instead of eARC)
- each voice exactly one speaker "late" (front right at the sub, centre at left rear, left rear at right rear, right rear at the bar) → channel-alignment slip in the HDMI audio stream; seen 2026-11-20 after several TV link drops; a TV input switch did not clear it; try `hdmi-audio-stereo --reinit` with no game running
- one voice swapped with another → a label swap on the Mac side (Audio MIDI Setup > Configure Speakers, or `hdmi-audio-stereo --layout`)
