#!/bin/bash
# Installs the nxm:// handler: ~/.local/bin/nxm-fetch.py + ~/Applications/NXM Handler.app, registered for nxm links.
#   ./install.sh              install / update
#   ./install.sh --key        prompt for the Nexus API key and store it in the login Keychain
#   ./install.sh --key KEY    store the given key
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/NXM Handler.app"
BIN="$HOME/.local/bin"
mkdir -p "$BIN" "$HOME/Applications" "$HOME/Games/Skyrim Mods/downloads"
install -m 755 nxm_fetch.py "$BIN/nxm-fetch.py"
rm -rf "$APP"
osacompile -o "$APP" nxm_handler.applescript
PL="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.fmorrisey.nxm-handler" "$PL" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.fmorrisey.nxm-handler" "$PL"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$PL"
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" -c "Add :CFBundleURLTypes:0:CFBundleURLName string 'Nexus Mods link'" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string nxm" "$PL"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PL"      # no Dock icon, never steals focus from a game
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
TMP="$(mktemp -d)"; swiftc -O -o "$TMP/sethandler" set_default_handler.swift 2>/dev/null && "$TMP/sethandler"; rm -rf "$TMP"
if [ "${1:-}" = "--key" ]; then
  if [ -n "${2:-}" ]; then KEY="$2"; else read -rsp "Nexus personal API key: " KEY; echo; fi
  security add-generic-password -a "$USER" -s com.fmorrisey.nexus-api -w "$KEY" -U
  echo "API key stored in the login Keychain (service com.fmorrisey.nexus-api)."
fi
echo "installed: $APP  +  $BIN/nxm-fetch.py   log: ~/Library/Logs/nxm-handler.log"
"$BIN/nxm-fetch.py" --check || echo "Store your key:  ./install.sh --key    (make one at https://next.nexusmods.com/settings/api-keys)"
