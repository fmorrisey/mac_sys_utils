#!/bin/bash
# Build hdmi-audio-stereo, install it as a per-user LaunchAgent, and start it.
# Re-running is safe: it rebuilds, rewrites the plist, and restarts the agent.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.fmorrisey.hdmi-audio-stereo"
BIN="$HOME/.local/bin/hdmi-audio-stereo"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

command -v swiftc >/dev/null 2>&1 || {
    echo "swiftc not found. Install the Xcode Command Line Tools first:  xcode-select --install" >&2
    exit 1
}

mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

echo "Building $BIN"
swiftc -O -o "$BIN" "$HERE/main.swift"

echo "Writing $PLIST"
sed "s|__HOME__|$HOME|g" "$HERE/$LABEL.plist" > "$PLIST"
plutil -lint -s "$PLIST"

echo "Starting agent"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
"$BIN" --status
