#!/bin/bash
# Stop the agent and remove the binary and plist. The log file is left in place.
set -uo pipefail

LABEL="com.fmorrisey.wifi-autoswitch"
BIN="$HOME/.local/bin/wifi-autoswitch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$BIN"
echo "Removed $LABEL. Log kept at $HOME/Library/Logs/wifi-autoswitch.log"
echo "Wi-Fi is left in whatever state it is in now:"
networksetup -getairportpower "$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')" 2>/dev/null || true
