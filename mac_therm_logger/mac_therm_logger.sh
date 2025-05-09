#!/bin/bash
# This script logs the thermal status of the system every minute.
# It logs the output of `pmset -g therm` and the top 1 process by CPU usage.
# It also logs the current date and time.
# The output is saved to a file named mac_therm_log.log in the same directory as the script.
# The script runs indefinitely until terminated by the user.
# The script is intended to be run in the background, so it does not output anything to the terminal.

# wrkSpc="$(cd "$(dirname "$0")"; pwd)"
WRK_SPC="$(cd "$(dirname "$0")"; pwd)"
LOG_FILE="$WRK_SPC/log/mac_therm_log_$(date +%Y-%m-%d).log"
PYTHON_SCRIPT="analyze_therm_log.py"
mkdir -p "$WRK_SPC/log"
echo "Logging thermal status to $LOG_FILE"
printf "\n    📌 Press Ctrl+C to stop and analyze.\n"

# Define the logging function
log_loop() {
  while true; do
    echo "=== $(date) ===" >> "$LOG_FILE"
    pmset -g therm >> "$LOG_FILE"
    top -l 1 -stats pid,command,cpu -o cpu | grep kernel_task >> "$LOG_FILE"
    echo "-----------------------------" >> "$LOG_FILE"
    
    echo -ne "\r    ⏱️  Running for $(ps -o etime= -p $$ | awk '{$1=$1};1') | Logged thermal status at $(date)| PID: $$\r"
    sleep 60
  done
}

# Start logging in the background
log_loop &
LOOP_PID=$!
cleanup_has_run=false

cleanup() {
  if [ "$cleanup_has_run" = true ]; then
    return
  fi
  cleanup_has_run=true

  echo ""
  echo ""
  echo "🛑 Stopping thermal logging..."
  kill "$LOOP_PID" 2>/dev/null
  wait "$LOOP_PID" 2>/dev/null

  echo "🔍 Running Python analysis..."
  python3 "$PYTHON_SCRIPT" "$LOG_FILE"
  echo "✅ Done!"
}

# Trap Ctrl+C and normal script exit
trap cleanup SIGINT SIGTERM EXIT

# Wait for logger
wait "$LOOP_PID"
