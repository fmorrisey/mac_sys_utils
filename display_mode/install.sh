#!/bin/bash
# Builds display-mode into ~/.local/bin and installs/restarts the LaunchAgent that keeps the TV on the preferred mode.
set -euo pipefail
cd "$(dirname "$0")"
LABEL=com.fmorrisey.display-mode
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
swiftc -O -o "$HOME/.local/bin/display-mode" main.swift
sed "s|__HOME__|$HOME|g" "$LABEL.plist" > "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 1
echo "installed: ~/.local/bin/display-mode + $PLIST   log: ~/Library/Logs/display-mode.log"
tail -3 "$HOME/Library/Logs/display-mode.log"
