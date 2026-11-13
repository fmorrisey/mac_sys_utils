#!/bin/bash
# Stop the agent and remove the binary and plist. The log file is left in place.
# Display-audio endpoints keep whatever format they have now; to go back to the
# multichannel format run:  hdmi-audio-stereo --once --channels 6   (before uninstalling)
set -uo pipefail

LABEL="com.fmorrisey.hdmi-audio-stereo"
BIN="$HOME/.local/bin/hdmi-audio-stereo"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$BIN"
echo "Removed $LABEL. Log kept at $HOME/Library/Logs/hdmi-audio-stereo.log"
