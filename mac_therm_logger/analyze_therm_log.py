#!/usr/bin/env python3
"""Summarize a mac_therm_logger log.

Understands both log formats:
  * the original Intel-era format (pmset -g therm + a kernel_task line per sample)
  * the current format (adds sys:/load:/pm:/top:/event: lines; pm: lines come from
    `powermetrics` on Apple Silicon: thermal pressure, fan RPM, die temperatures,
    cluster/GPU frequencies, power)

Usage: analyze_therm_log.py [LOG_FILE] [--csv [PATH]] [--top N]   (no LOG_FILE = newest in log/)
"""
import argparse
import csv
import re
import statistics
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

PRESSURE_ORDER = ["Nominal", "Moderate", "Heavy", "Trapping", "Sleeping"]
THROTTLED_PRESSURE = {"Heavy", "Trapping", "Sleeping"}

RE_TS = re.compile(r"^=== (.+) ===$")
RE_SYS = re.compile(r'^sys: chip="([^"]*)" arch=(\S+) macos=(\S+) lid=(\S+) power="([^"]*)"')
RE_LOAD = re.compile(r"^load: ([\d.]+) ([\d.]+) ([\d.]+)")
RE_SPEED = re.compile(r"CPU_Speed_Limit\s*=\s*(\d+)")
RE_SCHED = re.compile(r"CPU_Scheduler_Limit\s*=\s*(\d+)")
RE_CPUS = re.compile(r"CPU_Available_CPUs\s*=\s*(\d+)")
RE_KERNEL = re.compile(r"kernel_task\s+([\d.]+)")
RE_PRESSURE = re.compile(r"pressure level:\s*([A-Za-z]+)")
RE_FAN = re.compile(r"^pm: Fan[^:]*:\s*([\d.]+)\s*rpm", re.I)
RE_CPU_TEMP = re.compile(r"^pm: CPU[^:]*temperature:\s*([\d.]+)", re.I)
RE_GPU_TEMP = re.compile(r"^pm: GPU[^:]*temperature:\s*([\d.]+)", re.I)
RE_CLUSTER = re.compile(r"^pm: ([EP]\d*)-Cluster HW active frequency:\s*([\d.]+)\s*MHz")
RE_GPU_FREQ = re.compile(r"^pm: GPU HW active frequency:\s*([\d.]+)\s*MHz")
RE_POWER = re.compile(r"^pm: (CPU|GPU|ANE) Power:\s*([\d.]+)\s*mW")
RE_COMBINED = re.compile(r"^pm: Combined Power[^:]*:\s*([\d.]+)\s*mW")
RE_TOP = re.compile(r"^top: ([\d.]+)% (.+)$")
RE_EVENT = re.compile(r"^event: (.+)$")


def parse_timestamp(raw: str) -> Any:
    # strptime's %Z only knows the *current* zone's abbreviations, so a log written in
    # CDT won't parse on a Mac that's now in MST — fall back to dropping the abbreviation.
    candidates = [raw, re.sub(r"\s+[A-Z]{2,5}\s+(\d{4})$", r" \1", raw)]
    for s in candidates:
        for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%a %b %d %H:%M:%S %Z %Y", "%a %b %d %H:%M:%S %Y"):
            try:
                return datetime.strptime(s, fmt)
            except ValueError:
                continue
    return raw


def parse_log(path: str) -> List[Dict[str, Any]]:
    entries: List[Dict[str, Any]] = []
    cur: Optional[Dict[str, Any]] = None
    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            m = RE_TS.match(line)
            if m:
                if cur:
                    entries.append(cur)
                cur = {"timestamp": parse_timestamp(m.group(1)), "raw_ts": m.group(1),
                       "clusters": {}, "fans": [], "top": [], "events": []}
                continue
            if cur is None:
                continue
            if (m := RE_SYS.match(line)):
                cur.update(chip=m.group(1), arch=m.group(2), macos=m.group(3), lid=m.group(4), power=m.group(5))
            elif (m := RE_LOAD.match(line)):
                cur["load1"], cur["load5"], cur["load15"] = (float(x) for x in m.groups())
            elif (m := RE_SPEED.search(line)):
                cur["speed_limit"] = int(m.group(1))
            elif (m := RE_SCHED.search(line)):
                cur["scheduler_limit"] = int(m.group(1))
            elif (m := RE_CPUS.search(line)):
                cur["available_cpus"] = int(m.group(1))
            elif (m := RE_PRESSURE.search(line)):
                cur["pressure"] = m.group(1)
            elif (m := RE_FAN.match(line)):
                cur["fans"].append(float(m.group(1)))
            elif (m := RE_CPU_TEMP.match(line)):
                cur["cpu_temp"] = float(m.group(1))
            elif (m := RE_GPU_TEMP.match(line)):
                cur["gpu_temp"] = float(m.group(1))
            elif (m := RE_CLUSTER.match(line)):
                cur["clusters"][m.group(1)] = float(m.group(2))
            elif (m := RE_GPU_FREQ.match(line)):
                cur["gpu_mhz"] = float(m.group(1))
            elif (m := RE_POWER.match(line)):
                cur[m.group(1).lower() + "_mw"] = float(m.group(2))
            elif (m := RE_COMBINED.match(line)):
                cur["combined_mw"] = float(m.group(1))
            elif (m := RE_TOP.match(line)):
                cur["top"].append((float(m.group(1)), m.group(2)))
            elif (m := RE_EVENT.match(line)):
                cur["events"].append(m.group(1))
            elif (m := RE_KERNEL.search(line)):
                cur["kernel_task_cpu"] = float(m.group(1))
            elif "thermal warning level has been recorded" in line and not line.lstrip("therm: ").startswith("Note: No"):
                cur["thermal_warning"] = True
            elif "performance warning level has been recorded" in line and not line.lstrip("therm: ").startswith("Note: No"):
                cur["performance_warning"] = True
    if cur:
        entries.append(cur)
    return entries


def fmt_ts(ts: Any) -> str:
    return ts.strftime("%H:%M:%S") if isinstance(ts, datetime) else str(ts)


def fmt_span(a: Any, b: Any) -> str:
    if isinstance(a, datetime) and isinstance(b, datetime):
        secs = int((b - a).total_seconds())
        return f"{secs // 3600:d}h {secs % 3600 // 60:02d}m" if secs >= 3600 else f"{secs // 60:d}m {secs % 60:02d}s"
    return "?"


def mean(xs: List[float]) -> float:
    return statistics.mean(xs) if xs else float("nan")


def is_throttled(e: Dict[str, Any]) -> bool:
    return (e.get("pressure") in THROTTLED_PRESSURE
            or e.get("speed_limit", 100) < 100
            or e.get("scheduler_limit", 100) < 100
            or bool(e.get("events"))
            or bool(e.get("thermal_warning")))


def worst_pressure(es: List[Dict[str, Any]]) -> str:
    ps = [e["pressure"] for e in es if e.get("pressure") in PRESSURE_ORDER]
    return max(ps, key=PRESSURE_ORDER.index) if ps else "-"


def top_process(es: List[Dict[str, Any]]) -> str:
    c: Counter = Counter()
    for e in es:
        for cpu, cmd in e["top"][:1]:
            c[cmd] += 1
    return c.most_common(1)[0][0] if c else "-"


def summarize(entries: List[Dict[str, Any]], top_n: int) -> None:
    if not entries:
        print("No samples found."); return
    first, last = entries[0], entries[-1]
    print("📊 THERMAL LOG SUMMARY")
    print(f"Samples: {len(entries)}   span: {fmt_ts(first['timestamp'])} → {fmt_ts(last['timestamp'])} ({fmt_span(first['timestamp'], last['timestamp'])})")
    if first.get("chip"):
        lids = Counter(e.get("lid") for e in entries if e.get("lid"))
        powers = Counter(e.get("power", "").split(" ")[0] for e in entries if e.get("power"))
        print(f"System:  {first['chip']} ({first['arch']}), macOS {first['macos']} | lid: {', '.join(f'{k} {v}×' for k, v in lids.items())} | power: {', '.join(f'{k} {v}×' for k, v in powers.items())}")

    pressures = [e["pressure"] for e in entries if e.get("pressure")]
    if pressures:
        c = Counter(pressures)
        dist = "  ".join(f"{p} {100 * c[p] / len(pressures):.0f}%" for p in PRESSURE_ORDER + sorted(set(c) - set(PRESSURE_ORDER)) if c.get(p))
        print(f"\n🌡️  Thermal pressure: {dist}")

    cpu_t = [e["cpu_temp"] for e in entries if "cpu_temp" in e]
    gpu_t = [e["gpu_temp"] for e in entries if "gpu_temp" in e]
    if cpu_t or gpu_t:
        line = "🔥 Die temperature:"
        if cpu_t:
            hot = max(entries, key=lambda e: e.get("cpu_temp", -1))
            line += f" CPU avg {mean(cpu_t):.1f}°C / max {max(cpu_t):.1f}°C at {fmt_ts(hot['timestamp'])}"
        if gpu_t:
            line += f" | GPU avg {mean(gpu_t):.1f}°C / max {max(gpu_t):.1f}°C"
        print(line)

    fans = [max(e["fans"]) for e in entries if e["fans"]]
    if fans:
        print(f"🌀 Fan: min {min(fans):.0f} / avg {mean(fans):.0f} / max {max(fans):.0f} rpm"
              + ("   ⚠️  fan never spun up" if max(fans) < 100 and (cpu_t and max(cpu_t) > 85) else ""))

    clusters = sorted({k for e in entries for k in e["clusters"]})
    if clusters:
        parts = []
        for k in clusters:
            xs = [e["clusters"][k] for e in entries if k in e["clusters"]]
            parts.append(f"{k} avg {mean(xs):.0f} / min {min(xs):.0f} / max {max(xs):.0f}")
        print(f"⚙️  Cluster MHz: {' | '.join(parts)}")
    gpu_f = [e["gpu_mhz"] for e in entries if "gpu_mhz" in e]
    if gpu_f:
        print(f"🎮 GPU MHz: avg {mean(gpu_f):.0f} / min {min(gpu_f):.0f} / max {max(gpu_f):.0f}")

    for key, label in (("cpu_mw", "CPU"), ("gpu_mw", "GPU"), ("combined_mw", "Combined")):
        xs = [e[key] for e in entries if key in e]
        if xs:
            print(f"🔌 {label} power: avg {mean(xs) / 1000:.1f} W / max {max(xs) / 1000:.1f} W")

    speeds = [e["speed_limit"] for e in entries if "speed_limit" in e]
    if speeds:
        below = sum(1 for s in speeds if s < 100)
        print(f"🐢 CPU_Speed_Limit: min {min(speeds)}%  ({below} sample{'s' if below != 1 else ''} throttled below 100%)")
    kern = [e["kernel_task_cpu"] for e in entries if "kernel_task_cpu" in e]
    if kern:
        print(f"🧠 kernel_task CPU: avg {mean(kern):.1f}% / max {max(kern):.1f}%")
    loads = [e["load1"] for e in entries if "load1" in e]
    if loads:
        print(f"📈 Load (1 min): avg {mean(loads):.1f} / max {max(loads):.1f}")

    warnings = [(k, e) for e in entries for k in ("thermal_warning", "performance_warning") if e.get(k)]
    events = [(e["timestamp"], ev) for e in entries for ev in e["events"]]
    if warnings or events:
        print(f"\n⚠️  Warnings/events: {len(warnings) + len(events)}")
        for k, e in warnings:
            print(f"   {fmt_ts(e['timestamp'])}  {k.replace('_', ' ')}")
        for ts, ev in events:
            print(f"   {fmt_ts(ts)}  {ev}")

    # contiguous throttled stretches
    episodes: List[List[Dict[str, Any]]] = []
    for e in entries:
        if is_throttled(e):
            if episodes and entries[entries.index(e) - 1] is episodes[-1][-1]:
                episodes[-1].append(e)
            else:
                episodes.append([e])
    if episodes:
        print(f"\n🚨 Throttling episodes: {len(episodes)}")
        for ep in episodes:
            temps = [x["cpu_temp"] for x in ep if "cpu_temp" in x]
            sp = [x["speed_limit"] for x in ep if "speed_limit" in x]
            bits = [f"pressure {worst_pressure(ep)}"]
            if sp: bits.append(f"speed limit {min(sp)}%")
            if temps: bits.append(f"CPU up to {max(temps):.0f}°C")
            bits.append(f"top process: {top_process(ep)}")
            print(f"   {fmt_ts(ep[0]['timestamp'])} → {fmt_ts(ep[-1]['timestamp'])} ({len(ep)} samples, {fmt_span(ep[0]['timestamp'], ep[-1]['timestamp'])}): {', '.join(bits)}")
    elif pressures or speeds:
        print("\n✅ No throttling detected.")

    ranked = [e for e in entries if "cpu_temp" in e] or [e for e in entries if "speed_limit" in e]
    if ranked and any(e["top"] for e in ranked):
        key = (lambda e: -e["cpu_temp"]) if "cpu_temp" in ranked[0] else (lambda e: e["speed_limit"])
        print(f"\n🔎 Hottest {min(top_n, len(ranked))} samples and what was running:")
        for e in sorted(ranked, key=key)[:top_n]:
            what = ", ".join(f"{cmd} {cpu:.0f}%" for cpu, cmd in e["top"][:3]) or "-"
            metric = f"{e['cpu_temp']:.1f}°C" if "cpu_temp" in e else f"speed {e['speed_limit']}%"
            print(f"   {fmt_ts(e['timestamp'])}  {metric:>8}  {e.get('pressure', ''):<8} {what}")


def export_csv(entries: List[Dict[str, Any]], path: str) -> None:
    clusters = sorted({k for e in entries for k in e["clusters"]})
    fields = ["timestamp", "lid", "power", "load1", "pressure", "cpu_temp", "gpu_temp", "fan_rpm",
              *[f"{c}_mhz" for c in clusters], "gpu_mhz", "cpu_mw", "gpu_mw", "combined_mw",
              "speed_limit", "kernel_task_cpu", "top1", "top1_cpu", "events"]
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for e in entries:
            row = {k: e.get(k, "") for k in fields}
            row["timestamp"] = e["timestamp"].isoformat() if isinstance(e["timestamp"], datetime) else e["raw_ts"]
            row["fan_rpm"] = max(e["fans"]) if e["fans"] else ""
            for c in clusters:
                row[f"{c}_mhz"] = e["clusters"].get(c, "")
            if e["top"]:
                row["top1_cpu"], row["top1"] = e["top"][0]
            row["events"] = " | ".join(e["events"])
            w.writerow(row)
    print(f"\n✅ CSV exported to: {path}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Summarize a mac_therm_logger log.")
    ap.add_argument("log_file", nargs="?", help="log to analyze (default: the newest log/mac_therm_log_*.log)")
    ap.add_argument("--csv", nargs="?", const="AUTO", metavar="PATH", help="also export every sample as CSV")
    ap.add_argument("--top", type=int, default=5, metavar="N", help="how many hottest samples to list (default 5)")
    args = ap.parse_args()
    if not args.log_file:
        here = Path(__file__).resolve().parent
        logs = sorted(here.glob("log/mac_therm_log_*.log"), key=lambda q: q.stat().st_mtime)
        if not logs:
            print("No logs found in log/ — pass a log file path."); return 1
        args.log_file = str(logs[-1])
    print(f"Processing log file: {args.log_file}")
    try:
        entries = parse_log(args.log_file)
    except FileNotFoundError:
        print("Log file not found."); return 1
    summarize(entries, args.top)
    if args.csv and entries:
        export_csv(entries, args.csv if args.csv != "AUTO" else re.sub(r"\.log$", "", args.log_file) + "_summary.csv")
    return 0


if __name__ == "__main__":
    sys.exit(main())
