#!/bin/bash
# mac_therm_logger.sh — thermal / throttling logger for macOS (Apple Silicon + Intel)
#
# Appends one sample every INTERVAL seconds to log/mac_therm_log_<date>_<HHMM>[_<label>].log:
#   - Apple Silicon (via `sudo powermetrics`): thermal pressure level, fan RPM,
#     CPU/GPU die temperature, E/P-cluster + GPU frequency, CPU/GPU/combined power
#   - pmset -g therm: CPU_Speed_Limit etc. (the Intel throttle %, also reported on
#     Apple Silicon once thermal pressure engages)
#   - kernel_task CPU %, load averages, top processes by CPU (who is making the heat)
#   - lid state, power source / battery %, and any new "Thermal Emergency" /
#     "Clamshell Sleep" entries in the power log since the previous sample
# Ctrl+C (or -n N samples) stops it and runs analyze_therm_log.py on the file.
#
# Usage: ./mac_therm_logger.sh [-i SECONDS] [-l LABEL] [-n SAMPLES] [--no-sudo] [-q]
#   -i SECONDS   sample interval (default 60; keep under 240 when using sudo)
#   -l LABEL     tag the log filename, e.g. -l halo-clamshell  (great for A/B runs)
#   -n SAMPLES   stop after N samples (default: run until Ctrl+C)
#   --no-sudo    skip powermetrics: no temps/fans/pressure, but no password needed
#   -q, --quiet  no macOS notifications (everything is still written to the log)
#
# Notifications: one when thermal pressure first reaches Heavy (and again if it
# escalates to Trapping/Sleeping), one when it drops back below Heavy, and one per
# burst of new Thermal Emergency / Clamshell Sleep entries in the power log.
#
# Apple Silicon note: temperatures, fan speed and thermal pressure are only exposed
# through `powermetrics`, which needs root. The script asks for your password once
# and refreshes the sudo ticket on every sample. Intel Macs don't need sudo.

set -u

WRK_SPC="$(cd "$(dirname "$0")" && pwd)"
PYTHON_SCRIPT="$WRK_SPC/analyze_therm_log.py"
INTERVAL=60
LABEL=""
MAX_SAMPLES=0
USE_SUDO=true
NOTIFY=true

usage() { sed -n '2,/^$/p' "$0" | sed -E 's/^# ?//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--interval) INTERVAL="${2:?missing value for -i}"; shift 2 ;;
    -l|--label)    LABEL="${2:?missing value for -l}";    shift 2 ;;
    -n|--samples)  MAX_SAMPLES="${2:?missing value for -n}"; shift 2 ;;
    --no-sudo)     USE_SUDO=false; shift ;;
    -q|--quiet)    NOTIFY=false; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "unknown option: $1"; usage 1 ;;
  esac
done
case "$INTERVAL" in ''|*[!0-9]*|0) echo "-i must be a whole number of seconds >= 1"; exit 1 ;; esac
case "$MAX_SAMPLES" in ''|*[!0-9]*) echo "-n must be a whole number"; exit 1 ;; esac

ARCH="$(uname -m)"
CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
MACOS="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
IS_APPLE_SILICON=false; [ "$ARCH" = "arm64" ] && IS_APPLE_SILICON=true

mkdir -p "$WRK_SPC/log"
LOG_FILE="$WRK_SPC/log/mac_therm_log_$(date +%Y-%m-%d_%H%M)${LABEL:+_$LABEL}.log"   # one file per run, so A/B runs never merge

echo "🖥️  $CHIP ($ARCH), macOS $MACOS"
echo "📝 Logging to $LOG_FILE every ${INTERVAL}s$( [ "$MAX_SAMPLES" -gt 0 ] && echo " for $MAX_SAMPLES samples" )"

# --- powermetrics (Apple Silicon only; needs root) -----------------------------
PM_SAMPLERS=""
if $IS_APPLE_SILICON && $USE_SUDO && command -v powermetrics >/dev/null 2>&1; then
  echo "🔐 powermetrics needs root for temperatures / fan speed / thermal pressure."
  if sudo -v; then
    # Sampler names vary across macOS versions — keep only the ones this one accepts.
    for s in thermal smc cpu_power gpu_power; do
      if sudo -n powermetrics --samplers "$s" -n 1 -i 200 >/dev/null 2>&1; then
        PM_SAMPLERS="${PM_SAMPLERS:+$PM_SAMPLERS,}$s"
      fi
    done
    if [ -n "$PM_SAMPLERS" ]; then echo "   samplers: $PM_SAMPLERS"
    else echo "   ⚠️  powermetrics rejected every sampler — continuing without it"; fi
    [ "$INTERVAL" -ge 290 ] && echo "   ⚠️  interval >= sudo's 5-min ticket; powermetrics may stop working mid-run"
  else
    echo "   ⚠️  no sudo — continuing without powermetrics (pass --no-sudo to skip this prompt)"
  fi
elif $IS_APPLE_SILICON && ! $USE_SUDO; then
  echo "ℹ️  --no-sudo: temps / fans / pressure unavailable; logging pmset, load and top only."
fi
# --- macmon (temps + fans on recent macOS, where powermetrics dropped the smc sampler) ---
USE_MACMON=false
if $IS_APPLE_SILICON; then
  if command -v macmon >/dev/null 2>&1; then USE_MACMON=true; echo "   🌡️  macmon: CPU/GPU temps + fan RPM"
  else echo "   ℹ️  macmon not found — CPU temp / fan unavailable (brew install macmon)"; fi
fi
printf "\n    📌 Press Ctrl+C to stop and analyze.\n\n"

# --- helpers --------------------------------------------------------------------
lid_state() {
  if ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -q '"AppleClamshellState" = Yes'
  then echo closed; else echo open; fi
}
power_state() {   # "AC 94%" / "Battery 71%"
  local b src pct
  b="$(pmset -g batt 2>/dev/null)"
  src="Battery"; echo "$b" | grep -q "AC Power" && src="AC"
  pct="$(echo "$b" | grep -oE '[0-9]+%' | head -1)"
  echo "$src ${pct:-?}"
}
# Power-log lines worth knowing about: emergency sleeps and clamshell sleeps.
thermal_events() {
  pmset -g log 2>/dev/null | grep -E "Thermal Emergency|ThermalEvent|Clamshell Sleep" | sed -E 's/ +/ /g'
}
pm_sample() {   # the interesting powermetrics lines, prefixed "pm: "
  sudo -n powermetrics --samplers "$PM_SAMPLERS" -n 1 -i 1000 2>/dev/null \
    | grep -iE "pressure level|^ *Fan|temperature:|HW active frequency|^ *CPU Power|^ *GPU Power|^ *ANE Power|Combined Power" \
    | sed -E 's/^[[:space:]]+//; s/^/pm: /'
}
mm_sample() {   # temps + fans from macmon (no root), emitted in the same "pm: " shape the analyzer parses
  macmon pipe -s 1 -i 500 2>/dev/null | head -1 | python3 -c '
import sys, json
try: d = json.loads(sys.stdin.readline())
except Exception: sys.exit()
t = d.get("temp") or {}
if t.get("cpu_temp_avg") is not None: print("pm: CPU die temperature: %.1f C" % t["cpu_temp_avg"])
if t.get("gpu_temp_avg") is not None: print("pm: GPU die temperature: %.1f C" % t["gpu_temp_avg"])
for i, f in enumerate(d.get("fans") or []): print("pm: Fan %d: %d rpm" % (i, f.get("rpm", 0)))
' 2>/dev/null
}
notify() { $NOTIFY || return 0; osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true; }
pressure_rank() { case "$1" in Moderate) echo 1;; Heavy) echo 2;; Trapping) echo 3;; Sleeping) echo 4;; *) echo 0;; esac; }
PREV_RANK=0
pressure_notify() {   # alert once per throttling episode, not once per sample: on reaching/escalating past Heavy, and on recovery
  local pressure="$1" cputemp="$2" rank
  [ -z "$pressure" ] && return 0            # no powermetrics this sample: keep the previous state
  rank="$(pressure_rank "$pressure")"
  if [ "$rank" -ge 2 ] && [ "$rank" -gt "$PREV_RANK" ]; then
    notify "mac_therm_logger" "Thermal pressure: $pressure (CPU ${cputemp:-?} C)"
  elif [ "$rank" -lt 2 ] && [ "$PREV_RANK" -ge 2 ]; then
    notify "mac_therm_logger" "Thermal pressure back to $pressure (CPU ${cputemp:-?} C)"
  fi
  PREV_RANK="$rank"
}
proc_name() {   # friendly name for a PID: the Windows .exe for Wine processes, else the binary name
  local args exe comm
  args="$(ps -p "$1" -o args= 2>/dev/null)"
  exe="$(printf '%s\n' "$args" | grep -oE '[^\\/ ]+\.exe' | head -1)"
  if [ -n "$exe" ]; then printf '%s\n' "$exe"; return; fi
  comm="$(ps -p "$1" -o comm= 2>/dev/null)"; printf '%s\n' "${comm##*/}"
}

PREV_EVENTS="$(thermal_events | wc -l | tr -d ' ')"
SAMPLES=0
START_TS=$(date +%s)

write_sample() {
  local ts topout pm="" pressure="" cputemp="" fan="" events new
  ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
  # second report of `top -l 2`: the first one always says 0.0% CPU for everything
  topout="$(top -l 2 -s 1 -stats pid,cpu,command -o cpu 2>/dev/null | awk '/^Processes:/{b++} b==2' | grep -E '^ *[0-9]+ ')"
  [ -n "$PM_SAMPLERS" ] && { sudo -n -v 2>/dev/null; pm="$(pm_sample)"; }
  $USE_MACMON && pm="${pm:+$pm$'\n'}$(mm_sample)"
  {
    echo "=== $ts ==="
    echo "sys: chip=\"$CHIP\" arch=$ARCH macos=$MACOS lid=$(lid_state) power=\"$(power_state)\""
    echo "load: $(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{$1=$1};1')"
    pmset -g therm 2>/dev/null | sed 's/^/therm: /'
    if [ -n "$PM_SAMPLERS" ] || $USE_MACMON; then
      if [ -n "$pm" ]; then echo "$pm"; else echo "pm: unavailable (sudo ticket expired?)"; fi
    fi
    # legacy kernel_task line — same shape the Intel version wrote, so old parsers still work
    echo "$topout" | awk '$3=="kernel_task"{printf "%s      kernel_task      %s \n",$1,$2; f=1} END{if(!f) print "0      kernel_task      0.0 "}'
    echo "$topout" | awk '$3!="top"' | head -5 | while read -r pid cpu rest; do
      name="$(proc_name "$pid")"; printf "top: %s%% %s\n" "$cpu" "${name:-$rest}"
    done
    events="$(thermal_events)"
    new="$(echo "$events" | grep -c . )"
    if [ "$new" -gt "$PREV_EVENTS" ]; then
      echo "$events" | tail -n $((new - PREV_EVENTS)) | sed 's/^/event: /'
    fi
    echo "-----------------------------"
  } >> "$LOG_FILE"
  if [ "$new" -gt "$PREV_EVENTS" ]; then
    notify "mac_therm_logger" "$((new - PREV_EVENTS)) new thermal/sleep event(s) in the power log"
    PREV_EVENTS="$new"
  fi
  pressure="$(echo "$pm" | sed -nE 's/.*pressure level: *([A-Za-z]+).*/\1/p' | head -1)"
  cputemp="$(echo "$pm" | sed -nE 's/^pm: CPU[^:]*temperature: *([0-9.]+).*/\1/p' | head -1)"
  fan="$(echo "$pm" | sed -nE 's/^pm: Fan[^:]*: *([0-9.]+).*/\1/p' | sort -n | tail -1)"
  pressure_notify "$pressure" "$cputemp"
  local el=$(( $(date +%s) - START_TS ))
  printf "\r    ⏱️  %02d:%02d:%02d | sample %d | %s | pressure %-8s | CPU %5s°C | fan %6s rpm   " \
    $((el/3600)) $((el%3600/60)) $((el%60)) "$SAMPLES" "${ts:11:8}" "${pressure:--}" "${cputemp:--}" "${fan:--}"
}

STOP=0
trap 'STOP=1' INT TERM
while [ "$STOP" -eq 0 ]; do
  SAMPLES=$((SAMPLES + 1))
  t0=$(date +%s)
  write_sample
  if [ "$MAX_SAMPLES" -gt 0 ] && [ "$SAMPLES" -ge "$MAX_SAMPLES" ]; then break; fi
  # sleep for the remainder of the interval (sampling itself takes a few seconds)
  rem=$(( INTERVAL - ($(date +%s) - t0) ))
  [ "$rem" -gt 0 ] && { sleep "$rem" & wait $! 2>/dev/null; }   # interruptible: Ctrl+C returns immediately
done
trap - INT TERM

echo; echo
echo "🛑 Stopped after $SAMPLES sample(s)."
echo "🔍 Analyzing $LOG_FILE ..."
python3 "$PYTHON_SCRIPT" "$LOG_FILE"
echo "✅ Done!"
