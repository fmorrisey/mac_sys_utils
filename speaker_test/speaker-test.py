#!/usr/bin/env python3
"""speaker-test — surround-sound channel check that works for people who are hard of hearing.

Each speaker SAYS ITS OWN NAME (via macOS `say`), so you don't have to guess where a tone came from:
if a voice saying "left rear speaker" comes out of the bar, that's the finding. The sub gets a 50 Hz hum
(note: a soundbar system sends every channel's bass to the sub, so the hum proves nothing about mapping).

    speaker-test.py all                      # intro, then each of the six, 2 s apart (about 27 s)
    speaker-test.py centre                   # one speaker, said twice (left|right|centre|sub|leftrear|rightrear)
    speaker-test.py centre --repeat 3
    speaker-test.py --build                  # regenerate the files only

Files are 6-channel WAVs in the order L R C LFE Ls Rs; afplay/AudioQueue routes them by the output
device's speaker labels (Audio MIDI Setup > Configure Speakers), i.e. the same path a game uses.
Built files live in ~/Library/Caches/speaker-test/.
"""
import argparse, math, struct, subprocess, time, wave
from pathlib import Path

SR, CH = 48000, 6
CACHE = Path.home() / "Library/Caches/speaker-test"
NAMES = {"left": (0, "front left"), "right": (1, "front right"), "centre": (2, "centre"),
         "leftrear": (4, "left rear"), "rightrear": (5, "right rear")}
ORDER = ["left", "right", "centre", "sub", "leftrear", "rightrear"]


def say(text, path):
    subprocess.run(["say", "-r", "150", "-o", str(path), f"--data-format=LEI16@{SR}", text], check=True)


def mono(path):
    w = wave.open(str(path)); n, nch = w.getnframes(), w.getnchannels()
    s = struct.unpack("<" + "h" * (n * nch), w.readframes(n)); w.close()
    return list(s[::nch])


def frames(samples, chans, gain=0.9):
    out = []
    for v in samples:
        fr = [0] * CH
        for c in chans:
            fr[c] = int(v * gain)
        out.append(struct.pack("<" + "h" * CH, *fr))
    return b"".join(out)


def silence(sec):
    return struct.pack("<" + "h" * CH, *([0] * CH)) * int(SR * sec)


def hum(sec, c=3, hz=50):
    n = int(SR * sec); out = []
    for i in range(n):
        env = min(1.0, i / 4800, (n - i) / 4800)
        fr = [0] * CH; fr[c] = int(0.8 * 32767 * math.sin(2 * math.pi * hz * i / SR) * env)
        out.append(struct.pack("<" + "h" * CH, *fr))
    return b"".join(out)


def write(path, data):
    w = wave.open(str(path), "w"); w.setnchannels(CH); w.setsampwidth(2); w.setframerate(SR); w.writeframes(data); w.close()


def build():
    CACHE.mkdir(parents=True, exist_ok=True)
    voices = {}
    for key, (c, label) in NAMES.items():
        v = CACHE / f"v_{key}.wav"; say(f"{label} speaker. {label} speaker.", v); voices[key] = mono(v)
    intro = CACHE / "v_intro.wav"; say("Speaker test starting.", intro)
    for key, (c, _) in NAMES.items():
        write(CACHE / f"sp_{key}.wav", frames(voices[key], [c]) + silence(0.5))
    write(CACHE / "sp_sub.wav", hum(5.0))
    seq = [frames(mono(intro), [0, 1]), silence(1.0)]
    for key in ORDER:
        seq.append(hum(4.0) if key == "sub" else frames(voices[key], [NAMES[key][0]])); seq.append(silence(1.5))
    write(CACHE / "sp_all.wav", b"".join(seq))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("which", nargs="?", choices=["all"] + ORDER)
    ap.add_argument("--repeat", type=int, default=2)
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--delay", type=float, default=3.0, help="seconds before playing (get to the room)")
    a = ap.parse_args()
    if a.build or not (CACHE / "sp_all.wav").exists():
        build(); print(f"built in {CACHE}")
    if not a.which:
        return
    time.sleep(a.delay)
    f = CACHE / ("sp_all.wav" if a.which == "all" else f"sp_{a.which}.wav")
    n = 1 if a.which == "all" else a.repeat
    for i in range(n):
        print(f"{time.strftime('%H:%M:%S')} playing {a.which}" + (f" ({i + 1}/{n})" if n > 1 else ""), flush=True)
        subprocess.run(["afplay", str(f)], check=False)
        if i + 1 < n:
            time.sleep(1)


if __name__ == "__main__":
    main()
