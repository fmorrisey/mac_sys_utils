#!/bin/bash
LABEL=com.fmorrisey.display-mode
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/display-mode"
echo "removed (log kept at ~/Library/Logs/display-mode.log)"
