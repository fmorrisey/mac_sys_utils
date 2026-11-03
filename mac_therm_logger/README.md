# 🖥️ Mac Thermal Logger & Analyzer

A small CLI tool that records your Mac's thermal state over time and tells you **when it
throttled, how hard, and what was running when it did**. Works on Apple Silicon (M1–M5)
and Intel Macs.

Perfect for questions like: *is my MacBook throttling when I game lid-closed? Do the fans
actually spin up? What was eating the CPU when it went to "Thermal Emergency Sleep"?*

## 🔧 What it records (one sample per interval)

| Signal | Apple Silicon | Intel | Source |
|---|---|---|---|
| Thermal pressure level (Nominal → Moderate → Heavy → Trapping → Sleeping) | ✅ | – | `powermetrics` |
| Fan RPM, CPU & GPU die temperature | ✅ | – | `powermetrics` |
| E/P-cluster and GPU frequency, CPU/GPU/combined power | ✅ | – | `powermetrics` |
| `CPU_Speed_Limit` / scheduler limit (the classic throttle %) | once pressure engages | ✅ | `pmset -g therm` |
| `kernel_task` CPU % | ✅ | ✅ | `top` |
| Load averages, top 5 processes by CPU | ✅ | ✅ | `top`, `sysctl` |
| Lid open/closed, AC vs battery, battery % | ✅ | ✅ | `ioreg`, `pmset` |
| New **Thermal Emergency Sleep** / **Clamshell Sleep** events in the power log | ✅ | ✅ | `pmset -g log` |

When you stop it (Ctrl+C or after `-n` samples) it runs the analyzer automatically and
prints a summary: pressure distribution, temperature/fan/frequency ranges, every
throttling episode with its duration and top process, and the hottest samples with what
was running at the time. `--csv` exports every sample for spreadsheets.

## 📦 Requirements

![Shell Script](https://img.shields.io/badge/script-bash-blue)
![Python 3](https://img.shields.io/badge/python-3.8%2B-yellow)
![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)

No third-party tools. **On Apple Silicon, temperatures, fan speed and thermal pressure
are only available through `powermetrics`, which needs root** — the script asks for your
password once and refreshes the sudo ticket on each sample. Pass `--no-sudo` to skip that
(you still get pmset/top/load/events, just no temps).

## 🚀 Quick start

```bash
chmod +x mac_therm_logger/mac_therm_logger.sh
./mac_therm_logger/mac_therm_logger.sh            # every 60 s until Ctrl+C
```

Useful variations:

```bash
./mac_therm_logger.sh -i 10 -n 60 -l halo-clamshell   # 10-minute run, 10 s samples, tagged log
./mac_therm_logger.sh -i 10 -n 60 -l halo-lid-open    # …then the A/B run
./mac_therm_logger.sh --no-sudo                       # no password prompt, no temps
python3 analyze_therm_log.py --csv                    # newest log; or pass a path
python3 analyze_therm_log.py log/mac_therm_log_2026-11-01_1302_halo-clamshell.log
```

Each run gets its own timestamped file and the label lands in the name, so A/B comparisons (lid open vs closed, game A vs game B,
stand vs desk) stay separate and the analyzer can be re-run on any of them later.

## 📝 Sample log (Apple Silicon)

```log
=== 2026-11-01T13:02:10-0600 ===
sys: chip="Apple M5 Pro" arch=arm64 macos=26.6.2 lid=closed power="AC 94%"
load: 2.22 3.20 4.45
therm: Note: No thermal warning level has been recorded
therm: Note: No performance warning level has been recorded
therm: Note: No CPU power status has been recorded
pm: Current pressure level: Nominal
pm: Fan: 1203.45 rpm
pm: CPU die temperature: 48.12 C
pm: GPU die temperature: 46.10 C
pm: E-Cluster HW active frequency: 1020 MHz
pm: P0-Cluster HW active frequency: 1234 MHz
pm: GPU HW active frequency: 338 MHz
pm: CPU Power: 1234 mW
pm: GPU Power: 56 mW
pm: Combined Power (CPU + GPU + ANE): 1290 mW
0      kernel_task      0.0 
top: 53.3% mdsync
top: 29.4% mds
-----------------------------
```

Intel logs look like the original format (pmset block + kernel_task line); the analyzer
reads both, so your old logs still work — and it now reports `CPU_Speed_Limit`, which is
the number that actually shows Intel throttling.

## 📊 Reading the summary

- **Thermal pressure** is Apple's own verdict. `Heavy`/`Trapping` means clocks are being
  cut; `Sleeping` means the machine was about to force-sleep.
- **Fan at ~0 rpm while the CPU die is above ~85 °C** is a hardware problem (blocked or
  dead fan), not a software one — the analyzer flags it.
- **Cluster MHz dropping while temperature is high** is throttling on Apple Silicon even
  when `CPU_Speed_Limit` still says 100 — M-series scales clocks instead of stealing
  cycles with `kernel_task`, so the old Intel tells don't apply.
- **Thermal Emergency Sleep** in the events list means cooling failed outright. Check
  airflow first: a lid-closed MacBook on fabric or in a tight shelf will do this long
  before a faulty fan will.

## 💡 Pro tips

- Run a 10-minute `-n 60 -i 10` session with the suspect workload and another at idle;
  compare the two summaries before blaming hardware.
- Lid-closed ("clamshell") is fine for gaming **if** the rear vents are clear — and know
  that with the lid closed, losing the external display puts the whole Mac to sleep.
- Intel Macs: if `kernel_task` sits at 100 %+ with the fans screaming, a Genius Bar fan
  cleaning is still the best fix money can buy.
